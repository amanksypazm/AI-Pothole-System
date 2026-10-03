import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Cloud sync stays disabled until the app is built with a Supabase project.
/// Never put a Supabase secret/service-role key in this mobile app.
class SharedReportsRepository {
  static const _projectUrl = String.fromEnvironment('SUPABASE_URL');
  static const _publishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );
  static const _photoBucket = 'road-report-photos';

  SupabaseClient? _client;

  bool get isConfigured => _projectUrl.isNotEmpty && _publishableKey.isNotEmpty;

  Future<void> initialize() async {
    if (!isConfigured) return;

    await Supabase.initialize(
      url: _projectUrl,
      publishableKey: _publishableKey,
    );
    _client = Supabase.instance.client;
  }

  Future<void> _ensureSignedIn(SupabaseClient client) async {
    if (client.auth.currentUser == null) {
      await client.auth.signInAnonymously();
    }
  }

  Future<String?> currentUserId() async {
    final client = _client;
    if (client == null) return null;
    await _ensureSignedIn(client);
    return client.auth.currentUser?.id;
  }

  String? get currentEmail => _client?.auth.currentUser?.email;

  Future<void> linkOptionalEmail(String email) async {
    final client = _client;
    if (client == null) {
      throw StateError('Supabase setup is unavailable.');
    }
    await _ensureSignedIn(client);
    await client.auth.updateUser(UserAttributes(email: email));
  }

  Future<void> saveReport(Map<String, Object?> report) async {
    final client = _client;
    if (client == null) return;

    await _ensureSignedIn(client);
    final reporterId = client.auth.currentUser?.id;
    if (reporterId == null) {
      throw StateError('Could not create an anonymous report account.');
    }

    String? photoStoragePath;
    final photoPath = report['photoPath'] as String?;
    if (photoPath != null && await File(photoPath).exists()) {
      photoStoragePath = '$reporterId/${report['clientId']}.jpg';
      await client.storage
          .from(_photoBucket)
          .upload(
            photoStoragePath,
            File(photoPath),
            fileOptions: const FileOptions(
              upsert: true,
              contentType: 'image/jpeg',
            ),
          );
    }

    await client
        .from('road_reports')
        .upsert(
          {
            'client_id': report['clientId'],
            'reporter_id': reporterId,
            'issue_type': report['issueType'],
            'severity': report['severity'],
            'description': report['description'],
            'latitude': report['latitude'],
            'longitude': report['longitude'],
            'accuracy_meters': report['accuracyMeters'],
            'photo_storage_path': photoStoragePath,
            'created_at': report['createdAt'],
          },
          onConflict: 'client_id',
          ignoreDuplicates: true,
        );

    // A retry of a locally queued report may find its row already inserted.
    // Update only the photo path of the report belonging to this signed-in user.
    if (photoStoragePath != null) {
      await client
          .from('road_reports')
          .update({'photo_storage_path': photoStoragePath})
          .eq('client_id', report['clientId'] as String)
          .eq('reporter_id', reporterId);
    }
  }

  Future<List<Map<String, dynamic>>> fetchReports() async {
    final client = _client;
    if (client == null) return const [];

    await _ensureSignedIn(client);
    final rows = await client
        .from('road_reports')
        .select(
          'client_id, issue_type, severity, description, latitude, longitude, '
          'accuracy_meters, photo_storage_path, created_at',
        )
        .order('created_at', ascending: false)
        .limit(1000);

    final reports = <Map<String, dynamic>>[];
    for (final row in rows) {
      final photoPath = row['photo_storage_path'] as String?;
      final photoUrl = photoPath == null
          ? null
          : await client.storage
                .from(_photoBucket)
                .createSignedUrl(photoPath, 3600);
      reports.add({
        'clientId': row['client_id'],
        'issueType': row['issue_type'],
        'severity': row['severity'],
        'description': row['description'] ?? '',
        'latitude': row['latitude'],
        'longitude': row['longitude'],
        'accuracyMeters': row['accuracy_meters'],
        'photoPath': null,
        'photoUrl': photoUrl,
        'createdAt': row['created_at'],
      });
    }
    return reports;
  }

  Future<void> saveRoadReview(Map<String, Object?> review) async {
    final client = _client;
    if (client == null) return;
    await _ensureSignedIn(client);
    final reviewerId = client.auth.currentUser?.id;
    if (reviewerId == null) {
      throw StateError('Could not create a road-review account.');
    }
    await client
        .from('road_reviews')
        .upsert(
          {
            'client_id': review['clientId'],
            'reviewer_id': reviewerId,
            'start_latitude': review['startLatitude'],
            'start_longitude': review['startLongitude'],
            'end_latitude': review['endLatitude'],
            'end_longitude': review['endLongitude'],
            'route_points': review['routePoints'],
            'distance_meters': review['distanceMeters'],
            'duration_seconds': review['durationSeconds'],
            'rating': review['rating'],
            'recommend': review['recommend'],
            'comment': review['comment'],
            'created_at': review['createdAt'],
          },
          onConflict: 'client_id',
          ignoreDuplicates: true,
        );
  }

  Future<List<Map<String, dynamic>>> fetchRoadReviews() async {
    final client = _client;
    if (client == null) return const [];
    await _ensureSignedIn(client);
    return await client
        .from('road_reviews')
        .select(
          'client_id, start_latitude, start_longitude, end_latitude, '
          'end_longitude, route_points, distance_meters, duration_seconds, '
          'rating, recommend, comment, created_at',
        )
        .order('created_at', ascending: false)
        .limit(500);
  }
}
