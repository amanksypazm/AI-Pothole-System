import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:onnxruntime_plus/onnxruntime_plus.dart';

import 'dart:typed_data';

import 'package:image/image.dart' as img;

late OrtSession yoloSession;

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
      title: 'AI Pothole Detection',
      theme: ThemeData.dark(),
      home: cameras.isEmpty
          ? const CameraUnavailableScreen()
          : CameraScreen(cameras: cameras),
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

class CameraScreen extends StatefulWidget {
  final List<CameraDescription> cameras;

  const CameraScreen({super.key, required this.cameras});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  Future<void> runYoloInference(Float32List inputData) async {
    final inputTensor = OrtValueTensor.createTensorWithDataList(inputData, [
      1,
      3,
      416,
      416,
    ]);

    final inputs = {yoloSession.inputNames.first: inputTensor};

    final runOptions = OrtRunOptions();

    final outputs = await yoloSession.runAsync(runOptions, inputs);

    debugPrint('YOLO INFERENCE SUCCESS');
    debugPrint('OUTPUT COUNT: ${outputs?.length}');
    decodeYoloOutput(outputs!.first!.value as List<List<List<double>>>);
    debugPrint('OUTPUT VALUE TYPE: ${outputs.first!.value.runtimeType}');
    debugPrint('OUTPUT VALUE: ${outputs.first!.value}');

    inputTensor.release();
    runOptions.release();

    outputs.forEach((output) {
      output?.release();
    });
  }

  void decodeYoloOutput(List<List<List<double>>> output) {
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

      final double left = (x - w / 2).clamp(0.0, imageSize.toDouble());
      final double top = (y - h / 2).clamp(0.0, imageSize.toDouble());
      final double right = (x + w / 2).clamp(0.0, imageSize.toDouble());
      final double bottom = (y + h / 2).clamp(0.0, imageSize.toDouble());

      candidates.add({
        'left': left,
        'top': top,
        'right': right,
        'bottom': bottom,
        'confidence': confidence,
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
        final double area = width * height;

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

  Float32List imageToTensor(img.Image image) {
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

    return input;
  }

  @override
  void initState() {
    super.initState();

    cameraController = CameraController(
      widget.cameras.first,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    cameraFuture = cameraController.initialize().then((_) {
      cameraController.startImageStream((CameraImage image) async {
        if (isProcessingFrame) return;

        isProcessingFrame = true;

        try {
          final convertedImage = convertCameraImage(image);
          final inputData = imageToTensor(convertedImage);

          await runYoloInference(inputData);
        } finally {
          isProcessingFrame = false;
        }
      });

      getCurrentLocation();
    });
  }

  Future<void> getCurrentLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }

    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen((Position position) {
      setState(() {
        currentPosition = position;
      });
    });
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
        title: const Text('AI Pothole Detection'),
        centerTitle: true,
      ),
      body: FutureBuilder(
        future: cameraFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return Stack(
              children: [
                Align(
                  alignment: Alignment.topCenter,
                  child: AspectRatio(
                    aspectRatio: 1 / cameraController.value.aspectRatio,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final double previewWidth = constraints.maxWidth;
                        final double previewHeight = constraints.maxHeight;

                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            CameraPreview(cameraController),

                            ...detectedPotholes.map((pothole) {
                              return Positioned(
                                left:
                                    (pothole['top'] as double) /
                                    416.0 *
                                    previewWidth,
                                top:
                                    (pothole['left'] as double) /
                                    416.0 *
                                    previewHeight,
                                width:
                                    ((pothole['bottom'] as double) -
                                        (pothole['top'] as double)) /
                                    416.0 *
                                    previewWidth,
                                height:
                                    ((pothole['right'] as double) -
                                        (pothole['left'] as double)) /
                                    416.0 *
                                    previewHeight,
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
                        );
                      },
                    ),
                  ),
                ),

                Positioned(
                  left: 15,
                  right: 15,
                  bottom: 20,
                  child: Container(
                    padding: const EdgeInsets.all(15),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Text(
                      currentPosition == null
                          ? 'Getting GPS location...'
                          : 'Latitude: ${currentPosition!.latitude}\n'
                                'Longitude: ${currentPosition!.longitude}\n'
                                'Accuracy: ${currentPosition!.accuracy.toStringAsFixed(1)} m',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            );
          }

          return const Center(child: CircularProgressIndicator());
        },
      ),
    );
  }
}
