import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'shared_reports_repository.dart';

class ProfileAccountRepository {
  static const profilePhotoBucket = 'profile-photos';
  static const authRedirect = 'potholeai://auth-callback';

  final SharedReportsRepository reportsRepository;

  ProfileAccountRepository(this.reportsRepository);

  SupabaseClient get client {
    final configured = reportsRepository.client;
    if (configured == null) throw StateError('Cloud account is unavailable.');
    return configured;
  }

  User get currentUser {
    final user = client.auth.currentUser;
    if (user == null) {
      throw const AuthException('Sign in to open your profile.');
    }
    return user;
  }

  Future<Map<String, dynamic>> loadProfile() async {
    final user = currentUser;
    final rows = client.from('profiles');
    final existing = await rows
        .select(
          'id,full_name,phone,recovery_email,avatar_path,account_language,dark_mode,updated_at',
        )
        .eq('id', user.id)
        .maybeSingle();
    if (existing != null) return existing;

    // The UUID comes from the active Auth session. The primary-key conflict
    // target makes this safe if the auth trigger created the row concurrently.
    return await rows
        .upsert({
          'id': user.id,
          'full_name': (user.userMetadata?['full_name'] as String?) ?? '',
        }, onConflict: 'id')
        .select(
          'id,full_name,phone,recovery_email,avatar_path,account_language,dark_mode,updated_at',
        )
        .single();
  }

  Future<Map<String, dynamic>> updateProfile(
    Map<String, Object?> values,
  ) async {
    try {
      return await client
          .from('profiles')
          .update(values)
          .eq('id', currentUser.id)
          .select(
            'id,full_name,phone,recovery_email,avatar_path,account_language,dark_mode,updated_at',
          )
          .single();
    } catch (error) {
      logSupabaseError('save profile', error);
      rethrow;
    }
  }

  Future<String?> createAvatarUrl(String? path) async {
    if (path == null || path.isEmpty) return null;
    return await client.storage
        .from(profilePhotoBucket)
        .createSignedUrl(path, 3600);
  }

  Future<Map<String, dynamic>> uploadAvatar(
    File file, {
    String? previousPath,
  }) async {
    if (!await file.exists()) throw const FormatException('Photo not found.');
    final source = await file.readAsBytes();
    final decoded = img.decodeImage(source);
    if (decoded == null) throw const FormatException('Choose a valid photo.');
    final resized = decoded.width > 512 || decoded.height > 512
        ? img.copyResize(
            decoded,
            width: decoded.width >= decoded.height ? 512 : null,
            height: decoded.height > decoded.width ? 512 : null,
            maintainAspect: true,
          )
        : decoded;
    final bytes = Uint8List.fromList(img.encodeJpg(resized, quality: 82));
    final userId = currentUser.id;
    final path = '$userId/avatar-${DateTime.now().microsecondsSinceEpoch}.jpg';
    await client.storage
        .from(profilePhotoBucket)
        .uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(contentType: 'image/jpeg'),
        );
    late final Map<String, dynamic> profile;
    try {
      profile = await updateProfile({'avatar_path': path});
    } catch (_) {
      await client.storage.from(profilePhotoBucket).remove([path]);
      rethrow;
    }
    if (previousPath != null && previousPath.isNotEmpty) {
      try {
        await client.storage.from(profilePhotoBucket).remove([previousPath]);
      } catch (_) {
        // Keep the successfully saved avatar if stale-object cleanup fails.
      }
    }
    return profile;
  }

  Future<Map<String, dynamic>> removeAvatar(String? previousPath) async {
    final profile = await updateProfile({'avatar_path': null});
    if (previousPath != null && previousPath.isNotEmpty) {
      try {
        await client.storage.from(profilePhotoBucket).remove([previousPath]);
      } catch (_) {
        // The profile has already been detached from the object.
      }
    }
    return profile;
  }

  Future<List<Map<String, dynamic>>> loadNotifications() async {
    return await client
        .from('user_notifications')
        .select('id,title,body,created_at,read_at')
        .eq('user_id', currentUser.id)
        .order('created_at', ascending: false)
        .limit(100);
  }

  Future<void> markNotificationRead(String id) async {
    await client
        .from('user_notifications')
        .update({'read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', id)
        .eq('user_id', currentUser.id);
  }

  Future<void> markAllNotificationsRead() async {
    await client
        .from('user_notifications')
        .update({'read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('user_id', currentUser.id)
        .isFilter('read_at', null);
  }

  Future<void> changeEmail(String email) async {
    await client.auth.updateUser(
      UserAttributes(email: email),
      emailRedirectTo: authRedirect,
    );
  }

  Future<void> changePassword(String password) async {
    await client.auth.updateUser(UserAttributes(password: password));
  }

  Future<void> resendVerification() async {
    final user = currentUser;
    final email = user.newEmail ?? user.email;
    if (email == null || email.isEmpty) {
      throw const AuthException('There is no account email to verify.');
    }
    await client.auth.resend(
      type: user.newEmail == null ? OtpType.signup : OtpType.emailChange,
      email: email,
      emailRedirectTo: authRedirect,
    );
  }

  Future<void> deleteAccount() async {
    await client.rpc('delete_my_account');
    await client.auth.signOut();
  }

  static String friendlyError(Object error) {
    if (error is SocketException || error is TimeoutException) {
      return 'Could not reach Supabase. Check your internet connection and retry.';
    }
    if (error is AuthException) {
      final code = error.code?.toLowerCase() ?? '';
      if (code.contains('session') || code.contains('jwt') || code == '401') {
        return 'Your sign-in session has expired. Sign in again to load your profile.';
      }
      if (code.contains('invalid_credentials')) {
        return 'Email or password is incorrect.';
      }
      if (code.contains('email_not_confirmed')) {
        return 'Verify your email before signing in.';
      }
      if (code.contains('user_already_exists')) {
        return 'An account already exists for this email. Try signing in.';
      }
      if (code.contains('weak_password')) {
        return 'Choose a stronger password with at least 8 characters.';
      }
      return 'The account request could not be completed. Check your details and try again.';
    }
    if (error is FormatException) return error.message.toString();
    if (error is PostgrestException) {
      final responseCode = _postgrestResponseCode(error);
      if (error.code == '42P01' ||
          error.code == 'PGRST205' ||
          responseCode == '42P01' ||
          responseCode == 'PGRST205' ||
          error.message.toLowerCase().contains(
            "could not find the table 'public.profiles'",
          )) {
        return 'The Supabase profiles table is missing. Apply database/supabase_profile_account.sql in the Supabase SQL Editor.';
      }
      if (error.code == '42501' || responseCode == '42501') {
        return 'Supabase denied access to this profile. Check the profiles RLS policies in the profile account migration.';
      }
      if (error.code == 'PGRST204' || responseCode == 'PGRST204') {
        return 'The Supabase profiles table is missing required columns. Apply the latest profile account migration.';
      }
      if (error.code == '23505') return 'That phone number is already in use.';
      return 'Supabase could not save the profile (code ${error.code ?? 'unknown'}). Check the app debug log and retry.';
    }
    if (error is StorageException) {
      return 'The photo could not be uploaded. Check your connection and try again.';
    }
    return 'Something went wrong. Check your connection and try again.';
  }

  static String? _postgrestResponseCode(PostgrestException error) {
    try {
      final response = jsonDecode(error.message);
      if (response is Map<String, dynamic>) {
        return response['code'] as String?;
      }
    } catch (_) {
      // PostgREST messages are often already plain strings.
    }
    return null;
  }

  /// Logs diagnostic details only in debug builds; never logs credentials or
  /// profile values. This lets development identify schema/RLS failures while
  /// keeping production UI free of database internals.
  static void logSupabaseError(String operation, Object error) {
    if (!kDebugMode) return;
    if (error is PostgrestException) {
      debugPrint(
        'Supabase $operation failed: message=${error.message}; '
        'code=${error.code}; details=${error.details}; hint=${error.hint}',
      );
    } else if (error is AuthException) {
      debugPrint(
        'Supabase $operation failed: message=${error.message}; '
        'code=${error.code}',
      );
    } else if (error is StorageException) {
      debugPrint(
        'Supabase $operation failed: message=${error.message}; '
        'statusCode=${error.statusCode}',
      );
    } else {
      debugPrint('Supabase $operation failed: ${error.runtimeType}: $error');
    }
  }
}
