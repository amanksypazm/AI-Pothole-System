import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:onnxruntime_plus/onnxruntime_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'shared_reports_repository.dart';
import 'account_auth_screen.dart';
import 'profile_account_screen.dart';

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

class PotholeApp extends StatefulWidget {
  final List<CameraDescription> cameras;
  final SharedReportsRepository sharedReportsRepository;

  const PotholeApp({
    super.key,
    required this.cameras,
    required this.sharedReportsRepository,
  });

  @override
  State<PotholeApp> createState() => _PotholeAppState();
}

class _PotholeAppState extends State<PotholeApp> {
  ThemeMode _themeMode = ThemeMode.light;
  Locale _locale = const Locale('en');
  User? _sessionUser;
  bool _passwordRecovery = false;
  StreamSubscription<AuthState>? _authSubscription;
  Future<void> _cachedPreferencesLoaded = Future<void>.value();

  @override
  void initState() {
    super.initState();
    final client = widget.sharedReportsRepository.client;
    _sessionUser = client?.auth.currentUser;
    _cachedPreferencesLoaded = _loadCachedPreferences();
    if (client != null) {
      _authSubscription = client.auth.onAuthStateChange.listen((state) {
        if (!mounted) return;
        setState(() {
          _sessionUser = state.session?.user;
          if (state.event == AuthChangeEvent.passwordRecovery) {
            _passwordRecovery = true;
          }
        });
        _loadRemotePreferences(state.session?.user);
      });
    }
    _loadRemotePreferences(_sessionUser);
  }

  Future<void> _loadCachedPreferences() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    final userId = _sessionUser?.id;
    setState(() {
      _themeMode = preferences.getBool('profileDarkMode_$userId') == true
          ? ThemeMode.dark
          : ThemeMode.light;
      _locale = Locale(
        preferences.getString('profileAccountLanguage_$userId') ?? 'en',
      );
    });
  }

  Future<void> _loadRemotePreferences(User? user) async {
    await _cachedPreferencesLoaded;
    final client = widget.sharedReportsRepository.client;
    if (user == null || client == null) return;
    try {
      final row = await client
          .from('profiles')
          .select('account_language,dark_mode')
          .eq('id', user.id)
          .maybeSingle();
      if (!mounted || _sessionUser?.id != user.id || row == null) return;
      final darkMode = row['dark_mode'] as bool? ?? false;
      final language = row['account_language'] as String? ?? 'en';
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool('profileDarkMode_${user.id}', darkMode);
      await preferences.setString(
        'profileAccountLanguage_${user.id}',
        language,
      );
      if (!mounted || _sessionUser?.id != user.id) return;
      setState(() {
        _themeMode = darkMode ? ThemeMode.dark : ThemeMode.light;
        _locale = Locale(language);
      });
    } catch (_) {
      // Keep the last per-account cache available while the profile service is offline.
    }
  }

  void _setDarkMode(bool enabled) {
    setState(() => _themeMode = enabled ? ThemeMode.dark : ThemeMode.light);
  }

  void _setLanguage(String language) {
    setState(() => _locale = Locale(language));
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Pothole AI',
      theme: ThemeData.light(useMaterial3: true),
      darkTheme: ThemeData.dark(useMaterial3: true),
      themeMode: _themeMode,
      locale: _locale,
      supportedLocales: const [Locale('en'), Locale('hi')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: _passwordRecovery
          ? AccountAuthScreen(
              repository: widget.sharedReportsRepository,
              initialMode: AccountAuthMode.resetPassword,
              onPasswordReset: () => setState(() => _passwordRecovery = false),
            )
          : _sessionUser == null
          ? AccountAuthScreen(repository: widget.sharedReportsRepository)
          : HomeScreen(
              cameras: widget.cameras,
              sharedReportsRepository: widget.sharedReportsRepository,
              onDarkModeChanged: _setDarkMode,
              onLanguageChanged: _setLanguage,
            ),
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

enum _RoadMapAction { home, reports, profile, manualReport, roadReview }

class HomeScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  final SharedReportsRepository sharedReportsRepository;
  final ValueChanged<bool> onDarkModeChanged;
  final ValueChanged<String> onLanguageChanged;

  const HomeScreen({
    super.key,
    required this.cameras,
    required this.sharedReportsRepository,
    required this.onDarkModeChanged,
    required this.onLanguageChanged,
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
  bool _isAddMenuOpen = false;

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
    if (!mounted) return;
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
    final action = await Navigator.of(context).push<_RoadMapAction>(
      MaterialPageRoute(
        builder: (_) => RoadMapScreen(
          reports: List.unmodifiable(reportsForMap),
          reviews: List.unmodifiable(_roadReviews),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _RoadMapAction.home:
        setState(() => _selectedTab = 0);
      case _RoadMapAction.reports:
        setState(() => _selectedTab = 1);
      case _RoadMapAction.profile:
        setState(() => _selectedTab = 2);
      case _RoadMapAction.manualReport:
        await _openManualReport();
      case _RoadMapAction.roadReview:
        await _startRoadReview();
    }
  }

  Future<void> _openCamera() async {
    await _reportsLoaded;
    if (!mounted) return;

    final report = await Navigator.of(context).push<RoadIssueReport>(
      MaterialPageRoute(
        builder: (_) => widget.cameras.isEmpty
            ? const CameraUnavailableScreen()
            : CameraScreen(
                cameras: widget.cameras,
                captureAspectRatio: 9 / 16,
                captureAspectLabel: '16:9',
              ),
      ),
    );
    if (report == null || !mounted) return;

    setState(() => _reports.insert(0, report));
    await _saveReports();
    await _syncReport(report);
  }

  Future<void> _openSmartDetection() async {
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => widget.cameras.isEmpty
            ? const CameraUnavailableScreen()
            : CameraScreen(
                cameras: widget.cameras,
                captureAspectRatio: 9 / 16,
                captureAspectLabel: '16:9',
                smartMode: true,
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cloudReady = widget.sharedReportsRepository.isConfigured;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageColor = isDark
        ? const Color(0xFF090F19)
        : const Color(0xFFF5F7FC);

    return Scaffold(
      backgroundColor: pageColor,
      appBar: _selectedTab == 0 || _selectedTab == 2
          ? null
          : AppBar(
              backgroundColor: pageColor,
              titleSpacing: 20,
              title: const Row(
                children: [
                  Icon(
                    Icons.shield_outlined,
                    color: Color(0xFF26C6DA),
                    size: 25,
                  ),
                  SizedBox(width: 9),
                  Text(
                    'AIpothole',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      letterSpacing: .2,
                    ),
                  ),
                ],
              ),
              actions: [
                Container(
                  margin: const EdgeInsets.only(right: 18),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 7,
                  ),
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
                        cloudReady
                            ? Icons.cloud_done_outlined
                            : Icons.phone_android,
                        size: 16,
                        color: cloudReady
                            ? const Color(0xFF62D6B2)
                            : Colors.white70,
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
          ? _buildLandingHome()
          : SafeArea(child: _buildSelectedTab()),
      bottomNavigationBar: BottomAppBar(
        color: isDark ? const Color(0xFF101722) : Colors.white,
        surfaceTintColor: Colors.transparent,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              _navItem(Icons.home_outlined, Icons.home, 'Home', 0),
              _addNavItem(),
              _navItem(Icons.list_alt_outlined, Icons.list_alt, 'Reports', 1),
              _navItem(Icons.person_outline, Icons.person, 'Profile', 2),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLandingHome() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryText = isDark
        ? const Color(0xFFE4F6FA)
        : const Color(0xFF14253D);
    final secondaryText = isDark
        ? const Color(0xFFB7C7CE)
        : const Color(0xFF53647B);
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => ListView(
          padding: const EdgeInsets.fromLTRB(9, 18, 9, 16),
          children: [
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: 'Detect Potholes.\n'),
                  TextSpan(
                    text: 'Prevent Accidents.\n',
                    style: const TextStyle(color: Color(0xFF00AFC0)),
                  ),
                  TextSpan(text: 'Build Safer Roads.'),
                ],
              ),
              style: TextStyle(
                fontSize: 27,
                height: 1.22,
                fontWeight: FontWeight.w800,
                letterSpacing: -.55,
                color: primaryText,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'On-device YOLO11 pothole detection with phone-GPS reports and a community road map.',
              style: TextStyle(
                color: secondaryText,
                fontSize: 13,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 48,
              child: FilledButton.icon(
                onPressed: _openCamera,
                icon: const Icon(Icons.videocam, size: 19),
                label: const Text('Start Detection  →'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF00DCEB),
                  foregroundColor: const Color(0xFF07131B),
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: const BorderSide(
                      color: Color(0xFF77F6FF),
                      width: 1.4,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 7),
            SizedBox(
              height: 44,
              child: OutlinedButton.icon(
                onPressed: _startRoadReview,
                icon: const Icon(Icons.route_outlined, size: 19),
                label: const Text('Start Road Review'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: primaryText,
                  side: BorderSide(
                    color: isDark
                        ? const Color(0xFF344458)
                        : const Color(0xFFC6D0DF),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            _buildDetectionPreview(constraints.maxWidth - 18),
          ],
        ),
      ),
    );
  }

  Widget _buildDetectionPreview(double availableWidth) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? const Color(0xFF151B26) : Colors.white;
    final cardBorder = isDark
        ? const Color(0xFF29313D)
        : const Color(0xFFDCE3EE);
    final cardText = isDark ? const Color(0xFFCBD8DF) : const Color(0xFF46566D);
    final previewHeight = (availableWidth * .62).clamp(190.0, 250.0).toDouble();
    return Semantics(
      button: true,
      label: 'Open live AI road detection camera',
      child: InkWell(
        borderRadius: BorderRadius.circular(15),
        onTap: _openSmartDetection,
        child: Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: cardBorder),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 15, vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.circle, color: Color(0xFFFF7777), size: 9),
                    SizedBox(width: 8),
                    Text(
                      'DETECTION PREVIEW',
                      style: TextStyle(
                        color: Color(0xFFFFA3A3),
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: .5,
                      ),
                    ),
                    Spacer(),
                    Text(
                      'TAP TO SCAN',
                      style: TextStyle(
                        color: Color(0xFF00DCEB),
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: previewHeight,
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.asset(
                      'assets/home_pothole_sample.jpg',
                      fit: BoxFit.cover,
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: .24),
                            Colors.transparent,
                            Colors.black.withValues(alpha: .68),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      left: availableWidth * .24,
                      top: previewHeight * .33,
                      width: availableWidth * .36,
                      height: previewHeight * .27,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: const Color(0xFF00E5F0),
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 4,
                            ),
                            color: const Color(0xFFFFA5A0),
                            child: const Text(
                              'POTHOLE • SAMPLE',
                              style: TextStyle(
                                color: Color(0xFF251619),
                                fontSize: 9,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 12,
                      bottom: 10,
                      child: Text(
                        'Example model overlay · start detection for live camera',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                child: Row(
                  children: [
                    Icon(
                      Icons.satellite_alt,
                      size: 15,
                      color: Color(0xFF79DCE5),
                    ),
                    SizedBox(width: 7),
                    Text(
                      'Phone-GPS tagged reports',
                      style: TextStyle(
                        color: cardText,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Spacer(),
                    Text(
                      'ON-DEVICE YOLO',
                      style: TextStyle(
                        color: Color(0xFF7DE5B4),
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem(IconData icon, IconData activeIcon, String label, int tab) {
    final selected = _selectedTab == tab;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final idleColor = isDark ? Colors.white60 : const Color(0xFF65748A);
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          setState(() => _selectedTab = tab);
        },
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              selected ? activeIcon : icon,
              color: selected ? const Color(0xFF16A9B9) : idleColor,
            ),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: selected ? const Color(0xFF16A9B9) : idleColor,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _addNavItem() => Expanded(
    child: Center(
      child: IconButton.filled(
        onPressed: _showAddActions,
        tooltip: 'Add a report or road review',
        style: IconButton.styleFrom(
          backgroundColor: _isAddMenuOpen
              ? const Color(0xFF7DE5E9)
              : const Color(0xFF737E8A),
          foregroundColor: _isAddMenuOpen
              ? const Color(0xFF062034)
              : const Color(0xFFE4F6FA),
          fixedSize: const Size(44, 44),
        ),
        icon: const Icon(Icons.add, size: 26),
      ),
    ),
  );

  Widget _buildSelectedTab() {
    if (_selectedTab == 1) return _buildReportsTab();
    return _buildProfileTab();
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

  Widget _buildProfileTab() => ProfileAccountScreen(
    repository: widget.sharedReportsRepository,
    onBack: () => setState(() => _selectedTab = 0),
    onDarkModeChanged: widget.onDarkModeChanged,
    onLanguageChanged: widget.onLanguageChanged,
  );

  Future<void> _showAddActions() async {
    setState(() => _isAddMenuOpen = true);
    String? action;
    try {
      action = await showModalBottomSheet<String>(
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
    } finally {
      if (mounted) setState(() => _isAddMenuOpen = false);
    }
    if (!mounted) return;
    if (action == 'camera') await _openCamera();
    if (action == 'gps') await _openManualReport();
    if (action == 'review') await _startRoadReview();
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

  Future<void> _openDestinationPicker() async {
    if (_recording || _finished) return;
    final start = _startPosition;
    if (start == null) {
      setState(() => _error = 'Pehle current GPS location milne dein.');
      return;
    }
    final destination = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => RoadDestinationPickerScreen(
          startLocation: _latLng(start),
          initialDestination: _destination,
        ),
      ),
    );
    if (destination != null && mounted) {
      await _selectDestination(destination);
    }
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
        throw Exception('Full-screen map par destination choose karein.');
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
              if (mounted) {
                setState(() => _error = 'GPS tracking ruk gaya: $error');
              }
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
          Card(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            color: const Color(0xFF151F2C),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  SizedBox(
                    width: 22,
                    child: Column(
                      children: [
                        const Icon(
                          Icons.radio_button_unchecked,
                          size: 16,
                          color: Color(0xFF62D6B2),
                        ),
                        Container(width: 1, height: 18, color: Colors.white38),
                        const Icon(
                          Icons.location_on,
                          size: 18,
                          color: Color(0xFF7DE5E9),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      children: [
                        _RoutePointField(
                          text: _startPosition == null
                              ? 'Getting your location…'
                              : 'Your location · ${_startPosition!.latitude.toStringAsFixed(4)}, ${_startPosition!.longitude.toStringAsFixed(4)}',
                          hint: 'Choose starting point',
                          highlighted: true,
                          icon: Icons.my_location,
                          onTap: _recording || _finished
                              ? null
                              : _prepareCurrentLocation,
                        ),
                        const SizedBox(height: 8),
                        _RoutePointField(
                          text: _destination == null
                              ? ''
                              : '${_destination!.latitude.toStringAsFixed(4)}, ${_destination!.longitude.toStringAsFixed(4)}',
                          hint: 'Choose destination…',
                          icon: Icons.search,
                          onTap: _recording || _finished
                              ? null
                              : _openDestinationPicker,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.swap_vert, color: Colors.white70, size: 22),
                ],
              ),
            ),
          ),
          Expanded(
            flex: 4,
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
                  onMapClick: (_, __) => _openDestinationPicker(),
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
                            ? 'Tap to open full-screen map'
                            : 'Tap to change destination on full-screen map',
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

class _RoutePointField extends StatelessWidget {
  final String text;
  final String hint;
  final IconData icon;
  final bool highlighted;
  final VoidCallback? onTap;

  const _RoutePointField({
    required this.text,
    required this.hint,
    required this.icon,
    required this.onTap,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 46),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
          color: const Color(0xFF0C1521),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: highlighted ? const Color(0xFF00C7D9) : Colors.white24,
            width: highlighted ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                text.isEmpty ? hint : text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: text.isEmpty ? Colors.white54 : Colors.white,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(icon, size: 20, color: const Color(0xFF00C7D9)),
          ],
        ),
      ),
    ),
  );
}

class RoadDestinationPickerScreen extends StatefulWidget {
  final LatLng startLocation;
  final LatLng? initialDestination;

  const RoadDestinationPickerScreen({
    super.key,
    required this.startLocation,
    this.initialDestination,
  });

  @override
  State<RoadDestinationPickerScreen> createState() =>
      _RoadDestinationPickerScreenState();
}

class _RoadDestinationPickerScreenState
    extends State<RoadDestinationPickerScreen> {
  MapLibreMapController? _controller;
  LatLng? _destination;

  @override
  void initState() {
    super.initState();
    _destination = widget.initialDestination;
  }

  Future<void> _setDestination(LatLng point) async {
    setState(() => _destination = point);
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.clearCircles();
      await controller.addCircle(
        CircleOptions(
          geometry: widget.startLocation,
          circleRadius: 8,
          circleColor: '#22c55e',
          circleStrokeColor: '#ffffff',
          circleStrokeWidth: 2,
        ),
      );
      await controller.addCircle(
        CircleOptions(
          geometry: point,
          circleRadius: 10,
          circleColor: '#38bdf8',
          circleStrokeColor: '#ffffff',
          circleStrokeWidth: 3,
        ),
      );
    } catch (error) {
      debugPrint('Could not draw road destination markers: $error');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Choose destination')),
    body: Stack(
      children: [
        MapLibreMap(
          styleString: 'https://tiles.openfreemap.org/styles/liberty',
          initialCameraPosition: CameraPosition(
            target: _destination ?? widget.startLocation,
            zoom: _destination == null ? 14 : 15,
          ),
          myLocationEnabled: true,
          onMapCreated: (controller) => _controller = controller,
          onStyleLoadedCallback: () {
            if (_destination != null) {
              _setDestination(_destination!);
            } else {
              final controller = _controller;
              if (controller != null) {
                unawaited(
                  controller.addCircle(
                    CircleOptions(
                      geometry: widget.startLocation,
                      circleRadius: 8,
                      circleColor: '#22c55e',
                      circleStrokeColor: '#ffffff',
                      circleStrokeWidth: 2,
                    ),
                  ),
                );
              }
            }
          },
          onMapClick: (_, point) => _setDestination(point),
          attributionButtonPosition: AttributionButtonPosition.bottomLeft,
        ),
        Positioned(
          left: 12,
          right: 12,
          top: 12,
          child: Card(
            color: const Color(0xF0101722),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.my_location,
                        color: Color(0xFF62D6B2),
                        size: 19,
                      ),
                      const SizedBox(width: 9),
                      const Expanded(child: Text('Your location')),
                      Text(
                        '${widget.startLocation.latitude.toStringAsFixed(4)}, ${widget.startLocation.longitude.toStringAsFixed(4)}',
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const Padding(
                    padding: EdgeInsets.only(left: 9),
                    child: SizedBox(
                      height: 13,
                      child: VerticalDivider(width: 1, color: Colors.white38),
                    ),
                  ),
                  Row(
                    children: [
                      const Icon(
                        Icons.location_on_outlined,
                        color: Color(0xFF7DE5E9),
                        size: 19,
                      ),
                      const SizedBox(width: 9),
                      const Text('Choose destination'),
                      const Spacer(),
                      Text(
                        _destination == null
                            ? 'Tap the map'
                            : '${_destination!.latitude.toStringAsFixed(4)}, ${_destination!.longitude.toStringAsFixed(4)}',
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 18,
          child: FilledButton.icon(
            onPressed: _destination == null
                ? null
                : () => Navigator.of(context).pop(_destination),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF167C78),
              padding: const EdgeInsets.symmetric(vertical: 15),
            ),
            icon: const Icon(Icons.check),
            label: const Text('Confirm destination'),
          ),
        ),
      ],
    ),
  );
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
      if (!serviceEnabled) {
        throw Exception('Phone ki Location setting on karein.');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
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
      appBar: AppBar(
        title: const Text('Road reports'),
        actions: [
          PopupMenuButton<_RoadMapAction>(
            tooltip: 'More app options',
            onSelected: (action) => Navigator.of(context).pop(action),
            itemBuilder: (context) => const [
              PopupMenuItem(value: _RoadMapAction.home, child: Text('Home')),
              PopupMenuItem(
                value: _RoadMapAction.reports,
                child: Text('Reports'),
              ),
              PopupMenuItem(
                value: _RoadMapAction.profile,
                child: Text('Profile'),
              ),
              PopupMenuItem(
                value: _RoadMapAction.manualReport,
                child: Text('Report with GPS'),
              ),
              PopupMenuItem(
                value: _RoadMapAction.roadReview,
                child: Text('Review a road'),
              ),
            ],
          ),
        ],
      ),
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
  final double captureAspectRatio;
  final String captureAspectLabel;
  final bool smartMode;

  const CameraScreen({
    super.key,
    required this.cameras,
    required this.captureAspectRatio,
    required this.captureAspectLabel,
    this.smartMode = false,
  });

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _ScanLinePainter extends CustomPainter {
  final double progress;

  const _ScanLinePainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final y = progress * size.height;
    final glowPaint = Paint()
      ..color = const Color(0x334BFF9A)
      ..strokeWidth = 8
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawLine(Offset(0, y), Offset(size.width, y), glowPaint);

    final linePaint = Paint()
      ..shader = const LinearGradient(
        colors: [
          Color(0x004BFF9A),
          Color(0xB34BFF9A),
          Color(0xF0B3FFD1),
          Color(0xB34BFF9A),
          Color(0x004BFF9A),
        ],
      ).createShader(Rect.fromLTWH(0, y - 1, size.width, 2))
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
  }

  @override
  bool shouldRepaint(_ScanLinePainter oldDelegate) =>
      progress != oldDelegate.progress;
}

class _CameraScreenState extends State<CameraScreen>
    with SingleTickerProviderStateMixin {
  Future<void> runYoloInference(_PreparedImage preparedImage) async {
    final inputTensor = OrtValueTensor.createTensorWithDataList(
      preparedImage.tensor,
      [1, 3, 416, 416],
    );

    final inputs = {yoloSession.inputNames.first: inputTensor};

    final runOptions = OrtRunOptions();

    final outputs = await yoloSession.runAsync(runOptions, inputs);

    decodeYoloOutput(
      outputs!.first!.value as List<List<List<double>>>,
      preparedImage,
    );

    inputTensor.release();
    runOptions.release();

    for (final output in outputs) {
      output?.release();
    }
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

    _announceDetection();

    for (final detection in finalDetections) {
      final double confidence = detection['confidence']!;

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

      debugPrint(
        'AI pothole: ${(confidence * 100).toStringAsFixed(0)}% · $severity',
      );
    }
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
  late AnimationController _scanController;
  StreamSubscription<Position>? _locationSubscription;
  Timer? _smartUiTimer;
  final Stopwatch _recordingClock = Stopwatch();
  bool _isRecording = false;
  bool _isPaused = false;
  bool _videoBusy = false;
  bool _scanActive = false;
  bool _isFullscreen = false;
  bool _alertsMuted = true;
  bool _snapshotPending = false;
  bool _snapshotSaving = false;
  bool _closingSmartScreen = false;
  String? _lastSnapshotPath;
  String? _lastVideoPath;
  String? _smartError;
  double _fps = 0;
  int _fpsFrames = 0;
  DateTime _fpsWindowStart = DateTime.now();
  DateTime _lastVoiceAlert = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _hasDetections => detectedPotholes.isNotEmpty;

  String get _severityLabel {
    if (detectedPotholes.any((item) => item['severity'] == 'LARGE')) {
      return 'CRITICAL';
    }
    if (detectedPotholes.any((item) => item['severity'] == 'MEDIUM')) {
      return 'WARNING';
    }
    return _hasDetections ? 'MONITOR' : 'CLEAR';
  }

  Color get _severityColor => switch (_severityLabel) {
    'CRITICAL' => const Color(0xFFFF3B69),
    'WARNING' => const Color(0xFFFFC857),
    'MONITOR' => const Color(0xFF45D6F5),
    _ => const Color(0xFF58E39B),
  };

  double get _topConfidence => _hasDetections
      ? ((detectedPotholes.first['confidence'] as double) * 100)
      : 0;

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

    final coverScale = math.max(
      previewWidth / displayWidth,
      previewHeight / displayHeight,
    );
    final offsetX = (previewWidth - displayWidth * coverScale) / 2;
    final offsetY = (previewHeight - displayHeight * coverScale) / 2;

    return (
      left: displayLeft * coverScale + offsetX,
      top: displayTop * coverScale + offsetY,
      width: (displayRight - displayLeft) * coverScale,
      height: (displayBottom - displayTop) * coverScale,
    );
  }

  @override
  void initState() {
    super.initState();
    _scanController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2100),
    );

    final camera = widget.cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.back,
      orElse: () => widget.cameras.first,
    );
    cameraController = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    cameraFuture = cameraController.initialize().then((_) async {
      await _startDetection();
      if (widget.smartMode && mounted) {
        _setScanActive(true);
        unawaited(_startLocationTracking());
        _smartUiTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
          if (mounted) setState(() {});
        });
      }
    });
  }

  Future<void> _startDetection() async {
    if (!cameraController.value.isInitialized ||
        cameraController.value.isStreamingImages) {
      return;
    }

    await cameraController.startImageStream(_onCameraImage);
  }

  void _onCameraImage(CameraImage image) {
    if (!mounted ||
        isProcessingFrame ||
        _isCapturing ||
        _capturedPhotoPath != null ||
        (widget.smartMode && _isPaused)) {
      return;
    }
    isProcessingFrame = true;
    unawaited(_processCameraImage(image));
  }

  Future<void> _processCameraImage(CameraImage image) async {
    try {
      final convertedImage = convertCameraImage(image);
      if (widget.smartMode && _snapshotPending && !_snapshotSaving) {
        _snapshotPending = false;
        unawaited(_saveSmartSnapshot(convertedImage));
      }
      final preparedImage = imageToTensor(
        convertedImage,
        rotationDegrees: _frameRotationDegrees(),
        mirrorHorizontally:
            cameraController.description.lensDirection ==
            CameraLensDirection.front,
      );
      await runYoloInference(preparedImage);
      if (widget.smartMode) {
        _fpsFrames++;
        final now = DateTime.now();
        final elapsed = now.difference(_fpsWindowStart);
        if (elapsed >= const Duration(seconds: 1)) {
          _fps = _fpsFrames / elapsed.inMilliseconds * 1000;
          _fpsFrames = 0;
          _fpsWindowStart = now;
        }
      }
    } catch (error) {
      debugPrint('Could not process camera frame: $error');
      if (widget.smartMode && mounted) {
        setState(() => _smartError = 'AI frame processing paused: $error');
      }
    } finally {
      isProcessingFrame = false;
    }
  }

  Future<void> _startLocationTracking() async {
    try {
      final firstPosition = await _getPositionAfterCapture();
      if (!mounted) return;
      setState(() {
        currentPosition = firstPosition;
        _locationError = null;
      });
      _locationSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.bestForNavigation,
              distanceFilter: 2,
            ),
          ).listen(
            (position) {
              if (mounted) setState(() => currentPosition = position);
            },
            onError: (Object error) {
              if (mounted) setState(() => _locationError = error.toString());
            },
          );
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _locationError = error.toString().replaceFirst('Exception: ', ''),
        );
      }
    }
  }

  void _setScanActive(bool active) {
    if (_scanActive == active) return;
    _scanActive = active;
    if (active) {
      _scanController.repeat();
    } else {
      _scanController.stop();
    }
    if (mounted) setState(() {});
  }

  Future<void> _startSmartRecording() async {
    if (_videoBusy || _isRecording || !cameraController.value.isInitialized) {
      return;
    }
    setState(() {
      _videoBusy = true;
      _smartError = null;
      _lastVideoPath = null;
    });
    try {
      if (cameraController.value.isStreamingImages) {
        await cameraController.stopImageStream();
      }
      while (isProcessingFrame) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await cameraController.startVideoRecording(onAvailable: _onCameraImage);
      _recordingClock
        ..reset()
        ..start();
      _fpsFrames = 0;
      _fpsWindowStart = DateTime.now();
      if (mounted) {
        setState(() {
          _isRecording = true;
          _isPaused = false;
        });
      }
      _setScanActive(true);
    } catch (error) {
      if (mounted) {
        setState(() => _smartError = 'Recording could not start: $error');
        try {
          await _startDetection();
        } catch (restartError) {
          debugPrint('Could not restart AI camera stream: $restartError');
        }
      }
    } finally {
      if (mounted) setState(() => _videoBusy = false);
    }
  }

  Future<void> _toggleSmartPause() async {
    if (!_isRecording || _videoBusy) return;
    setState(() => _videoBusy = true);
    try {
      if (_isPaused) {
        await cameraController.resumeVideoRecording();
        _recordingClock.start();
        if (mounted) setState(() => _isPaused = false);
        _setScanActive(true);
      } else {
        await cameraController.pauseVideoRecording();
        _recordingClock.stop();
        if (mounted) setState(() => _isPaused = true);
        _setScanActive(false);
      }
    } catch (error) {
      if (mounted)
        setState(
          () => _smartError = 'Could not change recording state: $error',
        );
    } finally {
      if (mounted) setState(() => _videoBusy = false);
    }
  }

  Future<void> _stopSmartRecording({bool restartDetection = true}) async {
    if (!_isRecording || _videoBusy) return;
    setState(() => _videoBusy = true);
    _recordingClock.stop();
    try {
      final recordedFile = await cameraController.stopVideoRecording();
      if (mounted) {
        setState(() {
          _isRecording = false;
          _isPaused = false;
        });
      }
      final directoryPath = await _roadAppChannel.invokeMethod<String>(
        'getRoadVideoDirectory',
      );
      if (directoryPath == null) {
        throw Exception('Phone video storage is unavailable.');
      }
      final directory = Directory(directoryPath);
      await directory.create(recursive: true);
      final destination = File(
        '${directory.path}${Platform.pathSeparator}'
        'road_scan_${DateTime.now().millisecondsSinceEpoch}.mp4',
      );
      await File(recordedFile.path).copy(destination.path);
      try {
        await File(recordedFile.path).delete();
      } catch (_) {
        // The camera plugin may already have removed its temporary recording.
      }
      if (mounted) {
        setState(() {
          _lastVideoPath = destination.path;
          _isRecording = false;
          _isPaused = false;
          _smartError = null;
        });
      }
      if (restartDetection && mounted && !_closingSmartScreen) {
        await _startDetection();
        _setScanActive(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _smartError = 'Recording could not be saved: $error');
      }
    } finally {
      if (mounted) setState(() => _videoBusy = false);
    }
  }

  Future<void> _saveSmartSnapshot(img.Image frame) async {
    if (mounted) setState(() => _snapshotSaving = true);
    try {
      final photoDirectory = await _roadAppChannel.invokeMethod<String>(
        'getRoadPhotoDirectory',
      );
      if (photoDirectory == null) {
        throw Exception('Phone snapshot storage is unavailable.');
      }
      final directory = Directory(photoDirectory);
      await directory.create(recursive: true);
      final file = File(
        '${directory.path}${Platform.pathSeparator}'
        'scan_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await file.writeAsBytes(img.encodeJpg(frame, quality: 90));
      if (mounted) {
        setState(() {
          _lastSnapshotPath = file.path;
          _smartError = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Snapshot saved on this phone.')),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _smartError = 'Snapshot failed: $error');
    } finally {
      if (mounted) setState(() => _snapshotSaving = false);
    }
  }

  void _requestSmartSnapshot() {
    if (_isPaused || _snapshotSaving || _snapshotPending) return;
    if (!cameraController.value.isStreamingImages) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Start live detection before taking a snapshot.'),
        ),
      );
      return;
    }
    setState(() => _snapshotPending = true);
  }

  Future<void> _toggleVoiceAlerts() async {
    final muted = !_alertsMuted;
    setState(() => _alertsMuted = muted);
    if (muted) {
      try {
        await _roadAppChannel.invokeMethod<bool>('stopVoiceAlert');
      } catch (_) {
        // Muting voice alerts should still update the on-screen state.
      }
    } else if (_hasDetections) {
      _announceDetection();
    }
  }

  void _announceDetection() {
    final now = DateTime.now();
    if (!widget.smartMode ||
        _alertsMuted ||
        !_hasDetections ||
        now.difference(_lastVoiceAlert) < const Duration(seconds: 15)) {
      return;
    }
    _lastVoiceAlert = now;
    unawaited(
      _roadAppChannel
          .invokeMethod<bool>('speakVoiceAlert', {
            'message': _severityLabel == 'CRITICAL'
                ? 'Critical road pothole detected ahead.'
                : 'Road surface hazard detected ahead.',
          })
          .catchError((_) => false),
    );
  }

  Future<void> _toggleFullscreen() async {
    final fullscreen = !_isFullscreen;
    await SystemChrome.setEnabledSystemUIMode(
      fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    if (mounted) setState(() => _isFullscreen = fullscreen);
  }

  Future<void> _closeSmartScreen() async {
    if (_closingSmartScreen) return;
    _closingSmartScreen = true;
    while (_videoBusy) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (_isRecording) {
      await _stopSmartRecording(restartDetection: false);
    }
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (mounted) Navigator.of(context).pop();
  }

  String get _recordingTimeLabel {
    final elapsed = _recordingClock.elapsed;
    final minutes = elapsed.inMinutes.toString().padLeft(2, '0');
    final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
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
    final decoded = img.decodeImage(await File(sourcePath).readAsBytes());
    if (decoded == null) {
      throw Exception('The camera returned an unreadable photo.');
    }
    final oriented = img.bakeOrientation(decoded);
    final sourceAspect = oriented.width / oriented.height;
    late final int cropWidth;
    late final int cropHeight;
    if (sourceAspect > widget.captureAspectRatio) {
      cropHeight = oriented.height;
      cropWidth = (cropHeight * widget.captureAspectRatio).round();
    } else {
      cropWidth = oriented.width;
      cropHeight = (cropWidth / widget.captureAspectRatio).round();
    }
    final cropped = img.copyCrop(
      oriented,
      x: (oriented.width - cropWidth) ~/ 2,
      y: (oriented.height - cropHeight) ~/ 2,
      width: cropWidth,
      height: cropHeight,
    );
    await savedFile.writeAsBytes(img.encodeJpg(cropped, quality: 95));
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

  String get _detectionStatusLabel {
    if (_isRecording && _isPaused) return 'RECORDING PAUSED';
    if (_isRecording) return 'RECORDING · LIVE AI';
    if (_scanActive) return 'LIVE AI SCANNING';
    return 'DETECTION STOPPED';
  }

  Widget _buildSmartPreview(double width) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final previewWidth = constraints.maxWidth;
          final previewHeight = constraints.maxHeight;
          final sensorPreviewAspect = 1 / cameraController.value.aspectRatio;
          final compactWidth = math.min(220.0, previewWidth * .53).toDouble();
          return Stack(
            fit: StackFit.expand,
            children: [
              FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: sensorPreviewAspect * 1000,
                  height: 1000,
                  child: CameraPreview(cameraController),
                ),
              ),
              ...detectedPotholes.map((pothole) {
                final box = _previewBox(pothole, previewWidth, previewHeight);
                final severity = pothole['severity'] as String? ?? 'SMALL';
                final color = severity == 'LARGE'
                    ? const Color(0xFFFF3B69)
                    : severity == 'MEDIUM'
                    ? const Color(0xFFFFC857)
                    : const Color(0xFF45D6F5);
                return Positioned(
                  left: box.left,
                  top: box.top,
                  width: box.width,
                  height: box.height,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: color, width: 2),
                    ),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        color: color,
                        child: Text(
                          'POTHOLE ${((pothole['confidence'] as double) * 100).toStringAsFixed(0)}%',
                          maxLines: 1,
                          style: const TextStyle(
                            color: Color(0xFF07131B),
                            fontSize: 8,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
              if (_scanActive)
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _scanController,
                      builder: (context, _) => CustomPaint(
                        painter: _ScanLinePainter(_scanController.value),
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: 10,
                top: 10,
                child: _buildCompactDetectionCard(compactWidth),
              ),
              Positioned(
                right: 4,
                top: 2,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildHudStatusChip(),
                    if (_isFullscreen) ...[
                      IconButton(
                        tooltip: _alertsMuted
                            ? 'Turn on voice alerts'
                            : 'Mute voice alerts',
                        onPressed: _toggleVoiceAlerts,
                        visualDensity: VisualDensity.compact,
                        color: _alertsMuted
                            ? Colors.white70
                            : const Color(0xFF58E39B),
                        icon: Icon(
                          _alertsMuted ? Icons.volume_off : Icons.volume_up,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close live detection',
                        onPressed: _closeSmartScreen,
                        visualDensity: VisualDensity.compact,
                        color: Colors.white,
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ],
                ),
              ),
              Positioned(
                left: 10,
                bottom: 10,
                child: _buildCompactHazardCard(compactWidth),
              ),
              if (_isFullscreen)
                Positioned(
                  right: 10,
                  bottom: 76,
                  child: FloatingActionButton.small(
                    heroTag: 'exit-smart-fullscreen',
                    onPressed: _toggleFullscreen,
                    backgroundColor: const Color(0xDD0A1420),
                    foregroundColor: const Color(0xFF4BE8F3),
                    child: const Icon(Icons.fullscreen_exit),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCompactDetectionCard(double width) => Container(
    width: width,
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: const Color(0xE90A1420),
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: const Color(0xFF00DCEB).withValues(alpha: .7)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _hasDetections
              ? 'DEFECT · ${detectedPotholes.length}'
              : 'AI ROAD SCAN',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFF54EAF4),
            fontSize: 10,
            fontWeight: FontWeight.w900,
            letterSpacing: .4,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          _hasDetections
              ? 'Pothole · ${_topConfidence.toStringAsFixed(0)}% confidence'
              : 'No road defect in this frame',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 9),
        ),
      ],
    ),
  );

  Widget _buildHudStatusChip() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xE90A1420),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _severityColor.withValues(alpha: .8)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 7, color: _severityColor),
        const SizedBox(width: 5),
        Text(
          _detectionStatusLabel,
          style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w900),
        ),
      ],
    ),
  );

  Widget _buildCompactHazardCard(double width) => Container(
    width: width,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: const Color(0xE90A1420),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: _severityColor.withValues(alpha: .8)),
    ),
    child: Row(
      children: [
        Icon(
          _hasDetections
              ? Icons.warning_amber_rounded
              : Icons.verified_outlined,
          color: _severityColor,
          size: 18,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _hasDetections
                ? 'HAZARD · $_severityLabel · ${detectedPotholes.length} ahead'
                : 'ROAD STATUS · CLEAR',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _severityColor,
              fontSize: 10,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        if (_isRecording)
          Text(
            _recordingTimeLabel,
            style: const TextStyle(
              color: Colors.white,
              fontFeatures: [FontFeature.tabularFigures()],
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
      ],
    ),
  );

  Widget _buildSmartMetric(
    String label,
    String value,
    IconData icon, {
    Color color = const Color(0xFF43DAE9),
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
    decoration: BoxDecoration(
      color: const Color(0xFF0D1722),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0xFF1D3543)),
    ),
    child: Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 7),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 8,
                  letterSpacing: .5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _buildSmartMetrics(double width) {
    final tileWidth = width >= 700 ? (width - 36) / 4 : (width - 30) / 2;
    final position = currentPosition;
    final gpsLabel = position == null
        ? (_locationError == null ? 'GPS WAIT' : 'GPS OFF')
        : '${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)}';
    final speedLabel = position == null
        ? '-- km/h'
        : '${(position.speed * 3.6).clamp(0, 300).toStringAsFixed(0)} km/h';
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        SizedBox(
          width: tileWidth,
          child: _buildSmartMetric(
            'Detections',
            '${detectedPotholes.length}',
            Icons.center_focus_strong,
          ),
        ),
        SizedBox(
          width: tileWidth,
          child: _buildSmartMetric(
            'Speed',
            speedLabel,
            Icons.speed,
            color: const Color(0xFF8FE8B3),
          ),
        ),
        SizedBox(
          width: tileWidth,
          child: _buildSmartMetric(
            'GPS',
            gpsLabel,
            Icons.my_location,
            color: const Color(0xFF8FE8B3),
          ),
        ),
        SizedBox(
          width: tileWidth,
          child: _buildSmartMetric(
            'FPS / Confidence',
            '${_fps.toStringAsFixed(1)} / ${_topConfidence.toStringAsFixed(0)}%',
            Icons.memory,
            color: const Color(0xFFFFC857),
          ),
        ),
      ],
    );
  }

  Widget _buildSmartControls() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (!_isRecording)
        FilledButton.icon(
          onPressed: _videoBusy ? null : _startSmartRecording,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF00DCEB),
            foregroundColor: const Color(0xFF07131B),
            padding: const EdgeInsets.symmetric(vertical: 13),
          ),
          icon: _videoBusy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.fiber_manual_record),
          label: Text(_videoBusy ? 'STARTING…' : 'START RECORDING'),
        )
      else
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _videoBusy ? null : _toggleSmartPause,
                icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
                label: Text(_isPaused ? 'RESUME' : 'PAUSE'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF62D6B2),
                  side: const BorderSide(color: Color(0xFF287C70)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: FilledButton.icon(
                onPressed: _videoBusy ? null : _stopSmartRecording,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFAF3151),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                icon: _videoBusy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.stop_circle_outlined),
                label: const Text('STOP & SAVE'),
              ),
            ),
          ],
        ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _snapshotSaving || _snapshotPending || _isPaused
            ? null
            : _requestSmartSnapshot,
        icon: _snapshotSaving || _snapshotPending
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.camera_alt_outlined),
        label: Text(
          _snapshotSaving || _snapshotPending
              ? 'CAPTURING SNAPSHOT…'
              : 'SNAPSHOT',
        ),
      ),
      if (_lastVideoPath != null) ...[
        const SizedBox(height: 6),
        Text(
          'Video saved · ${_lastVideoPath!.split(Platform.pathSeparator).last}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xFF8FE8B3), fontSize: 10),
        ),
      ],
      if (_lastSnapshotPath != null) ...[
        const SizedBox(height: 4),
        Text(
          'Snapshot saved · ${_lastSnapshotPath!.split(Platform.pathSeparator).last}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white54, fontSize: 10),
        ),
      ],
      if (_smartError != null) ...[
        const SizedBox(height: 6),
        Text(
          _smartError!,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xFFFFC857), fontSize: 11),
        ),
      ],
    ],
  );

  Widget _buildSmartScreen() => PopScope<Object?>(
    canPop: !_isRecording,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) unawaited(_closeSmartScreen());
    },
    child: Scaffold(
      backgroundColor: const Color(0xFF070D16),
      appBar: _isFullscreen
          ? null
          : AppBar(
              backgroundColor: const Color(0xFF070D16),
              title: const Text('SMART ROAD SCAN'),
              titleTextStyle: const TextStyle(
                color: Color(0xFFE4F6FA),
                fontSize: 16,
                fontWeight: FontWeight.w900,
                letterSpacing: .8,
              ),
              leading: IconButton(
                tooltip: 'Close camera',
                onPressed: _closeSmartScreen,
                icon: const Icon(Icons.close),
              ),
              actions: [
                IconButton(
                  tooltip: _alertsMuted
                      ? 'Turn on voice alerts'
                      : 'Mute voice alerts',
                  onPressed: _toggleVoiceAlerts,
                  icon: Icon(_alertsMuted ? Icons.volume_off : Icons.volume_up),
                ),
                IconButton(
                  tooltip: 'Toggle fullscreen',
                  onPressed: _toggleFullscreen,
                  icon: const Icon(Icons.fullscreen),
                ),
              ],
            ),
      body: SafeArea(
        top: !_isFullscreen,
        bottom: !_isFullscreen,
        child: FutureBuilder<void>(
          future: cameraFuture,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.videocam_off,
                        size: 42,
                        color: Colors.white54,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Camera or live detection is unavailable.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${snapshot.error}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: _closeSmartScreen,
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('Back'),
                      ),
                    ],
                  ),
                ),
              );
            }
            if (snapshot.connectionState != ConnectionState.done ||
                !cameraController.value.isInitialized) {
              return const Center(child: CircularProgressIndicator());
            }
            return LayoutBuilder(
              builder: (context, constraints) {
                final wideLayout = constraints.maxWidth >= 760;
                final preview = Padding(
                  padding: EdgeInsets.all(wideLayout ? 12 : 8),
                  child: _buildSmartPreview(constraints.maxWidth),
                );
                final panel = ListView(
                  padding: EdgeInsets.fromLTRB(
                    wideLayout ? 12 : 10,
                    wideLayout ? 12 : 6,
                    wideLayout ? 12 : 10,
                    12,
                  ),
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'LIVE TELEMETRY',
                            style: TextStyle(
                              color: Color(0xFF54EAF4),
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              letterSpacing: .8,
                            ),
                          ),
                        ),
                        if (_isRecording)
                          Text(
                            _recordingTimeLabel,
                            style: const TextStyle(
                              color: Color(0xFFFF687F),
                              fontFeatures: [FontFeature.tabularFigures()],
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _buildSmartMetrics(constraints.maxWidth),
                    const SizedBox(height: 10),
                    _buildSmartControls(),
                  ],
                );
                if (wideLayout) {
                  return Row(
                    children: [
                      Expanded(flex: 7, child: preview),
                      SizedBox(width: 390, child: panel),
                    ],
                  );
                }
                return Column(
                  children: [
                    Expanded(flex: 7, child: preview),
                    Flexible(flex: 4, child: panel),
                  ],
                );
              },
            );
          },
        ),
      ),
    ),
  );

  @override
  void dispose() {
    _smartUiTimer?.cancel();
    _locationSubscription?.cancel();
    _scanController.dispose();
    if (_isFullscreen) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    if (cameraController.value.isRecordingVideo) {
      unawaited(() async {
        try {
          await cameraController.stopVideoRecording();
        } catch (error) {
          debugPrint('Could not stop video during camera cleanup: $error');
        }
      }());
    }
    cameraController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.smartMode) return _buildSmartScreen();
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
            final previewWidth = MediaQuery.sizeOf(context).width - 32;
            final previewHeight = previewWidth / widget.captureAspectRatio;

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                const Text(
                  'Point the camera at the pothole',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  'Capture frame: ${widget.captureAspectLabel}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: previewWidth,
                  height: previewHeight,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final photoPath = _capturedPhotoPath;
                        if (photoPath != null) {
                          return Image.file(File(photoPath), fit: BoxFit.cover);
                        }

                        final previewWidth = constraints.maxWidth;
                        final previewActualHeight = constraints.maxHeight;
                        final sensorPreviewAspect =
                            1 / cameraController.value.aspectRatio;
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            FittedBox(
                              fit: BoxFit.cover,
                              child: SizedBox(
                                width: sensorPreviewAspect * 1000,
                                height: 1000,
                                child: CameraPreview(cameraController),
                              ),
                            ),
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
                        );
                      },
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
