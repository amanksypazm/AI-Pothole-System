import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:onnxruntime_plus/onnxruntime_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shared_reports_repository.dart';

import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;

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
  final sharedReportsRepository = SharedReportsRepository();
  await sharedReportsRepository.initialize();

  runApp(
    PotholeApp(
      cameras: cameras,
      sharedReportsRepository: sharedReportsRepository,
    ),
  );
}

class PotholeApp extends StatelessWidget {
  final List<CameraDescription> cameras;
  final SharedReportsRepository sharedReportsRepository;

  const PotholeApp({
    super.key,
    required this.cameras,
    required this.sharedReportsRepository,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AIpothole Detection',
      theme: ThemeData.dark(),
      home: HomeScreen(
        cameras: cameras,
        sharedReportsRepository: sharedReportsRepository,
      ),
    );
  }
}

class _OptionalProfilePanel extends StatefulWidget {
  final int reportCount;
  final int reviewCount;
  final SharedReportsRepository repository;

  const _OptionalProfilePanel({
    required this.reportCount,
    required this.reviewCount,
    required this.repository,
  });

  @override
  State<_OptionalProfilePanel> createState() => _OptionalProfilePanelState();
}

class _OptionalProfilePanelState extends State<_OptionalProfilePanel> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  String? _publicId;
  String? _avatarPath;
  bool _saving = false;
  bool _linkingEmail = false;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    var publicId = prefs.getString('profilePublicId');
    if (publicId == null || !RegExp(r'^[A-Z0-9]{5,10}$').hasMatch(publicId)) {
      String? authId;
      try {
        authId = await widget.repository.currentUserId();
      } catch (error) {
        debugPrint('Could not load cloud user ID; creating a local ID: $error');
      }
      if (authId != null) {
        final compact = BigInt.parse(
          authId.replaceAll('-', ''),
          radix: 16,
        ).toRadixString(36).toUpperCase();
        publicId = compact.substring(compact.length - 10);
      } else {
        final random = math.Random.secure();
        const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
        final suffix = List.generate(
          10,
          (_) => alphabet[random.nextInt(alphabet.length)],
        ).join();
        publicId = suffix;
      }
      await prefs.setString('profilePublicId', publicId);
    }
    if (!mounted) return;
    setState(() {
      _publicId = publicId;
      _nameController.text = prefs.getString('profileDisplayName') ?? '';
      _avatarPath = prefs.getString('profileAvatarPath');
      _emailController.text = widget.repository.currentEmail ?? '';
    });
  }

  Future<void> _saveProfile() async {
    setState(() => _saving = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('profileDisplayName', _nameController.text.trim());
      if (_avatarPath == null) {
        await prefs.remove('profileAvatarPath');
      } else {
        await prefs.setString('profileAvatarPath', _avatarPath!);
      }
      if (mounted) {
        setState(() => _editing = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Profile saved.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save profile: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _chooseAvatar() async {
    try {
      final path = await _roadAppChannel.invokeMethod<String>(
        'pickProfilePhoto',
      );
      if (path != null && mounted) setState(() => _avatarPath = path);
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message ?? 'Could not open photos.')),
        );
      }
    }
  }

  Future<void> _linkEmail() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) return;
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a valid email, or leave it blank.'),
        ),
      );
      return;
    }
    setState(() => _linkingEmail = true);
    try {
      await widget.repository.linkOptionalEmail(email);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Email confirmation requested. Check your inbox to finish linking.',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Email could not be linked: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _linkingEmail = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final avatarExists = _avatarPath != null && File(_avatarPath!).existsSync();
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const Text(
          'Profile',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 20),
        if (!_editing) ...[
          Center(
            child: CircleAvatar(
              radius: 48,
              backgroundColor: const Color(0xFF153448),
              backgroundImage: avatarExists
                  ? FileImage(File(_avatarPath!))
                  : null,
              child: avatarExists
                  ? null
                  : const Icon(
                      Icons.person,
                      size: 42,
                      color: Color(0xFF7DE5E9),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              _nameController.text.trim().isEmpty
                  ? 'Anonymous contributor'
                  : _nameController.text.trim(),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: InkWell(
              onTap: _copyUserId,
              child: Text(
                _publicId ?? 'Creating ID…',
                style: const TextStyle(
                  color: Colors.white60,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ),
          const SizedBox(height: 22),
          Card(
            child: ListTile(
              leading: const Icon(Icons.warning_amber),
              title: const Text('Pothole reports'),
              trailing: Text('${widget.reportCount}'),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.route_outlined),
              title: const Text('Roads reviewed'),
              trailing: Text('${widget.reviewCount}'),
            ),
          ),
          OutlinedButton.icon(
            onPressed: () => setState(() => _editing = true),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Edit profile'),
          ),
        ] else ...[
          Align(
            alignment: Alignment.center,
            child: InkWell(
              onTap: _chooseAvatar,
              borderRadius: BorderRadius.circular(60),
              child: CircleAvatar(
                radius: 46,
                backgroundColor: const Color(0xFF153448),
                backgroundImage: avatarExists
                    ? FileImage(File(_avatarPath!))
                    : null,
                child: avatarExists
                    ? null
                    : const Icon(
                        Icons.add_a_photo_outlined,
                        size: 30,
                        color: Color(0xFF7DE5E9),
                      ),
              ),
            ),
          ),
          TextButton(
            onPressed: _chooseAvatar,
            child: const Text('Choose photo'),
          ),
          TextField(
            controller: _nameController,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Name',
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(
              labelText: 'Email for account recovery',
              prefixIcon: Icon(Icons.email_outlined),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _linkingEmail || !widget.repository.isConfigured
                ? null
                : _linkEmail,
            icon: _linkingEmail
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.link),
            label: const Text('Link email'),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _saving ? null : _saveProfile,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            label: const Text('Save profile'),
          ),
          TextButton(
            onPressed: () => setState(() => _editing = false),
            child: const Text('Cancel'),
          ),
        ],
      ],
    );
  }

  Future<void> _copyUserId() async {
    final id = _publicId;
    if (id == null) return;
    await Clipboard.setData(ClipboardData(text: id));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('User ID copied.')));
    }
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
  final String clientId;
  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final String? photoPath;
  final String? photoUrl;
  final DateTime createdAt;

  const RoadIssueReport({
    required this.issueType,
    required this.severity,
    required this.description,
    required this.clientId,
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.photoPath,
    this.photoUrl,
    required this.createdAt,
  });

  Map<String, Object?> toJson() => {
    'issueType': issueType,
    'severity': severity,
    'description': description,
    'clientId': clientId,
    'latitude': latitude,
    'longitude': longitude,
    'accuracyMeters': accuracyMeters,
    'photoPath': photoPath,
    'createdAt': createdAt.toIso8601String(),
  };

  factory RoadIssueReport.fromJson(Map<String, dynamic> json) {
    final createdAt = DateTime.parse(json['createdAt'] as String);
    return RoadIssueReport(
      issueType: json['issueType'] as String,
      severity: json['severity'] as String,
      description: json['description'] as String? ?? '',
      clientId:
          json['clientId'] as String? ??
          createdAt.microsecondsSinceEpoch.toString(),
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      accuracyMeters: (json['accuracyMeters'] as num).toDouble(),
      photoPath: json['photoPath'] as String?,
      photoUrl: json['photoUrl'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
}

class RoadReview {
  final String clientId;
  final double startLatitude;
  final double startLongitude;
  final double endLatitude;
  final double endLongitude;
  final List<Map<String, double>> routePoints;
  final double distanceMeters;
  final int durationSeconds;
  final int rating;
  final bool recommend;
  final String comment;
  final DateTime createdAt;

  const RoadReview({
    required this.clientId,
    required this.startLatitude,
    required this.startLongitude,
    required this.endLatitude,
    required this.endLongitude,
    required this.routePoints,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.rating,
    required this.recommend,
    required this.comment,
    required this.createdAt,
  });

  Map<String, Object?> toJson() => {
    'clientId': clientId,
    'startLatitude': startLatitude,
    'startLongitude': startLongitude,
    'endLatitude': endLatitude,
    'endLongitude': endLongitude,
    'routePoints': routePoints,
    'distanceMeters': distanceMeters,
    'durationSeconds': durationSeconds,
    'rating': rating,
    'recommend': recommend,
    'comment': comment,
    'createdAt': createdAt.toIso8601String(),
  };

  factory RoadReview.fromJson(Map<String, dynamic> json) => RoadReview(
    clientId: json['clientId'] as String,
    startLatitude: (json['startLatitude'] as num).toDouble(),
    startLongitude: (json['startLongitude'] as num).toDouble(),
    endLatitude: (json['endLatitude'] as num).toDouble(),
    endLongitude: (json['endLongitude'] as num).toDouble(),
    routePoints: (json['routePoints'] as List<dynamic>)
        .map(
          (item) => Map<String, double>.from(
            (item as Map<String, dynamic>).map(
              (key, value) => MapEntry(key, (value as num).toDouble()),
            ),
          ),
        )
        .toList(),
    distanceMeters: (json['distanceMeters'] as num).toDouble(),
    durationSeconds: (json['durationSeconds'] as num?)?.toInt() ?? 0,
    rating: (json['rating'] as num).toInt(),
    recommend: json['recommend'] as bool,
    comment: json['comment'] as String? ?? '',
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

class HomeScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  final SharedReportsRepository sharedReportsRepository;

  const HomeScreen({
    super.key,
    required this.cameras,
    required this.sharedReportsRepository,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<RoadIssueReport> _reports = [];
  final List<RoadReview> _roadReviews = [];
  late final Future<void> _reportsLoaded;
  int _selectedTab = 0;
  bool _cloudReviewsLoading = false;
  String _searchQuery = '';

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
      if (savedJson != null && savedJson.isNotEmpty) {
        final savedReports = (jsonDecode(savedJson) as List<dynamic>)
            .map(
              (item) => RoadIssueReport.fromJson(item as Map<String, dynamic>),
            )
            .toList();
        if (mounted) setState(() => _reports.addAll(savedReports));
      }
    } catch (error) {
      debugPrint('Could not load local road reports: $error');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList('roadReviews') ?? const <String>[];
      _roadReviews.addAll(
        saved.map(
          (item) =>
              RoadReview.fromJson(jsonDecode(item) as Map<String, dynamic>),
        ),
      );
    } catch (error) {
      debugPrint('Could not load road reviews: $error');
    }
  }

  Future<void> _saveRoadReviews() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'roadReviews',
      _roadReviews.map((review) => jsonEncode(review.toJson())).toList(),
    );
  }

  Future<void> _loadCloudRoadReviews() async {
    await _reportsLoaded;
    if (!mounted ||
        !widget.sharedReportsRepository.isConfigured ||
        _cloudReviewsLoading) {
      return;
    }
    setState(() => _cloudReviewsLoading = true);
    try {
      for (final review in _roadReviews) {
        await widget.sharedReportsRepository.saveRoadReview(review.toJson());
      }
      final rows = await widget.sharedReportsRepository.fetchRoadReviews();
      final mapped = rows
          .map(
            (row) => RoadReview.fromJson({
              'clientId': row['client_id'],
              'startLatitude': row['start_latitude'],
              'startLongitude': row['start_longitude'],
              'endLatitude': row['end_latitude'],
              'endLongitude': row['end_longitude'],
              'routePoints': row['route_points'],
              'distanceMeters': row['distance_meters'],
              'durationSeconds': row['duration_seconds'] ?? 0,
              'rating': row['rating'],
              'recommend': row['recommend'],
              'comment': row['comment'],
              'createdAt': row['created_at'],
            }),
          )
          .toList();
      if (mounted) {
        setState(() {
          final existing = {for (final review in _roadReviews) review.clientId};
          _roadReviews.addAll(
            mapped.where((review) => !existing.contains(review.clientId)),
          );
        });
        await _saveRoadReviews();
      }
    } catch (error) {
      if (mounted) {
        final message = _isRoadReviewTableMissing(error)
            ? 'Supabase road_reviews table is missing. Route reviews are still saved on this phone; run database/supabase_road_reviews.sql to enable sharing.'
            : 'Could not load road reviews: $error';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => _cloudReviewsLoading = false);
    }
  }

  Future<void> _startRoadReview() async {
    final review = await Navigator.of(context).push<RoadReview>(
      MaterialPageRoute(builder: (_) => const RoadReviewCaptureScreen()),
    );
    if (review == null || !mounted) return;
    setState(() => _roadReviews.insert(0, review));
    await _saveRoadReviews();
    if (!widget.sharedReportsRepository.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Road review saved on this phone. Add Supabase setup to share it.',
          ),
        ),
      );
      return;
    }
    try {
      await widget.sharedReportsRepository.saveRoadReview(review.toJson());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Road review saved and shared.')),
        );
      }
    } catch (error) {
      if (mounted) {
        final message = _isRoadReviewTableMissing(error)
            ? 'Route saved on this phone. Apply database/supabase_road_reviews.sql to enable cloud sharing.'
            : 'Saved on this phone; cloud sync failed: $error';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  bool _isRoadReviewTableMissing(Object error) {
    final message = error.toString();
    return message.contains('PGRST205') ||
        message.contains("Could not find the table 'public.road_reviews'");
  }

  Future<void> _saveReports() async {
    try {
      await _roadAppChannel.invokeMethod<void>('saveRoadReports', {
        'reportsJson': jsonEncode(
          _reports.map((report) => report.toJson()).toList(),
        ),
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not save report details locally: $error'),
        ),
      );
    }
  }

  Future<void> _openManualReport() async {
    await _reportsLoaded;
    if (!mounted) return;

    final report = await Navigator.of(context).push<RoadIssueReport>(
      MaterialPageRoute(builder: (_) => const ManualReportScreen()),
    );

    if (report == null || !mounted) return;

    setState(() => _reports.insert(0, report));
    await _saveReports();
    await _syncReport(report);
  }

  Future<void> _syncReport(RoadIssueReport report) async {
    if (!widget.sharedReportsRepository.isConfigured) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Report saved on this phone. Cloud setup is still needed.',
          ),
        ),
      );
      return;
    }
    try {
      await widget.sharedReportsRepository.saveReport(report.toJson());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Report saved and shared with other users.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved on this phone; cloud sync failed: $error'),
        ),
      );
    }
  }

  Future<void> _openMap() async {
    await _reportsLoaded;
    await _loadCloudRoadReviews();
    if (!mounted) return;

    var reportsForMap = List<RoadIssueReport>.of(_reports);
    if (widget.sharedReportsRepository.isConfigured) {
      try {
        for (final report in _reports) {
          await widget.sharedReportsRepository.saveReport(report.toJson());
        }
        final remoteReports = await widget.sharedReportsRepository
            .fetchReports();
        final byId = {
          for (final report in reportsForMap) report.clientId: report,
        };
        for (final remote in remoteReports) {
          final report = RoadIssueReport.fromJson(remote);
          byId[report.clientId] = report;
        }
        reportsForMap = byId.values.toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load shared reports: $error')),
        );
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => RoadMapScreen(
          reports: List.unmodifiable(reportsForMap),
          reviews: List.unmodifiable(_roadReviews),
        ),
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
    await _syncReport(report);
  }

  @override
  Widget build(BuildContext context) {
    final cloudReady = widget.sharedReportsRepository.isConfigured;

    return Scaffold(
      backgroundColor: const Color(0xFF090F19),
      appBar: AppBar(
        backgroundColor: const Color(0xFF090F19),
        titleSpacing: 20,
        title: const Row(
          children: [
            Icon(Icons.shield_outlined, color: Color(0xFF26C6DA), size: 25),
            SizedBox(width: 9),
            Text(
              'AIpothole',
              style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: .2),
            ),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 18),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              color: cloudReady
                  ? const Color(0xFF103B34)
                  : const Color(0xFF292F3A),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(
                color: cloudReady
                    ? const Color(0xFF1E806B)
                    : const Color(0xFF454E5D),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  cloudReady ? Icons.cloud_done_outlined : Icons.phone_android,
                  size: 16,
                  color: cloudReady ? const Color(0xFF62D6B2) : Colors.white70,
                ),
                const SizedBox(width: 6),
                Text(
                  cloudReady ? 'SYNC SET' : 'ON DEVICE',
                  style: const TextStyle(
                    fontSize: 10,
                    letterSpacing: .6,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: _selectedTab == 0
          ? SafeArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 30),
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(color: const Color(0xFF1E7FC7)),
                      gradient: const LinearGradient(
                        colors: [Color(0xFF0B2340), Color(0xFF075B94)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: .12),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Icon(
                                Icons.health_and_safety_outlined,
                                color: Color(0xFF8BE9F2),
                              ),
                            ),
                            const SizedBox(width: 10),
                            const Text(
                              'ROAD SAFETY • COMMUNITY',
                              style: TextStyle(
                                color: Color(0xFFB8EAF4),
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 19),
                        const Text(
                          'Help make every\njourney safer.',
                          style: TextStyle(
                            fontSize: 29,
                            height: 1.12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -.4,
                          ),
                        ),
                        const SizedBox(height: 9),
                        const Text(
                          'Report road damage so other people can avoid it.',
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.4,
                            color: Colors.white70,
                          ),
                        ),
                        const SizedBox(height: 19),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _openCamera,
                            icon: const Icon(Icons.camera_alt_outlined),
                            label: const Text('Detect with camera'),
                            style: FilledButton.styleFrom(
                              foregroundColor: const Color(0xFF062034),
                              backgroundColor: const Color(0xFF7DE5E9),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              textStyle: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF121C29),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFF26364A)),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.assignment_outlined,
                          color: Color(0xFF7DE5E9),
                          size: 23,
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${_reports.length} ${_reports.length == 1 ? 'report' : 'reports'} on this phone',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                cloudReady
                                    ? 'Cloud sync is configured for saved reports'
                                    : 'Saved locally on this device',
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 25),
                  const Text(
                    'More ways to help',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 11),
                  _HomeActionCard(
                    icon: Icons.edit_location_alt,
                    title: 'Report with GPS',
                    subtitle: 'Add a road issue without taking a photo',
                    color: const Color(0xFF16B8C9),
                    onTap: _openManualReport,
                  ),
                  _HomeActionCard(
                    icon: Icons.route_outlined,
                    title: 'Review a road',
                    subtitle:
                        'Record its GPS route, rate it 1–10 and recommend it',
                    color: const Color(0xFF62D6B2),
                    onTap: _startRoadReview,
                  ),
                  _HomeActionCard(
                    icon: Icons.map_outlined,
                    title: 'View road reports',
                    subtitle: cloudReady
                        ? 'See shared reports from all users'
                        : 'See reports saved on this phone',
                    color: const Color(0xFFFFA726),
                    onTap: _openMap,
                  ),
                  const SizedBox(height: 9),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 17,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF111D2B),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF263A52)),
                    ),
                    child: const Column(
                      children: [
                        Text(
                          '🕳️ One pothole. One alert.\nOne safer journey. 🚧',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.45,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          '⚠️ A little caution can protect a lifetime. 💙',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: Color(0xFF83DDF0),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            )
          : SafeArea(child: _buildSelectedTab()),
      floatingActionButton: _selectedTab == 4
          ? null
          : FloatingActionButton(
              onPressed: _showAddActions,
              tooltip: 'Add a report or road review',
              backgroundColor: const Color(0xFF7DE5E9),
              foregroundColor: const Color(0xFF062034),
              shape: const CircleBorder(),
              child: const Icon(Icons.add, size: 30),
            ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: BottomAppBar(
        color: const Color(0xFF101722),
        shape: _selectedTab == 4 ? null : const CircularNotchedRectangle(),
        notchMargin: 7,
        child: SizedBox(
          height: 58,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: _selectedTab == 4
                ? [
                    _navItem(Icons.home_outlined, Icons.home, 'Home', 0),
                    _navItem(Icons.person_outline, Icons.person, 'Profile', 4),
                  ]
                : [
                    _navItem(Icons.home_outlined, Icons.home, 'Home', 0),
                    _navItem(Icons.search_outlined, Icons.search, 'Explore', 1),
                    const SizedBox(width: 52),
                    _navItem(
                      Icons.list_alt_outlined,
                      Icons.list_alt,
                      'Reports',
                      3,
                    ),
                    _navItem(Icons.person_outline, Icons.person, 'Profile', 4),
                  ],
          ),
        ),
      ),
    );
  }

  Widget _navItem(IconData icon, IconData activeIcon, String label, int tab) {
    final selected = _selectedTab == tab;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          setState(() => _selectedTab = tab);
          if (tab == 1) _loadCloudRoadReviews();
        },
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              selected ? activeIcon : icon,
              color: selected ? const Color(0xFF7DE5E9) : Colors.white60,
            ),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: selected ? const Color(0xFF7DE5E9) : Colors.white60,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectedTab() {
    if (_selectedTab == 1) return _buildExploreTab();
    if (_selectedTab == 3) return _buildReportsTab();
    return _buildProfileTab();
  }

  Widget _buildExploreTab() {
    final term = _searchQuery.trim().toLowerCase();
    final visibleReports = _reports
        .where(
          (report) =>
              term.isEmpty ||
              '${report.issueType} ${report.severity} ${report.description}'
                  .toLowerCase()
                  .contains(term),
        )
        .toList();
    final visibleReviews = _roadReviews
        .where(
          (review) =>
              term.isEmpty ||
              '${review.comment} ${review.recommend ? 'recommend' : 'not recommend'} ${review.rating}'
                  .toLowerCase()
                  .contains(term),
        )
        .toList();
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const Text(
          'Explore roads',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        const Text(
          'Find nearby road hazards and community reviews.',
          style: TextStyle(color: Colors.white60),
        ),
        const SizedBox(height: 16),
        TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Search by issue, severity or comment',
            border: OutlineInputBorder(),
          ),
          onChanged: (value) => setState(() => _searchQuery = value),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _openMap,
          icon: const Icon(Icons.map_outlined),
          label: const Text('Open hazard map'),
        ),
        const SizedBox(height: 22),
        Text(
          'Nearby reports (${visibleReports.length})',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        if (visibleReports.isNotEmpty)
          ...visibleReports
              .take(6)
              .map(
                (report) => Card(
                  child: ListTile(
                    leading: Icon(
                      Icons.warning_amber_rounded,
                      color: report.severity == 'Major'
                          ? Colors.redAccent
                          : Colors.orangeAccent,
                    ),
                    title: Text('${report.severity} ${report.issueType}'),
                    subtitle: Text(
                      '${report.latitude.toStringAsFixed(5)}, ${report.longitude.toStringAsFixed(5)}',
                    ),
                    onTap: _openMap,
                  ),
                ),
              ),
        const SizedBox(height: 16),
        Text(
          'Community road reviews (${visibleReviews.length})',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        if (_cloudReviewsLoading) const LinearProgressIndicator(),
        if (visibleReviews.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Center(
              child: Text(
                'No road reviews yet. Use + to review a road.',
                textAlign: TextAlign.center,
              ),
            ),
          )
        else
          ...visibleReviews.map((review) => _RoadReviewCard(review: review)),
      ],
    );
  }

  Widget _buildReportsTab() => ListView(
    padding: const EdgeInsets.all(18),
    children: [
      const Text(
        'Reports',
        style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 6),
      Text(
        '${_reports.length} saved on this phone',
        style: const TextStyle(color: Colors.white60),
      ),
      const SizedBox(height: 14),
      OutlinedButton.icon(
        onPressed: _openMap,
        icon: const Icon(Icons.map_outlined),
        label: const Text('View on map'),
      ),
      if (_reports.isEmpty)
        const Padding(
          padding: EdgeInsets.all(28),
          child: Center(child: Text('No reports yet. Tap + to add one.')),
        )
      else
        ..._reports.map(
          (report) => Card(
            child: ListTile(
              leading: Icon(
                report.issueType == 'Pothole'
                    ? Icons.warning_amber_rounded
                    : Icons.construction,
                color: report.severity == 'Major'
                    ? Colors.redAccent
                    : Colors.orangeAccent,
              ),
              title: Text('${report.severity} ${report.issueType}'),
              subtitle: Text(
                '${report.latitude.toStringAsFixed(5)}, ${report.longitude.toStringAsFixed(5)}\n${report.createdAt.toLocal()}',
              ),
              isThreeLine: true,
              trailing: report.photoPath != null || report.photoUrl != null
                  ? const Icon(Icons.photo_outlined)
                  : null,
            ),
          ),
        ),
    ],
  );

  Widget _buildProfileTab() => _OptionalProfilePanel(
    reportCount: _reports.length,
    reviewCount: _roadReviews.length,
    repository: widget.sharedReportsRepository,
  );

  Future<void> _showAddActions() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF101722),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'What would you like to add?',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt_outlined),
                title: const Text('Pothole report with camera'),
                onTap: () => Navigator.pop(context, 'camera'),
              ),
              ListTile(
                leading: const Icon(Icons.edit_location_alt),
                title: const Text('Pothole report with GPS'),
                onTap: () => Navigator.pop(context, 'gps'),
              ),
              ListTile(
                leading: const Icon(Icons.route_outlined),
                title: const Text('Start road review'),
                onTap: () => Navigator.pop(context, 'review'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'camera') await _openCamera();
    if (action == 'gps') await _openManualReport();
    if (action == 'review') await _startRoadReview();
  }
}

class _RoadReviewCard extends StatelessWidget {
  final RoadReview review;
  const _RoadReviewCard({required this.review});

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                review.recommend
                    ? Icons.thumb_up_alt_outlined
                    : Icons.thumb_down_alt_outlined,
                color: review.recommend
                    ? const Color(0xFF62D6B2)
                    : Colors.orangeAccent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${review.rating}/10 · ${review.recommend ? 'Recommended' : 'Not recommended'}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${(review.distanceMeters / 1000).toStringAsFixed(2)} km · ${_formatTripDuration(review.durationSeconds)} · ${review.routePoints.length} GPS points',
          ),
          Text(
            'Start ${review.startLatitude.toStringAsFixed(5)}, ${review.startLongitude.toStringAsFixed(5)}',
          ),
          Text(
            'End ${review.endLatitude.toStringAsFixed(5)}, ${review.endLongitude.toStringAsFixed(5)}',
          ),
          if (review.comment.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(review.comment, style: const TextStyle(color: Colors.white70)),
          ],
        ],
      ),
    ),
  );
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
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 13,
                      ),
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

class RoadReviewCaptureScreen extends StatefulWidget {
  const RoadReviewCaptureScreen({super.key});

  @override
  State<RoadReviewCaptureScreen> createState() =>
      _RoadReviewCaptureScreenState();
}

class _RoadReviewCaptureScreenState extends State<RoadReviewCaptureScreen> {
  final List<Position> _positions = [];
  StreamSubscription<Position>? _positionSubscription;
  Timer? _elapsedTimer;
  DateTime? _recordingStartedAt;
  Duration _elapsed = Duration.zero;
  Position? _startPosition;
  LatLng? _destination;
  List<LatLng> _plannedRoute = [];
  double? _plannedDistanceMeters;
  int? _estimatedDurationSeconds;
  int _routeRequestId = 0;
  double? _distanceToDestination;
  double _distanceMeters = 0;
  bool _recording = false;
  bool _finished = false;
  bool _busy = false;
  bool _routeLoading = false;
  bool _mapStyleReady = false;
  bool _mapSyncing = false;
  bool _mapSyncRequested = false;
  bool _centerMapRequested = false;
  MapLibreMapController? _mapController;
  Line? _actualRouteLine;
  Line? _plannedRouteLine;
  Circle? _startMarker;
  Circle? _endMarker;
  int _rating = 5;
  bool _recommend = true;
  final _commentController = TextEditingController();
  String? _error;

  bool get _arrivedAtDestination =>
      _distanceToDestination != null && _distanceToDestination! <= 100;

  @override
  void initState() {
    super.initState();
    _prepareCurrentLocation();
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _elapsedTimer?.cancel();
    _commentController.dispose();
    super.dispose();
  }

  LatLng _latLng(Position position) =>
      LatLng(position.latitude, position.longitude);

  Future<void> _ensureLocationPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw Exception('Phone ki Location setting on karein.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw Exception('Road route ke liye Location permission allow karein.');
    }
  }

  Future<void> _prepareCurrentLocation() async {
    try {
      await _ensureLocationPermission();
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
        ),
      );
      if (!mounted) return;
      setState(() {
        _startPosition = position;
        _error = null;
      });
      _requestMapSync(center: true);
      if (_destination != null) await _calculatePlannedRoute();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Exception: ', ''),
        );
      }
    }
  }

  Future<void> _selectDestination(LatLng destination) async {
    if (_recording || _finished) return;
    if (_startPosition == null) {
      setState(() => _error = 'Pehle current GPS location milne dein.');
      return;
    }
    setState(() {
      _destination = destination;
      _plannedRoute = [];
      _plannedDistanceMeters = null;
      _estimatedDurationSeconds = null;
      _routeLoading = true;
      _error = null;
    });
    _requestMapSync();
    await _calculatePlannedRoute();
  }

  Future<void> _calculatePlannedRoute({Position? fromPosition}) async {
    final start = fromPosition ?? _startPosition;
    final destination = _destination;
    if (start == null || destination == null) return;
    final requestId = ++_routeRequestId;
    if (mounted) setState(() => _routeLoading = true);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '${start.longitude},${start.latitude};'
        '${destination.longitude},${destination.latitude}'
        '?overview=full&geometries=geojson&steps=false',
      );
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15));
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'AIpotholeDetection/1.0',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('Road route service abhi available nahi hai.');
      }
      final data = jsonDecode(body) as Map<String, dynamic>;
      final routes = data['routes'] as List<dynamic>? ?? const [];
      if (data['code'] != 'Ok' || routes.isEmpty) {
        throw Exception('Is destination tak car route nahi mil saka.');
      }
      final route = routes.first as Map<String, dynamic>;
      final geometry = route['geometry'] as Map<String, dynamic>;
      final coordinates = geometry['coordinates'] as List<dynamic>;
      final planned = coordinates.map((coordinate) {
        final pair = coordinate as List<dynamic>;
        return LatLng((pair[1] as num).toDouble(), (pair[0] as num).toDouble());
      }).toList();
      if (!mounted || requestId != _routeRequestId) return;
      setState(() {
        _plannedRoute = planned;
        _destination = planned.last;
        _plannedDistanceMeters = (route['distance'] as num).toDouble();
        _estimatedDurationSeconds = (route['duration'] as num).round();
        _routeLoading = false;
        _error = null;
      });
      _requestMapSync();
      if (planned.length > 1 && _mapController != null && _mapStyleReady) {
        final minLat = planned
            .map((point) => point.latitude)
            .reduce((a, b) => a < b ? a : b);
        final maxLat = planned
            .map((point) => point.latitude)
            .reduce((a, b) => a > b ? a : b);
        final minLng = planned
            .map((point) => point.longitude)
            .reduce((a, b) => a < b ? a : b);
        final maxLng = planned
            .map((point) => point.longitude)
            .reduce((a, b) => a > b ? a : b);
        await _mapController!.animateCamera(
          CameraUpdate.newLatLngBounds(
            LatLngBounds(
              southwest: LatLng(minLat, minLng),
              northeast: LatLng(maxLat, maxLng),
            ),
            left: 26,
            top: 48,
            right: 26,
            bottom: 220,
          ),
        );
      }
    } catch (error) {
      if (mounted && requestId == _routeRequestId) {
        setState(() {
          _routeLoading = false;
          _error = error.toString().replaceFirst('Exception: ', '');
        });
      }
    } finally {
      client.close(force: true);
    }
  }

  void _onMapStyleLoaded() {
    _mapStyleReady = true;
    _requestMapSync(center: _startPosition != null);
  }

  void _requestMapSync({bool center = false}) {
    _mapSyncRequested = true;
    _centerMapRequested = _centerMapRequested || center;
    if (_mapController != null && _mapStyleReady && !_mapSyncing) {
      unawaited(_syncMapRoute());
    }
  }

  Future<void> _syncMapRoute() async {
    final controller = _mapController;
    if (controller == null || !_mapStyleReady || _mapSyncing) return;
    _mapSyncing = true;
    try {
      while (_mapSyncRequested && mounted) {
        _mapSyncRequested = false;
        final positions = List<Position>.of(_positions);
        final startPosition =
            _startPosition ?? (positions.isNotEmpty ? positions.first : null);
        if (startPosition == null) continue;
        final start = _latLng(startPosition);
        final actualPoints = positions.map(_latLng).toList();
        if (_centerMapRequested) {
          _centerMapRequested = false;
          await controller.animateCamera(
            CameraUpdate.newLatLngZoom(
              positions.isNotEmpty ? actualPoints.last : start,
              16,
            ),
            duration: const Duration(milliseconds: 400),
          );
        }
        final startOptions = CircleOptions(
          geometry: start,
          circleRadius: 7,
          circleColor: '#22c55e',
          circleStrokeColor: '#ffffff',
          circleStrokeWidth: 2,
        );
        if (_startMarker == null) {
          _startMarker = await controller.addCircle(startOptions);
        } else {
          await controller.updateCircle(_startMarker!, startOptions);
        }
        final end =
            _destination ?? (positions.isNotEmpty ? actualPoints.last : null);
        if (end != null) {
          final endOptions = CircleOptions(
            geometry: end,
            circleRadius: 7,
            circleColor: _finished ? '#f97316' : '#38bdf8',
            circleStrokeColor: '#ffffff',
            circleStrokeWidth: 2,
          );
          if (_endMarker == null) {
            _endMarker = await controller.addCircle(endOptions);
          } else {
            await controller.updateCircle(_endMarker!, endOptions);
          }
        }
        if (_plannedRoute.length >= 2) {
          final plannedOptions = LineOptions(
            geometry: List<LatLng>.of(_plannedRoute),
            lineColor: '#3b82f6',
            lineWidth: 5,
            lineOpacity: 0.85,
          );
          if (_plannedRouteLine == null) {
            _plannedRouteLine = await controller.addLine(plannedOptions);
          } else {
            await controller.updateLine(_plannedRouteLine!, plannedOptions);
          }
        }
        if (actualPoints.length >= 2) {
          final actualOptions = LineOptions(
            geometry: actualPoints,
            lineColor: '#18c7ac',
            lineWidth: 6,
            lineOpacity: 0.95,
          );
          if (_actualRouteLine == null) {
            _actualRouteLine = await controller.addLine(actualOptions);
          } else {
            await controller.updateLine(_actualRouteLine!, actualOptions);
          }
        }
      }
    } catch (error) {
      debugPrint('Could not update the live road route on map: $error');
    } finally {
      _mapSyncing = false;
      if (_mapSyncRequested && mounted) _requestMapSync();
    }
  }

  Future<void> _startRecording() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_destination == null) {
        throw Exception('Map par tap karke destination select karein.');
      }
      await _ensureLocationPermission();
      final first = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
        ),
      );
      if (first.accuracy > 100) {
        throw Exception(
          'GPS accuracy abhi ±${first.accuracy.toStringAsFixed(0)} m hai. Behtar signal milne par dobara Start dabayein.',
        );
      }
      _positions
        ..clear()
        ..add(first);
      _startPosition = first;
      _distanceMeters = 0;
      _distanceToDestination = Geolocator.distanceBetween(
        first.latitude,
        first.longitude,
        _destination!.latitude,
        _destination!.longitude,
      );
      _recordingStartedAt = DateTime.now();
      _elapsed = Duration.zero;
      _elapsedTimer?.cancel();
      _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final startedAt = _recordingStartedAt;
        if (mounted && startedAt != null) {
          setState(() => _elapsed = DateTime.now().difference(startedAt));
        }
      });
      _positionSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.bestForNavigation,
              distanceFilter: 4,
              timeLimit: Duration(hours: 5),
            ),
          ).listen(
            (position) {
              if (position.accuracy > 60 || _positions.length >= 5000) return;
              final previous = _positions.last;
              final moved = Geolocator.distanceBetween(
                previous.latitude,
                previous.longitude,
                position.latitude,
                position.longitude,
              );
              if (moved < 3) return;
              _distanceMeters += moved;
              _positions.add(position);
              final destination = _destination;
              _distanceToDestination = destination == null
                  ? null
                  : Geolocator.distanceBetween(
                      position.latitude,
                      position.longitude,
                      destination.latitude,
                      destination.longitude,
                    );
              if (mounted) {
                setState(() {});
                _requestMapSync(center: true);
              }
            },
            onError: (Object error) {
              if (mounted)
                setState(() => _error = 'GPS tracking ruk gaya: $error');
            },
          );
      setState(() {
        _recording = true;
        _busy = false;
      });
      _requestMapSync(center: true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  Future<void> _finishRecording() async {
    if (_plannedRoute.isNotEmpty && !_arrivedAtDestination) {
      setState(
        () => _error =
            'Selected destination se ${_distanceToDestination?.toStringAsFixed(0) ?? 'unknown'} m door ho. Wahan pahunchkar Arrived dabayein.',
      );
      return;
    }
    if (_positions.length < 2) {
      setState(
        () => _error =
            'Thode aur GPS points record hone dein, phir finish karein.',
      );
      return;
    }
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _elapsedTimer?.cancel();
    setState(() {
      _recording = false;
      _finished = true;
    });
    _requestMapSync();
  }

  void _saveReview() {
    if (_positions.length < 2 || _recordingStartedAt == null) {
      setState(
        () => _error =
            'Route record karne ke liye kam-se-kam 2 GPS points chahiye.',
      );
      return;
    }
    final first = _positions.first;
    final last = _positions.last;
    final review = RoadReview(
      clientId: DateTime.now().microsecondsSinceEpoch.toString(),
      startLatitude: first.latitude,
      startLongitude: first.longitude,
      endLatitude: last.latitude,
      endLongitude: last.longitude,
      routePoints: _positions
          .map(
            (position) => <String, double>{
              'latitude': position.latitude,
              'longitude': position.longitude,
              'accuracy': position.accuracy,
            },
          )
          .toList(),
      distanceMeters: _distanceMeters,
      durationSeconds: _elapsed.inSeconds,
      rating: _rating,
      recommend: _recommend,
      comment: _commentController.text.trim(),
      createdAt: DateTime.now(),
    );
    Navigator.of(context).pop(review);
  }

  String get _elapsedLabel =>
      '${_elapsed.inHours.toString().padLeft(2, '0')}:${(_elapsed.inMinutes % 60).toString().padLeft(2, '0')}:${(_elapsed.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Review a road')),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            flex: 6,
            child: Stack(
              children: [
                MapLibreMap(
                  styleString: 'https://tiles.openfreemap.org/styles/liberty',
                  initialCameraPosition: CameraPosition(
                    target: _startPosition == null
                        ? const LatLng(28.6139, 77.2090)
                        : LatLng(
                            _startPosition!.latitude,
                            _startPosition!.longitude,
                          ),
                    zoom: 15,
                  ),
                  myLocationEnabled: false,
                  onMapCreated: (controller) => _mapController = controller,
                  onStyleLoadedCallback: _onMapStyleLoaded,
                  onMapClick: (_, coordinates) =>
                      _selectDestination(coordinates),
                  attributionButtonPosition:
                      AttributionButtonPosition.bottomLeft,
                ),
                if (_recording)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: Center(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Color(0xDD0A1420),
                            shape: BoxShape.circle,
                          ),
                          child: Padding(
                            padding: EdgeInsets.all(9),
                            child: Icon(
                              Icons.directions_car_filled,
                              color: Color(0xFF62D6B2),
                              size: 34,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: 12,
                  top: 12,
                  child: Card(
                    color: const Color(0xE6101722),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Text(
                        _recording
                            ? 'LIVE · blue route / green travelled path'
                            : _destination == null
                            ? 'Tap the map to choose destination'
                            : 'Tap another point to change destination',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ),
                if (_routeLoading)
                  const Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: LinearProgressIndicator(
                      color: Color(0xFF62D6B2),
                      backgroundColor: Color(0xFF18334A),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            flex: 5,
            child: Container(
              width: double.infinity,
              color: const Color(0xFF0C1521),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 20),
                children: [
                  Text(
                    _recording
                        ? 'Live road tracking'
                        : _finished
                        ? 'Rate this road'
                        : 'Plan your road review',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _startPosition == null
                        ? 'Getting your GPS start point…'
                        : 'From: ${_startPosition!.latitude.toStringAsFixed(5)}, ${_startPosition!.longitude.toStringAsFixed(5)}',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _destination == null
                        ? 'To: tap a destination on the map'
                        : 'To: ${_destination!.latitude.toStringAsFixed(5)}, ${_destination!.longitude.toStringAsFixed(5)}',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (_plannedDistanceMeters != null)
                        Chip(
                          avatar: const Icon(Icons.route, size: 17),
                          label: Text(
                            'Route ${(_plannedDistanceMeters! / 1000).toStringAsFixed(1)} km',
                          ),
                        ),
                      if (_estimatedDurationSeconds != null && !_recording)
                        Chip(
                          avatar: const Icon(Icons.schedule, size: 17),
                          label: Text(
                            'ETA ${(_estimatedDurationSeconds! / 60).ceil()} min',
                          ),
                        ),
                      if (_recording || _finished)
                        Chip(
                          avatar: const Icon(Icons.timer_outlined, size: 17),
                          label: Text(_elapsedLabel),
                        ),
                      if (_recording || _finished)
                        Chip(
                          avatar: const Icon(Icons.directions_car, size: 17),
                          label: Text(
                            'Travelled ${_distanceMeters < 1000 ? '${_distanceMeters.toStringAsFixed(0)} m' : '${(_distanceMeters / 1000).toStringAsFixed(2)} km'}',
                          ),
                        ),
                      if (_recording && _distanceToDestination != null)
                        Chip(
                          avatar: const Icon(Icons.flag_outlined, size: 17),
                          label: Text(
                            '${_distanceToDestination! < 1000 ? _distanceToDestination!.toStringAsFixed(0) : (_distanceToDestination! / 1000).toStringAsFixed(1)} ${_distanceToDestination! < 1000 ? 'm' : 'km'} to destination',
                          ),
                        ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 5),
                    Text(
                      _error!,
                      style: const TextStyle(color: Colors.orangeAccent),
                    ),
                    if (_destination != null && !_recording && !_finished)
                      const Text(
                        'Route preview could not load; GPS tracking can still record your actual drive.',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                  ],
                  const SizedBox(height: 8),
                  if (!_recording && !_finished)
                    FilledButton.icon(
                      onPressed: _busy || _routeLoading || _destination == null
                          ? null
                          : _startRecording,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF167C78),
                      ),
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.navigation_outlined),
                      label: Text(
                        _busy
                            ? 'Getting GPS…'
                            : _routeLoading
                            ? 'Loading route…'
                            : 'Start live tracking',
                      ),
                    ),
                  if (_recording)
                    FilledButton.icon(
                      onPressed:
                          _positions.length < 2 ||
                              (_plannedRoute.isNotEmpty &&
                                  !_arrivedAtDestination)
                          ? null
                          : _finishRecording,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF167C78),
                      ),
                      icon: const Icon(Icons.flag_outlined),
                      label: const Text('Arrived · finish trip'),
                    ),
                  if (_recording &&
                      _plannedRoute.isNotEmpty &&
                      !_arrivedAtDestination)
                    const Text(
                      'Destination ke 100 m ke andar pahunchne par finish button active hoga.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  if (_finished) ...[
                    const Text(
                      'Road rating',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '$_rating / 10',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF7DE5E9),
                      ),
                    ),
                    Slider(
                      value: _rating.toDouble(),
                      min: 1,
                      max: 10,
                      divisions: 9,
                      label: '$_rating',
                      onChanged: (value) =>
                          setState(() => _rating = value.round()),
                    ),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                          value: true,
                          label: Text('Recommend'),
                          icon: Icon(Icons.thumb_up_outlined),
                        ),
                        ButtonSegment(
                          value: false,
                          label: Text('Don’t recommend'),
                          icon: Icon(Icons.thumb_down_outlined),
                        ),
                      ],
                      selected: {_recommend},
                      onSelectionChanged: (selection) =>
                          setState(() => _recommend = selection.first),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _commentController,
                      maxLength: 300,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Road condition comment (optional)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _saveReview,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Save road review'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

String _formatTripDuration(int seconds) {
  final duration = Duration(seconds: seconds);
  final hours = duration.inHours.toString().padLeft(2, '0');
  final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
  final remainingSeconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$hours:$minutes:$remainingSeconds';
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
  LatLng? _selectedPin;
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
      setState(() {
        _currentPosition = position;
        _selectedPin ??= LatLng(position.latitude, position.longitude);
      });
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _locationError = error.toString().replaceFirst('Exception: ', ''),
      );
    } finally {
      if (mounted) setState(() => _isLoadingLocation = false);
    }
  }

  Future<void> _openGoogleMapsPin() async {
    final position = _currentPosition;
    if (position == null) return;
    final pin = _selectedPin ?? LatLng(position.latitude, position.longitude);

    try {
      await _roadAppChannel.invokeMethod<void>('openGoogleMapsPin', {
        'latitude': pin.latitude,
        'longitude': pin.longitude,
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open Google Maps: ${error.message}')),
      );
    }
  }

  Future<void> _choosePinOnMap() async {
    final position = _currentPosition;
    if (position == null) return;
    final pin = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialLocation:
              _selectedPin ?? LatLng(position.latitude, position.longitude),
        ),
      ),
    );
    if (pin != null && mounted) setState(() => _selectedPin = pin);
  }

  void _saveDemoReport() {
    if (!_formKey.currentState!.validate()) return;

    Navigator.of(context).pop(
      RoadIssueReport(
        issueType: _issueType,
        severity: _severity,
        description: _descriptionController.text.trim(),
        clientId: DateTime.now().microsecondsSinceEpoch.toString(),
        latitude:
            (_selectedPin ??
                    LatLng(
                      _currentPosition!.latitude,
                      _currentPosition!.longitude,
                    ))
                .latitude,
        longitude:
            (_selectedPin ??
                    LatLng(
                      _currentPosition!.latitude,
                      _currentPosition!.longitude,
                    ))
                .longitude,
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
                        : _locationError ??
                              'Allow location access to continue.',
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
                  onPressed: _choosePinOnMap,
                  icon: const Icon(Icons.add_location_alt_outlined),
                  label: const Text('Adjust exact pin on map'),
                ),
                const SizedBox(height: 4),
                Text(
                  _selectedPin == null
                      ? 'Using live phone GPS location.'
                      : 'Pin: ${_selectedPin!.latitude.toStringAsFixed(6)}, ${_selectedPin!.longitude.toStringAsFixed(6)}',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
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

class LocationPickerScreen extends StatefulWidget {
  final LatLng initialLocation;

  const LocationPickerScreen({super.key, required this.initialLocation});

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  MapLibreMapController? _controller;
  LatLng? _pin;

  @override
  void initState() {
    super.initState();
    _pin = widget.initialLocation;
  }

  Future<void> _setPin(LatLng location) async {
    setState(() => _pin = location);
    final controller = _controller;
    if (controller == null) return;
    await controller.clearCircles();
    await controller.addCircle(
      CircleOptions(
        geometry: location,
        circleRadius: 10,
        circleColor: '#ff453a',
        circleStrokeColor: '#ffffff',
        circleStrokeWidth: 3,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Choose pothole location')),
      body: Stack(
        children: [
          MapLibreMap(
            styleString: 'https://tiles.openfreemap.org/styles/liberty',
            initialCameraPosition: CameraPosition(
              target: widget.initialLocation,
              zoom: 17,
            ),
            myLocationEnabled: true,
            onMapCreated: (controller) => _controller = controller,
            onStyleLoadedCallback: () => _setPin(_pin!),
            onMapClick: (_, point) => _setPin(point),
            attributionButtonPosition: AttributionButtonPosition.bottomLeft,
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 20,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Map par tap karke pin ko pothole par set karein.',
                    ),
                    const SizedBox(height: 6),
                    if (_pin != null)
                      Text(
                        '${_pin!.latitude.toStringAsFixed(6)}, ${_pin!.longitude.toStringAsFixed(6)}',
                      ),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: _pin == null
                          ? null
                          : () => Navigator.pop(context, _pin),
                      icon: const Icon(Icons.check),
                      label: const Text('Use this location'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class RoadMapScreen extends StatefulWidget {
  final List<RoadIssueReport> reports;
  final List<RoadReview> reviews;

  const RoadMapScreen({
    super.key,
    required this.reports,
    this.reviews = const [],
  });

  @override
  State<RoadMapScreen> createState() => _RoadMapScreenState();
}

class _RoadMapScreenState extends State<RoadMapScreen> {
  MapLibreMapController? _controller;
  LatLng _initialLocation = const LatLng(28.6139, 77.2090);
  bool _isLoadingLocation = true;

  @override
  void initState() {
    super.initState();
    _loadInitialLocation();
  }

  Future<void> _loadInitialLocation() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse) {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
          ),
        );
        _initialLocation = LatLng(position.latitude, position.longitude);
      } else if (permission == LocationPermission.denied) {
        final requested = await Geolocator.requestPermission();
        if (requested == LocationPermission.whileInUse ||
            requested == LocationPermission.always) {
          final position = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
            ),
          );
          _initialLocation = LatLng(position.latitude, position.longitude);
        }
      }
    } catch (error) {
      debugPrint('Could not get map starting location: $error');
    }
    if (mounted) setState(() => _isLoadingLocation = false);
  }

  Future<void> _addReportMarkers() async {
    final controller = _controller;
    if (controller == null) return;
    for (final report in widget.reports) {
      await controller.addCircle(
        CircleOptions(
          geometry: LatLng(report.latitude, report.longitude),
          circleRadius: report.severity == 'Major' ? 10 : 8,
          circleColor: report.severity == 'Major' ? '#ff453a' : '#ff9f0a',
          circleStrokeColor: '#ffffff',
          circleStrokeWidth: 2,
        ),
      );
    }
    for (final review in widget.reviews) {
      if (review.routePoints.length < 2) continue;
      await controller.addLine(
        LineOptions(
          geometry: review.routePoints
              .map((point) => LatLng(point['latitude']!, point['longitude']!))
              .toList(),
          lineColor: review.recommend ? '#18c7ac' : '#ff9f0a',
          lineWidth: 4,
          lineOpacity: 0.85,
        ),
      );
    }
  }

  Future<void> _centerOnCurrentLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled)
        throw Exception('Phone ki Location setting on karein.');
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied)
        permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception('App settings me Location permission allow karein.');
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      await _controller?.animateCamera(
        CameraUpdate.newLatLngZoom(
          LatLng(position.latitude, position.longitude),
          17,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Road reports')),
      body: Column(
        children: [
          Expanded(
            flex: 6,
            child: Stack(
              children: [
                if (_isLoadingLocation)
                  const Center(
                    child: Card(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('Getting live GPS…'),
                      ),
                    ),
                  )
                else
                  MapLibreMap(
                    styleString: 'https://tiles.openfreemap.org/styles/liberty',
                    initialCameraPosition: CameraPosition(
                      target: _initialLocation,
                      zoom: 13,
                    ),
                    myLocationEnabled: true,
                    onMapCreated: (controller) => _controller = controller,
                    onStyleLoadedCallback: _addReportMarkers,
                    attributionButtonPosition:
                        AttributionButtonPosition.bottomLeft,
                  ),
                Positioned(
                  right: 14,
                  top: 14,
                  child: FloatingActionButton.small(
                    heroTag: 'center-on-gps',
                    tooltip: 'Center on my location',
                    onPressed: _centerOnCurrentLocation,
                    child: const Icon(Icons.my_location),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Saved reports (${widget.reports.length})',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          Expanded(
            flex: 4,
            child: widget.reports.isEmpty
                ? const Center(
                    child: Text(
                      'No reports yet. Add one from the home screen.',
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    children: widget.reports
                        .map(
                          (report) => Card(
                            child: ListTile(
                              leading:
                                  report.photoPath != null ||
                                      report.photoUrl != null
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: report.photoPath != null
                                          ? Image.file(
                                              File(report.photoPath!),
                                              width: 52,
                                              height: 52,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, _, _) => Icon(
                                                Icons.warning_amber_rounded,
                                                color:
                                                    report.severity == 'Major'
                                                    ? Colors.redAccent
                                                    : Colors.orangeAccent,
                                              ),
                                            )
                                          : Image.network(
                                              report.photoUrl!,
                                              width: 52,
                                              height: 52,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, _, _) => Icon(
                                                Icons.warning_amber_rounded,
                                                color:
                                                    report.severity == 'Major'
                                                    ? Colors.redAccent
                                                    : Colors.orangeAccent,
                                              ),
                                            ),
                                    )
                                  : Icon(
                                      Icons.warning_amber_rounded,
                                      color: report.severity == 'Major'
                                          ? Colors.redAccent
                                          : Colors.orangeAccent,
                                    ),
                              title: Text(
                                '${report.severity} ${report.issueType}',
                              ),
                              subtitle: Text(
                                '${report.latitude.toStringAsFixed(5)}, ${report.longitude.toStringAsFixed(5)}  •  ±${report.accuracyMeters.toStringAsFixed(0)} m GPS',
                              ),
                              onTap: () => _controller?.animateCamera(
                                CameraUpdate.newLatLngZoom(
                                  LatLng(report.latitude, report.longitude),
                                  18,
                                ),
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
          ),
        ],
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
      [1, 3, 416, 416],
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
      final double left =
          ((x - w / 2 - preparedImage.offsetX) / preparedImage.scaleX).clamp(
            0.0,
            preparedImage.sourceWidth.toDouble(),
          );
      final double top =
          ((y - h / 2 - preparedImage.offsetY) / preparedImage.scaleY).clamp(
            0.0,
            preparedImage.sourceHeight.toDouble(),
          );
      final double right =
          ((x + w / 2 - preparedImage.offsetX) / preparedImage.scaleX).clamp(
            0.0,
            preparedImage.sourceWidth.toDouble(),
          );
      final double bottom =
          ((y + h / 2 - preparedImage.offsetY) / preparedImage.scaleY).clamp(
            0.0,
            preparedImage.sourceHeight.toDouble(),
          );

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
            width *
            height *
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
  LatLng? _selectedPhotoPin;
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
    final int sensorOrientation =
        cameraController.description.sensorOrientation;
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
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
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
          setState(
            () => _locationError = error.toString().replaceFirst(
              'Exception: ',
              '',
            ),
          );
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
        setState(
          () =>
              _locationError = error.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  Future<void> _choosePhotoPinOnMap() async {
    final position = currentPosition;
    if (position == null) return;
    final pin = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialLocation:
              _selectedPhotoPin ??
              LatLng(position.latitude, position.longitude),
        ),
      ),
    );
    if (pin != null && mounted) setState(() => _selectedPhotoPin = pin);
  }

  Future<void> _retakePhoto() async {
    final oldPath = _capturedPhotoPath;
    setState(() {
      _capturedPhotoPath = null;
      currentPosition = null;
      _selectedPhotoPin = null;
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
        clientId: DateTime.now().microsecondsSinceEpoch.toString(),
        latitude:
            (_selectedPhotoPin ?? LatLng(position.latitude, position.longitude))
                .latitude,
        longitude:
            (_selectedPhotoPin ?? LatLng(position.latitude, position.longitude))
                .longitude,
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
            return Center(
              child: Text('Camera could not start: ${snapshot.error}'),
            );
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
                    onPressed: _isCapturing
                        ? null
                        : _capturePhotoAndGetLocation,
                    icon: _isCapturing
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.camera_alt),
                    label: Text(
                      _isCapturing ? 'Taking photo…' : 'Capture pothole photo',
                    ),
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
                        title: Text(
                          _isCapturing
                              ? 'Getting GPS location…'
                              : 'GPS not ready',
                        ),
                        subtitle: Text(
                          _locationError ?? 'Photo is captured; location is needed to save this report.',
                        ),
                        trailing: _isCapturing
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : IconButton(
                                onPressed: _retryLocation,
                                icon: const Icon(Icons.refresh),
                              ),
                      ),
                    ),
                  if (currentPosition != null) ...[
                    OutlinedButton.icon(
                      onPressed: _choosePhotoPinOnMap,
                      icon: const Icon(Icons.add_location_alt_outlined),
                      label: const Text('Adjust pothole pin on map'),
                    ),
                    if (_selectedPhotoPin != null)
                      Text(
                        'Selected pin: ${_selectedPhotoPin!.latitude.toStringAsFixed(6)}, ${_selectedPhotoPin!.longitude.toStringAsFixed(6)}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                  ],
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _retakePhoto,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retake photo'),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: currentPosition == null
                        ? null
                        : _saveCapturedReport,
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
