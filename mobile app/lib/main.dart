import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:onnxruntime_plus/onnxruntime_plus.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

late OrtSession yoloSession;
const MethodChannel _roadAppChannel = MethodChannel(
  'com.example.pothole_app/road_tools',
);

class _PreparedImage {
  final Float32List tensor;
  final double scaleX;
  final double scaleY;
  final int offsetX;
  final int offsetY;
  final int sourceWidth;
  final int sourceHeight;
  final int rotationDegrees;
  final bool mirrorHorizontally;

  const _PreparedImage({
    required this.tensor,
    required this.scaleX,
    required this.scaleY,
    required this.offsetX,
    required this.offsetY,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.rotationDegrees,
    required this.mirrorHorizontally,
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  OrtEnv.instance.init();

  final rawAssetFile = await rootBundle.load('assets/best.onnx');
  final bytes = rawAssetFile.buffer.asUint8List();

  final sessionOptions = OrtSessionOptions();
  yoloSession = OrtSession.fromBuffer(bytes, sessionOptions);

  debugPrint('YOLO MODEL LOADED');
  debugPrint(yoloSession.inputNames.toString());

  final cameras = await availableCameras();

  runApp(PotholeApp(cameras: cameras));
}

class PotholeApp extends StatelessWidget {
  final List<CameraDescription> cameras;

  const PotholeApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AIpothole Detection',
      theme: ThemeData.dark(),
      home: HomeScreen(cameras: cameras),
    );
  }
}

class CameraUnavailableScreen extends StatelessWidget {
  const CameraUnavailableScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('No camera is available on this device.')),
    );
  }
}

class RoadIssueReport {
  final String issueType;
  final String severity;
  final String description;
  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final String? photoPath;
  final DateTime createdAt;

  const RoadIssueReport({
    required this.issueType,
    required this.severity,
    required this.description,
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.photoPath,
    required this.createdAt,
  });

  Map<String, Object?> toJson() => {
    'issueType': issueType,
    'severity': severity,
    'description': description,
    'latitude': latitude,
    'longitude': longitude,
    'accuracyMeters': accuracyMeters,
    'photoPath': photoPath,
    'createdAt': createdAt.toIso8601String(),
  };

  factory RoadIssueReport.fromJson(Map<String, dynamic> json) {
    return RoadIssueReport(
      issueType: json['issueType'] as String,
      severity: json['severity'] as String,
      description: json['description'] as String? ?? '',
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      accuracyMeters: (json['accuracyMeters'] as num).toDouble(),
      photoPath: json['photoPath'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final List<CameraDescription> cameras;

  const HomeScreen({super.key, required this.cameras});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<RoadIssueReport> _reports = [];
  late final Future<void> _reportsLoaded;

  @override
  void initState() {
    super.initState();
    _reportsLoaded = _loadReports();
  }

  Future<void> _loadReports() async {
    try {
      final String? savedJson = await _roadAppChannel.invokeMethod<String>(
        'loadRoadReports',
      );
      if (savedJson == null || savedJson.isEmpty) return;

      final savedReports = (jsonDecode(savedJson) as List<dynamic>)
          .map((item) => RoadIssueReport.fromJson(item as Map<String, dynamic>))
          .toList();
      if (mounted) setState(() => _reports.addAll(savedReports));
    } catch (error) {
      debugPrint('Could not load local road reports: $error');
    }
  }

  Future<void> _saveReports() async {
    try {
      await _roadAppChannel.invokeMethod<void>('saveRoadReports', {
        'reportsJson': jsonEncode(_reports.map((report) => report.toJson()).toList()),
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save report details locally: $error')),
      );
    }
  }

  Future<void> _openManualReport() async {
    await _reportsLoaded;
    if (!mounted) return;

    final report = await Navigator.of(context).push<RoadIssueReport>(
      MaterialPageRoute(
        builder: (_) => const ManualReportScreen(),
      ),
    );

    if (report == null || !mounted) return;

    setState(() => _reports.insert(0, report));
    await _saveReports();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Report and photo saved on this phone. They are not uploaded.',
        ),
      ),
    );
  }

  Future<void> _openMap() async {
    await _reportsLoaded;
    if (!mounted) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => RoadMapScreen(reports: List.unmodifiable(_reports)),
      ),
    );
  }

  Future<void> _openCamera() async {
    await _reportsLoaded;
    if (!mounted) return;

    final report = await Navigator.of(context).push<RoadIssueReport>(
      MaterialPageRoute(
        builder: (_) => widget.cameras.isEmpty
            ? const CameraUnavailableScreen()
            : CameraScreen(cameras: widget.cameras),
      ),
    );
    if (report == null || !mounted) return;

    setState(() => _reports.insert(0, report));
    await _saveReports();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Photo and GPS report saved on this phone.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AIpothole Detection'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                gradient: const LinearGradient(
                  colors: [Color(0xFF073B78), Color(0xFF087EE1)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.health_and_safety, size: 34, color: Colors.white),
                  SizedBox(height: 16),
                  Text(
                    'Safer roads start with one report',
                    style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Help identify potholes and damaged roads in your area.',
                    style: TextStyle(fontSize: 15, color: Colors.white70),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'What would you like to do?',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            _HomeActionCard(
              icon: Icons.edit_location_alt,
              title: 'Report without camera',
              subtitle: 'Report road damage with GPS; no photo',
              color: const Color(0xFF16B8C9),
              onTap: _openManualReport,
            ),
            _HomeActionCard(
              icon: Icons.camera_alt,
              title: 'Detect with camera',
              subtitle: 'Live AI detection; capture a photo with GPS',
              color: const Color(0xFF3B82F6),
              onTap: _openCamera,
            ),
            _HomeActionCard(
              icon: Icons.map_outlined,
              title: 'View road reports',
              subtitle: 'See reports saved during this demo',
              color: const Color(0xFFFFA726),
              onTap: _openMap,
            ),
            const SizedBox(height: 14),
            const Text(
              'Reports are saved on this phone for now. Shared map and route planning come next.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _HomeActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(color: Colors.white60, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class ManualReportScreen extends StatefulWidget {
  const ManualReportScreen({super.key});

  @override
  State<ManualReportScreen> createState() => _ManualReportScreenState();
}

class _ManualReportScreenState extends State<ManualReportScreen> {
  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();
  String _issueType = 'Pothole';
  String _severity = 'Medium';
  Position? _currentPosition;
  bool _isLoadingLocation = false;
  String? _locationError;

  @override
  void initState() {
    super.initState();
    _loadCurrentLocation();
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentLocation() async {
    setState(() {
      _isLoadingLocation = true;
      _locationError = null;
    });

    try {
      final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception('Turn on Location services, then tap refresh.');
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        throw Exception('Location permission was denied. Allow it to report.');
      }
      if (permission == LocationPermission.deniedForever) {
        throw Exception(
          'Location permission is blocked. Enable it in the app settings.',
        );
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      if (!mounted) return;
      setState(() => _currentPosition = position);
    } catch (error) {
      if (!mounted) return;
      setState(() => _locationError = error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isLoadingLocation = false);
    }
  }

  Future<void> _openGoogleMapsPin() async {
    final position = _currentPosition;
    if (position == null) return;

    try {
      await _roadAppChannel.invokeMethod<void>('openGoogleMapsPin', {
        'latitude': position.latitude,
        'longitude': position.longitude,
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open Google Maps: ${error.message}')),
      );
    }
  }

  void _saveDemoReport() {
    if (!_formKey.currentState!.validate()) return;

    Navigator.of(context).pop(
      RoadIssueReport(
        issueType: _issueType,
        severity: _severity,
        description: _descriptionController.text.trim(),
        latitude: _currentPosition!.latitude,
        longitude: _currentPosition!.longitude,
        accuracyMeters: _currentPosition!.accuracy,
        photoPath: null,
        createdAt: DateTime.now(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Report a road issue')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text(
                'Tell us what you found',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'This report uses GPS only. No camera photo will be taken.',
                style: TextStyle(color: Colors.white60),
              ),
              const SizedBox(height: 22),
              DropdownButtonFormField<String>(
                initialValue: _issueType,
                decoration: const InputDecoration(
                  labelText: 'Issue type',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'Pothole', child: Text('Pothole')),
                  DropdownMenuItem(
                    value: 'Damaged road',
                    child: Text('Damaged road'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _issueType = value);
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _severity,
                decoration: const InputDecoration(
                  labelText: 'Severity',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'Medium', child: Text('Medium')),
                  DropdownMenuItem(value: 'Major', child: Text('Major')),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _severity = value);
                },
              ),
              const SizedBox(height: 10),
              const Text(
                'Major: a hazard that may require drivers to slow down a lot or nearly stop.',
                style: TextStyle(color: Colors.white60, fontSize: 13),
              ),
              const SizedBox(height: 18),
              TextFormField(
                controller: _descriptionController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  hintText: 'Add a short note about the road issue',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 18),
              Card(
                child: ListTile(
                  leading: Icon(
                    _locationError == null
                        ? Icons.location_searching
                        : Icons.location_off,
                  ),
                  title: Text(
                    _isLoadingLocation
                        ? 'Getting your GPS location…'
                        : _currentPosition == null
                        ? 'Location unavailable'
                        : 'Current location ready',
                  ),
                  subtitle: Text(
                    _isLoadingLocation
                        ? 'Please wait.'
                        : _currentPosition != null
                        ? 'Lat: ${_currentPosition!.latitude.toStringAsFixed(6)}\n'
                              'Lon: ${_currentPosition!.longitude.toStringAsFixed(6)}\n'
                              'Accuracy: ±${_currentPosition!.accuracy.toStringAsFixed(0)} m'
                        : _locationError ?? 'Allow location access to continue.',
                  ),
                  trailing: IconButton(
                    tooltip: 'Refresh location',
                    onPressed: _isLoadingLocation ? null : _loadCurrentLocation,
                    icon: const Icon(Icons.refresh),
                  ),
                ),
              ),
              if (_currentPosition != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _openGoogleMapsPin,
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('Check this pin in Google Maps'),
                ),
              ],
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _currentPosition == null || _isLoadingLocation
                    ? null
                    : _saveDemoReport,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Save report on this phone'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RoadMapScreen extends StatelessWidget {
  final List<RoadIssueReport> reports;

  const RoadMapScreen({super.key, required this.reports});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Road reports')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Container(
              height: 170,
              decoration: BoxDecoration(
                color: const Color(0xFF10243B),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white12),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.map_outlined, size: 48, color: Color(0xFF16B8C9)),
                  SizedBox(height: 10),
                  Text('Google Map will be connected next'),
                  SizedBox(height: 4),
                  Text(
                    'Reports can open their GPS pin in Google Maps.',
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Reports saved on this phone (${reports.length})',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            if (reports.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(18),
                  child: Text('No reports yet. Add one from the home screen.'),
                ),
              )
            else
              ...reports.map(
                (report) => Card(
                  child: ListTile(
                  leading: Icon(
                      Icons.warning_amber_rounded,
                      color: report.severity == 'Major'
                          ? Colors.redAccent
                          : Colors.orangeAccent,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (report.photoPath != null)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(
                              File(report.photoPath!),
                              width: 48,
                              height: 48,
                              fit: BoxFit.cover,
                            ),
                          ),
                        IconButton(
                          tooltip: 'Open pin in Google Maps',
                          icon: const Icon(Icons.directions_outlined),
                          onPressed: () async {
                            try {
                              await _roadAppChannel.invokeMethod<void>(
                                'openGoogleMapsPin',
                                {
                                  'latitude': report.latitude,
                                  'longitude': report.longitude,
                                },
                              );
                            } on PlatformException catch (error) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Could not open Google Maps: ${error.message}',
                                  ),
                                ),
                              );
                            }
                          },
                        ),
                      ],
                    ),
                    title: Text('${report.severity} ${report.issueType}'),
                    subtitle: Text(
                      report.description.isEmpty
                          ? 'Lat: ${report.latitude.toStringAsFixed(6)}, '
                                'Lon: ${report.longitude.toStringAsFixed(6)}\n'
                                'GPS accuracy: ±${report.accuracyMeters.toStringAsFixed(0)} m'
                          : '${report.description}\n'
                                'Lat: ${report.latitude.toStringAsFixed(6)}, '
                                'Lon: ${report.longitude.toStringAsFixed(6)}\n'
                                'GPS accuracy: ±${report.accuracyMeters.toStringAsFixed(0)} m',
                    ),
                    isThreeLine: true,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class CameraScreen extends StatefulWidget {
  final List<CameraDescription> cameras;

  const CameraScreen({super.key, required this.cameras});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  Future<void> runYoloInference(_PreparedImage preparedImage) async {
    final inputTensor = OrtValueTensor.createTensorWithDataList(
      preparedImage.tensor,
      [
        1,
        3,
        416,
        416,
      ],
    );

    final inputs = {yoloSession.inputNames.first: inputTensor};

    final runOptions = OrtRunOptions();

    final outputs = await yoloSession.runAsync(runOptions, inputs);

    debugPrint('YOLO INFERENCE SUCCESS');
    debugPrint('OUTPUT COUNT: ${outputs?.length}');
    decodeYoloOutput(
      outputs!.first!.value as List<List<List<double>>>,
      preparedImage,
    );
    debugPrint('OUTPUT VALUE TYPE: ${outputs.first!.value.runtimeType}');
    debugPrint('OUTPUT VALUE: ${outputs.first!.value}');

    inputTensor.release();
    runOptions.release();

    outputs.forEach((output) {
      output?.release();
    });
  }

  void decodeYoloOutput(
    List<List<List<double>>> output,
    _PreparedImage preparedImage,
  ) {
    final data = output[0];

    const double confidenceThreshold = 0.10;
    const double iouThreshold = 0.45;
    const int imageSize = 416;

    final List<Map<String, double>> candidates = [];

    for (int i = 0; i < data[0].length; i++) {
      final double x = data[0][i];
      final double y = data[1][i];
      final double w = data[2][i];
      final double h = data[3][i];
      final double confidence = data[4][i];

      if (confidence < confidenceThreshold) continue;

      // Undo the letterbox padding and resize so detections use source-frame
      // coordinates instead of the model's padded 416x416 coordinates.
      final double left = ((x - w / 2 - preparedImage.offsetX) /
              preparedImage.scaleX)
          .clamp(0.0, preparedImage.sourceWidth.toDouble());
      final double top = ((y - h / 2 - preparedImage.offsetY) /
              preparedImage.scaleY)
          .clamp(0.0, preparedImage.sourceHeight.toDouble());
      final double right = ((x + w / 2 - preparedImage.offsetX) /
              preparedImage.scaleX)
          .clamp(0.0, preparedImage.sourceWidth.toDouble());
      final double bottom = ((y + h / 2 - preparedImage.offsetY) /
              preparedImage.scaleY)
          .clamp(0.0, preparedImage.sourceHeight.toDouble());

      candidates.add({
        'left': left,
        'top': top,
        'right': right,
        'bottom': bottom,
        'confidence': confidence,
        'sourceWidth': preparedImage.sourceWidth.toDouble(),
        'sourceHeight': preparedImage.sourceHeight.toDouble(),
        'rotationDegrees': preparedImage.rotationDegrees.toDouble(),
        'mirrorHorizontally': preparedImage.mirrorHorizontally ? 1.0 : 0.0,
      });
    }

    candidates.sort((a, b) => b['confidence']!.compareTo(a['confidence']!));

    final List<Map<String, double>> finalDetections = [];

    for (final candidate in candidates) {
      bool duplicate = false;

      for (final existing in finalDetections) {
        if (_calculateIoU(candidate, existing) >= iouThreshold) {
          duplicate = true;
          break;
        }
      }

      if (!duplicate) {
        finalDetections.add(candidate);
      }
    }

    setState(() {
      detectedPotholes = finalDetections.map((d) {
        final double width = d['right']! - d['left']!;
        final double height = d['bottom']! - d['top']!;
        final double area =
            width * height *
            (imageSize / preparedImage.sourceWidth) *
            (imageSize / preparedImage.sourceHeight);

        String severity;

        if (area >= 25000) {
          severity = 'LARGE';
        } else if (area >= 10000) {
          severity = 'MEDIUM';
        } else {
          severity = 'SMALL';
        }

        return {
          'left': d['left']!,
          'top': d['top']!,
          'right': d['right']!,
          'bottom': d['bottom']!,
          'confidence': d['confidence']!,
          'severity': severity,
          'sourceWidth': d['sourceWidth']!,
          'sourceHeight': d['sourceHeight']!,
          'rotationDegrees': d['rotationDegrees']!,
          'mirrorHorizontally': d['mirrorHorizontally']!,
        };
      }).toList();
    });

    double maxConfidence = 0.0;

    for (final detection in finalDetections) {
      final double confidence = detection['confidence']!;

      if (confidence > maxConfidence) {
        maxConfidence = confidence;
      }

      final double width = detection['right']! - detection['left']!;
      final double height = detection['bottom']! - detection['top']!;
      final double area = width * height;

      String severity;

      if (area >= 25000) {
        severity = 'LARGE';
      } else if (area >= 10000) {
        severity = 'MEDIUM';
      } else {
        severity = 'SMALL';
      }

      debugPrint('POTHOLE DETECTED');
      debugPrint('Confidence: $confidence');
      debugPrint('Severity: $severity');
      debugPrint(
        'Box: ${detection['left']}, ${detection['top']}, '
        '${detection['right']}, ${detection['bottom']}',
      );
    }

    debugPrint('TOTAL POTHOLES: ${finalDetections.length}');
    debugPrint('MAX CONFIDENCE: $maxConfidence');
  }

  double _calculateIoU(Map<String, double> a, Map<String, double> b) {
    final double left = a['left']! > b['left']! ? a['left']! : b['left']!;
    final double top = a['top']! > b['top']! ? a['top']! : b['top']!;
    final double right = a['right']! < b['right']! ? a['right']! : b['right']!;
    final double bottom = a['bottom']! < b['bottom']!
        ? a['bottom']!
        : b['bottom']!;

    final double intersectionWidth = (right - left).clamp(0.0, double.infinity);
    final double intersectionHeight = (bottom - top).clamp(
      0.0,
      double.infinity,
    );
    final double intersection = intersectionWidth * intersectionHeight;

    final double areaA =
        (a['right']! - a['left']!) * (a['bottom']! - a['top']!);
    final double areaB =
        (b['right']! - b['left']!) * (b['bottom']! - b['top']!);
    final double union = areaA + areaB - intersection;

    if (union <= 0) return 0.0;

    return intersection / union;
  }

  late CameraController cameraController;
  late Future<void> cameraFuture;
  bool isProcessingFrame = false;
  bool _isCapturing = false;
  String? _capturedPhotoPath;
  String? _locationError;

  Position? currentPosition;
  List<Map<String, dynamic>> detectedPotholes = [];

  img.Image convertCameraImage(CameraImage image) {
    final int width = image.width;
    final int height = image.height;

    final img.Image result = img.Image(width: width, height: height);

    final Plane yPlane = image.planes[0];
    final Plane uPlane = image.planes[1];
    final Plane vPlane = image.planes[2];

    final int yRowStride = yPlane.bytesPerRow;
    final int uRowStride = uPlane.bytesPerRow;
    final int vRowStride = vPlane.bytesPerRow;

    final int uPixelStride = uPlane.bytesPerPixel ?? 1;
    final int vPixelStride = vPlane.bytesPerPixel ?? 1;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int yIndex = y * yRowStride + x;

        final int uvX = x ~/ 2;
        final int uvY = y ~/ 2;

        final int uIndex = uvY * uRowStride + uvX * uPixelStride;
        final int vIndex = uvY * vRowStride + uvX * vPixelStride;

        final int yp = yPlane.bytes[yIndex];
        final int up = uPlane.bytes[uIndex];
        final int vp = vPlane.bytes[vIndex];

        final double rValue = yp + 1.402 * (vp - 128);
        final double gValue =
            yp - 0.344136 * (up - 128) - 0.714136 * (vp - 128);
        final double bValue = yp + 1.772 * (up - 128);

        final int r = rValue.round().clamp(0, 255);
        final int g = gValue.round().clamp(0, 255);
        final int b = bValue.round().clamp(0, 255);

        result.setPixelRgb(x, y, r, g, b);
      }
    }

    return result;
  }

  _PreparedImage imageToTensor(
    img.Image image, {
    required int rotationDegrees,
    required bool mirrorHorizontally,
  }) {
    const int size = 416;

    final double scale =
        size / (image.width > image.height ? image.width : image.height);

    final int newWidth = (image.width * scale).round();
    final int newHeight = (image.height * scale).round();

    final resized = img.copyResize(image, width: newWidth, height: newHeight);

    final canvas = img.Image(width: size, height: size);

    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        canvas.setPixelRgb(x, y, 114, 114, 114);
      }
    }

    final int offsetX = (size - newWidth) ~/ 2;
    final int offsetY = (size - newHeight) ~/ 2;

    for (int y = 0; y < newHeight; y++) {
      for (int x = 0; x < newWidth; x++) {
        final pixel = resized.getPixel(x, y);

        canvas.setPixelRgb(
          x + offsetX,
          y + offsetY,
          pixel.r.toInt(),
          pixel.g.toInt(),
          pixel.b.toInt(),
        );
      }
    }

    final input = Float32List(3 * size * size);
    int index = 0;

    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        input[index++] = canvas.getPixel(x, y).r / 255.0;
      }
    }

    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        input[index++] = canvas.getPixel(x, y).g / 255.0;
      }
    }

    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        input[index++] = canvas.getPixel(x, y).b / 255.0;
      }
    }

    return _PreparedImage(
      tensor: input,
      scaleX: newWidth / image.width,
      scaleY: newHeight / image.height,
      offsetX: offsetX,
      offsetY: offsetY,
      sourceWidth: image.width,
      sourceHeight: image.height,
      rotationDegrees: rotationDegrees,
      mirrorHorizontally: mirrorHorizontally,
    );
  }

  int _deviceOrientationDegrees(DeviceOrientation orientation) {
    return switch (orientation) {
      DeviceOrientation.portraitUp => 0,
      DeviceOrientation.landscapeLeft => 90,
      DeviceOrientation.portraitDown => 180,
      DeviceOrientation.landscapeRight => 270,
    };
  }

  int _frameRotationDegrees() {
    final int sensorOrientation = cameraController.description.sensorOrientation;
    final int deviceOrientation = _deviceOrientationDegrees(
      cameraController.value.deviceOrientation,
    );
    final bool isFrontCamera =
        cameraController.description.lensDirection == CameraLensDirection.front;

    if (isFrontCamera) {
      return (sensorOrientation + deviceOrientation) % 360;
    }

    return (sensorOrientation - deviceOrientation + 360) % 360;
  }

  ({double left, double top, double width, double height}) _previewBox(
    Map<String, dynamic> detection,
    double previewWidth,
    double previewHeight,
  ) {
    final double sourceWidth = detection['sourceWidth'] as double;
    final double sourceHeight = detection['sourceHeight'] as double;
    final double left = detection['left'] as double;
    final double top = detection['top'] as double;
    final double right = detection['right'] as double;
    final double bottom = detection['bottom'] as double;
    final int rotation = (detection['rotationDegrees'] as double).round();

    double displayLeft;
    double displayTop;
    double displayRight;
    double displayBottom;
    double displayWidth;
    double displayHeight;

    switch (rotation) {
      case 90:
        displayLeft = sourceHeight - bottom;
        displayTop = left;
        displayRight = sourceHeight - top;
        displayBottom = right;
        displayWidth = sourceHeight;
        displayHeight = sourceWidth;
        break;
      case 180:
        displayLeft = sourceWidth - right;
        displayTop = sourceHeight - bottom;
        displayRight = sourceWidth - left;
        displayBottom = sourceHeight - top;
        displayWidth = sourceWidth;
        displayHeight = sourceHeight;
        break;
      case 270:
        displayLeft = top;
        displayTop = sourceWidth - right;
        displayRight = bottom;
        displayBottom = sourceWidth - left;
        displayWidth = sourceHeight;
        displayHeight = sourceWidth;
        break;
            default:
        displayLeft = left;
        displayTop = top;
        displayRight = right;
        displayBottom = bottom;
        displayWidth = sourceWidth;
        displayHeight = sourceHeight;
    }

    if ((detection['mirrorHorizontally'] as double) == 1.0) {
      final double mirroredLeft = displayWidth - displayRight;
      displayRight = displayWidth - displayLeft;
      displayLeft = mirroredLeft;
    }

    return (
      left: displayLeft / displayWidth * previewWidth,
      top: displayTop / displayHeight * previewHeight,
      width: (displayRight - displayLeft) / displayWidth * previewWidth,
      height: (displayBottom - displayTop) / displayHeight * previewHeight,
    );
  }

  @override
  void initState() {
    super.initState();

    final camera = widget.cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.back,
      orElse: () => widget.cameras.first,
    );
    cameraController = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    cameraFuture = cameraController.initialize().then((_) => _startDetection());
  }

  Future<void> _startDetection() async {
    if (!cameraController.value.isInitialized ||
        cameraController.value.isStreamingImages) {
      return;
    }

    await cameraController.startImageStream((CameraImage image) async {
      if (isProcessingFrame || _isCapturing || _capturedPhotoPath != null) {
        return;
      }

      isProcessingFrame = true;
      try {
        final convertedImage = convertCameraImage(image);
        final preparedImage = imageToTensor(
          convertedImage,
          rotationDegrees: _frameRotationDegrees(),
          mirrorHorizontally:
              cameraController.description.lensDirection ==
              CameraLensDirection.front,
        );
        await runYoloInference(preparedImage);
      } catch (error) {
        debugPrint('Could not process camera frame: $error');
      } finally {
        isProcessingFrame = false;
      }
    });
  }

  Future<Position> _getPositionAfterCapture() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw Exception('Turn on Location services, then retry GPS.');
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw Exception('Allow location access to attach GPS to this photo.');
    }

    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
      ),
    );
  }

  Future<String> _savePhotoLocally(String sourcePath) async {
    final String? photoDirectory = await _roadAppChannel.invokeMethod<String>(
      'getRoadPhotoDirectory',
    );
    if (photoDirectory == null) {
      throw Exception('Could not open this phone’s private photo storage.');
    }

    final directory = Directory(photoDirectory);
    await directory.create(recursive: true);
    final savedFile = File(
      '${directory.path}${Platform.pathSeparator}'
      'road_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    await File(sourcePath).copy(savedFile.path);
    return savedFile.path;
  }

  Future<void> _capturePhotoAndGetLocation() async {
    if (_isCapturing || _capturedPhotoPath != null) return;
    setState(() {
      _isCapturing = true;
      _locationError = null;
    });

    bool photoCaptured = false;
    try {
      if (cameraController.value.isStreamingImages) {
        await cameraController.stopImageStream();
      }
      while (isProcessingFrame) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final photo = await cameraController.takePicture();
      final savedPath = await _savePhotoLocally(photo.path);
      try {
        await File(photo.path).delete();
      } catch (_) {
        // The camera plugin may already have cleaned up its temporary file.
      }

      photoCaptured = true;
      if (mounted) setState(() => _capturedPhotoPath = savedPath);

      try {
        final position = await _getPositionAfterCapture();
        if (mounted) {
          setState(() {
            currentPosition = position;
            _locationError = null;
          });
        }
      } catch (error) {
        if (mounted) {
          setState(() => _locationError = error.toString().replaceFirst('Exception: ', ''));
        }
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not capture photo: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _isCapturing = false);
      if (!photoCaptured && mounted) {
        try {
          await _startDetection();
        } catch (error) {
          debugPrint('Could not restart camera detection: $error');
        }
      }
    }
  }

  Future<void> _retryLocation() async {
    setState(() {
      _isCapturing = true;
      _locationError = null;
    });
    try {
      final position = await _getPositionAfterCapture();
      if (mounted) setState(() => currentPosition = position);
    } catch (error) {
      if (mounted) {
        setState(() => _locationError = error.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  Future<void> _retakePhoto() async {
    final oldPath = _capturedPhotoPath;
    setState(() {
      _capturedPhotoPath = null;
      currentPosition = null;
      _locationError = null;
    });
    if (oldPath != null) {
      try {
        await File(oldPath).delete();
      } catch (_) {
        // Ignore cleanup failures for a replaced photo.
      }
    }
    try {
      await _startDetection();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not restart camera: $error')),
      );
    }
  }

  void _saveCapturedReport() {
    final path = _capturedPhotoPath;
    final position = currentPosition;
    if (path == null || position == null) return;

    final largePotholeDetected = detectedPotholes.any(
      (detection) => detection['severity'] == 'LARGE',
    );
    final detectionCount = detectedPotholes.length;
    Navigator.of(context).pop(
      RoadIssueReport(
        issueType: 'Pothole',
        severity: largePotholeDetected ? 'Major' : 'Medium',
        description: detectionCount == 0
            ? 'Photo captured. Please verify the road issue.'
            : 'AI detected $detectionCount pothole(s); please verify the result.',
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyMeters: position.accuracy,
        photoPath: path,
        createdAt: DateTime.now(),
      ),
    );
  }

  @override
  void dispose() {
    cameraController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AIpothole Detection'),
        centerTitle: true,
      ),
      body: FutureBuilder<void>(
        future: cameraFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Camera could not start: ${snapshot.error}'));
          }
          if (snapshot.connectionState == ConnectionState.done) {
            final previewHeight = (MediaQuery.sizeOf(context).height * 0.40)
                .clamp(220.0, 350.0)
                .toDouble();

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                const Text(
                  'Point the camera at the pothole',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: previewHeight,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 1 / cameraController.value.aspectRatio,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final photoPath = _capturedPhotoPath;
                          if (photoPath != null) {
                            return ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: Image.file(
                                File(photoPath),
                                fit: BoxFit.cover,
                              ),
                            );
                          }

                          final previewWidth = constraints.maxWidth;
                          final previewActualHeight = constraints.maxHeight;
                          return ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                CameraPreview(cameraController),
                                ...detectedPotholes.map((pothole) {
                                  final box = _previewBox(
                                    pothole,
                                    previewWidth,
                                    previewActualHeight,
                                  );
                                  return Positioned(
                                    left: box.left,
                                    top: box.top,
                                    width: box.width,
                                    height: box.height,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: Colors.red,
                                          width: 3,
                                        ),
                                      ),
                                    ),
                                  );
                                }),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                if (_capturedPhotoPath == null) ...[
                  FilledButton.icon(
                    onPressed: _isCapturing ? null : _capturePhotoAndGetLocation,
                    icon: _isCapturing
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.camera_alt),
                    label: Text(_isCapturing ? 'Taking photo…' : 'Capture pothole photo'),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Live AI detection runs while the camera is open.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ] else ...[
                  if (currentPosition != null)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.location_on),
                        title: const Text('GPS location attached'),
                        subtitle: Text(
                          'Latitude: ${currentPosition!.latitude.toStringAsFixed(6)}\n'
                          'Longitude: ${currentPosition!.longitude.toStringAsFixed(6)}\n'
                          'Accuracy: ±${currentPosition!.accuracy.toStringAsFixed(0)} m',
                        ),
                      ),
                    )
                  else
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.location_off),
                        title: Text(_isCapturing ? 'Getting GPS location…' : 'GPS not ready'),
                        subtitle: Text(_locationError ?? 'Photo is captured; location is needed to save this report.'),
                        trailing: _isCapturing
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : IconButton(
                                onPressed: _retryLocation,
                                icon: const Icon(Icons.refresh),
                              ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _retakePhoto,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retake photo'),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: currentPosition == null ? null : _saveCapturedReport,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Save photo with GPS report'),
                  ),
                ],
              ],
            );
          }

            return const Center(child: CircularProgressIndicator());
        },
      ),
    );
  }
}
