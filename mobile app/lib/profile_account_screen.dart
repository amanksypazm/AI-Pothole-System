import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'account_auth_screen.dart';
import 'profile_account_repository.dart';
import 'shared_reports_repository.dart';

class ProfileAccountScreen extends StatefulWidget {
  final SharedReportsRepository repository;
  final VoidCallback onBack;
  final ValueChanged<bool> onDarkModeChanged;
  final ValueChanged<String> onLanguageChanged;

  const ProfileAccountScreen({
    super.key,
    required this.repository,
    required this.onBack,
    required this.onDarkModeChanged,
    required this.onLanguageChanged,
  });

  @override
  State<ProfileAccountScreen> createState() => _ProfileAccountScreenState();
}

class _ProfileAccountScreenState extends State<ProfileAccountScreen> {
  static const _profileChannel = MethodChannel(
    'com.example.pothole_app/road_tools',
  );

  late final ProfileAccountRepository _account;
  Map<String, dynamic>? _profile;
  String? _avatarUrl;
  String? _localAvatarPath;
  String? _loadError;
  int _unreadCount = 0;
  bool _loading = false;
  bool _saving = false;

  SupabaseClient get _client => widget.repository.client!;
  User? get _user => _client.auth.currentUser;
  bool get _darkMode => _profile?['dark_mode'] as bool? ?? false;
  String get _language => _profile?['account_language'] as String? ?? 'en';
  bool get _hindi => _language == 'hi';

  @override
  void initState() {
    super.initState();
    _account = ProfileAccountRepository(widget.repository);
    _load();
  }

  String _t(String english, String hindi) => _hindi ? hindi : english;

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final profile = await _account.loadProfile();
      final avatarUrl = await _account.createAvatarUrl(
        profile['avatar_path'] as String?,
      );
      int unread = 0;
      try {
        final notifications = await _account.loadNotifications();
        unread = notifications.where((item) => item['read_at'] == null).length;
      } catch (_) {
        // The Profile tab still works if notifications have not been configured.
      }
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _avatarUrl = avatarUrl;
        _unreadCount = unread;
      });
      final isDark = profile['dark_mode'] as bool? ?? false;
      final language = profile['account_language'] as String? ?? 'en';
      widget.onDarkModeChanged(isDark);
      widget.onLanguageChanged(language);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('profileDarkMode_${_user?.id}', isDark);
      await prefs.setString('profileAccountLanguage_${_user?.id}', language);
    } catch (error) {
      ProfileAccountRepository.logSupabaseError('open profile', error);
      if (mounted) {
        setState(
          () => _loadError = ProfileAccountRepository.friendlyError(error),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _message(String text, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  Future<void> _editField(String field) async {
    if (_profile == null || _saving) return;
    final current = switch (field) {
      'full_name' => _profile!['full_name'] as String? ?? '',
      'phone' => _profile!['phone'] as String? ?? '',
      _ => _profile!['recovery_email'] as String? ?? '',
    };
    final controller = TextEditingController(text: current);
    final label = switch (field) {
      'full_name' => _t('Full Name', 'पूरा नाम'),
      'phone' => _t('Phone', 'फ़ोन'),
      _ => _t('Recovery Email', 'रिकवरी ईमेल'),
    };
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: field == 'phone'
              ? TextInputType.phone
              : field == 'recovery_email'
              ? TextInputType.emailAddress
              : TextInputType.name,
          textCapitalization: field == 'full_name'
              ? TextCapitalization.words
              : TextCapitalization.none,
          decoration: InputDecoration(hintText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(_t('Cancel', 'रद्द करें')),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: Text(_t('Save', 'सेव करें')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || !mounted) return;
    final error = switch (field) {
      'full_name' =>
        value.isEmpty || value.length > 100
            ? _t(
                'Enter a name up to 100 characters.',
                '100 अक्षरों तक का नाम लिखें।',
              )
            : null,
      'phone' =>
        value.isNotEmpty && !RegExp(r'^\+?[0-9(). -]{7,25}$').hasMatch(value)
            ? _t('Enter a valid phone number.', 'सही फ़ोन नंबर लिखें।')
            : null,
      _ =>
        value.isNotEmpty &&
                !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value)
            ? _t('Enter a valid email address.', 'सही ईमेल पता लिखें।')
            : null,
    };
    if (error != null) {
      _message(error, error: true);
      return;
    }
    await _saveValues({field: value});
  }

  Future<void> _saveValues(Map<String, Object?> values) async {
    setState(() => _saving = true);
    try {
      final updated = await _account.updateProfile(values);
      if (!mounted) return;
      setState(() => _profile = updated);
      _message(_t('Profile updated.', 'प्रोफ़ाइल अपडेट हो गई।'));
    } catch (error) {
      _message(ProfileAccountRepository.friendlyError(error), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setLanguage(String language) async {
    if (language == _language || _saving) return;
    setState(() => _saving = true);
    try {
      final updated = await _account.updateProfile({
        'account_language': language,
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('profileAccountLanguage_${_user?.id}', language);
      if (!mounted) return;
      setState(() => _profile = updated);
      widget.onLanguageChanged(language);
    } catch (error) {
      _message(ProfileAccountRepository.friendlyError(error), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setDarkMode(bool enabled) async {
    setState(() => _saving = true);
    try {
      final updated = await _account.updateProfile({'dark_mode': enabled});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('profileDarkMode_${_user?.id}', enabled);
      if (!mounted) return;
      setState(() => _profile = updated);
      widget.onDarkModeChanged(enabled);
    } catch (error) {
      _message(ProfileAccountRepository.friendlyError(error), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _chooseAvatar({bool useCamera = false}) async {
    try {
      final path = await _profileChannel.invokeMethod<String>(
        useCamera ? 'captureProfilePhoto' : 'pickProfilePhoto',
      );
      if (path == null || !mounted) return;
      final file = File(path);
      setState(() {
        _saving = true;
        _localAvatarPath = path;
      });
      final oldPath = _profile?['avatar_path'] as String?;
      final updated = await _account.uploadAvatar(file, previousPath: oldPath);
      final signedUrl = await _account.createAvatarUrl(
        updated['avatar_path'] as String?,
      );
      if (!mounted) return;
      setState(() {
        _profile = updated;
        _avatarUrl = signedUrl;
        _localAvatarPath = null;
      });
      _message(_t('Profile photo updated.', 'प्रोफ़ाइल फ़ोटो अपडेट हो गई।'));
    } on PlatformException catch (error) {
      _message(
        error.message ?? _t('Could not open photos.', 'फ़ोटो नहीं खुल सकीं।'),
        error: true,
      );
    } catch (error) {
      _message(ProfileAccountRepository.friendlyError(error), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _removeAvatar() async {
    if (_saving || _profile == null) return;
    setState(() => _saving = true);
    try {
      final updated = await _account.removeAvatar(
        _profile!['avatar_path'] as String?,
      );
      if (!mounted) return;
      setState(() {
        _profile = updated;
        _avatarUrl = null;
        _localAvatarPath = null;
      });
      _message(_t('Profile photo removed.', 'प्रोफ़ाइल फ़ोटो हटा दी गई।'));
    } catch (error) {
      _message(ProfileAccountRepository.friendlyError(error), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openNotifications() async {
    final remaining = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => _NotificationsScreen(account: _account),
      ),
    );
    if (remaining != null && mounted) setState(() => _unreadCount = remaining);
  }

  Future<void> _createAccount() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AccountAuthScreen(
          repository: widget.repository,
          initialMode: AccountAuthMode.signUp,
        ),
      ),
    );
    if (created == true && mounted) {
      await _load();
      _message(
        _t(
          'Account linked. Check your email to verify it.',
          'अकाउंट लिंक हो गया। सत्यापन के लिए ईमेल देखें।',
        ),
      );
    }
  }

  Future<void> _changeEmail() async {
    final controller = TextEditingController(text: _user?.email ?? '');
    final email = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_t('Change account email', 'अकाउंट ईमेल बदलें')),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(labelText: _t('New email', 'नया ईमेल')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(_t('Cancel', 'रद्द करें')),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: Text(_t('Send confirmation', 'पुष्टि भेजें')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (email == null || !mounted) return;
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      _message(
        _t('Enter a valid email address.', 'सही ईमेल पता लिखें।'),
        error: true,
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await _account.changeEmail(email);
      _message(
        _t(
          'Confirmation sent. The account email changes after verification.',
          'पुष्टि ईमेल भेजा गया। सत्यापन के बाद अकाउंट ईमेल बदलेगा।',
        ),
      );
    } catch (error) {
      _message(ProfileAccountRepository.friendlyError(error), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _changePassword() async {
    final password = TextEditingController();
    final confirm = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_t('Change password', 'पासवर्ड बदलें')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: password,
              obscureText: true,
              decoration: InputDecoration(
                labelText: _t('New password', 'नया पासवर्ड'),
              ),
            ),
            TextField(
              controller: confirm,
              obscureText: true,
              decoration: InputDecoration(
                labelText: _t('Confirm password', 'पासवर्ड की पुष्टि'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(_t('Cancel', 'रद्द करें')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              dialogContext,
              '${password.text}\n${confirm.text}',
            ),
            child: Text(_t('Save', 'सेव करें')),
          ),
        ],
      ),
    );
    final values = result?.split('\n');
    if (values == null || !mounted) return;
    if (values[0].length < 8 || values[0] != values[1]) {
      _message(
        _t(
          'Use 8+ characters and make both entries match.',
          '8+ अक्षर लिखें और दोनों पासवर्ड मिलाएँ।',
        ),
        error: true,
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await _account.changePassword(values[0]);
      _message(_t('Password updated.', 'पासवर्ड अपडेट हो गया।'));
    } catch (error) {
      _message(ProfileAccountRepository.friendlyError(error), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
      password.dispose();
      confirm.dispose();
    }
  }

  Future<void> _resendVerification() async {
    setState(() => _saving = true);
    try {
      await _account.resendVerification();
      _message(_t('Verification email sent.', 'सत्यापन ईमेल भेजा गया।'));
    } catch (error) {
      _message(ProfileAccountRepository.friendlyError(error), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_t('Sign out?', 'साइन आउट करें?')),
        content: Text(
          _t(
            'You can sign back in to restore your profile.',
            'प्रोफ़ाइल वापस पाने के लिए फिर साइन इन कर सकते हैं।',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(_t('Cancel', 'रद्द करें')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(_t('Sign out', 'साइन आउट')),
          ),
        ],
      ),
    );
    if (confirmed == true) await _client.auth.signOut();
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          _t('Delete account permanently?', 'अकाउंट हमेशा के लिए मिटाएँ?'),
        ),
        content: Text(
          _t(
            'This deletes the account, its profile, and its private profile photo. This cannot be undone.',
            'इससे अकाउंट, प्रोफ़ाइल और निजी फ़ोटो मिट जाएँगे। यह वापस नहीं हो सकता।',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(_t('Cancel', 'रद्द करें')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(_t('Delete account', 'अकाउंट मिटाएँ')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await _account.deleteAccount();
    } catch (error) {
      _message(ProfileAccountRepository.friendlyError(error), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openInfoPage(String title, String body) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _ProfileInfoScreen(title: title, body: body),
      ),
    );
  }

  Color get _pageColor =>
      _darkMode ? const Color(0xFF0A1220) : const Color(0xFFF5F7FC);
  Color get _cardColor => _darkMode ? const Color(0xFF151F2D) : Colors.white;
  Color get _fieldColor =>
      _darkMode ? const Color(0xFF202C3C) : const Color(0xFFEEF3FF);
  Color get _textColor =>
      _darkMode ? const Color(0xFFE8EEF7) : const Color(0xFF10213D);
  Color get _mutedColor =>
      _darkMode ? const Color(0xFF9AA8BA) : const Color(0xFF6C7891);
  Color get _accentColor => const Color(0xFF1E5BFF);

  @override
  Widget build(BuildContext context) {
    final user = _user;
    final fullName = (_profile?['full_name'] as String? ?? '').trim();
    final accountEmail = user?.email ?? _t('Guest account', 'अतिथि अकाउंट');
    final verified =
        user?.isAnonymous == false && user?.emailConfirmedAt != null;
    final localAvatar = _localAvatarPath;
    final ImageProvider? avatarProvider =
        localAvatar != null && File(localAvatar).existsSync()
        ? FileImage(File(localAvatar))
        : _avatarUrl != null
        ? NetworkImage(_avatarUrl!)
        : null;

    return ColoredBox(
      color: _pageColor,
      child: Column(
        children: [
          _buildHeader(avatarProvider),
          Expanded(
            child: _loading
                ? Center(child: CircularProgressIndicator(color: _accentColor))
                : _loadError != null
                ? _buildLoadError()
                : ListView(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 18),
                    children: [
                      const SizedBox(height: 4),
                      Center(
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(3),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _accentColor,
                                  width: 2.5,
                                ),
                              ),
                              child: CircleAvatar(
                                radius: 40,
                                backgroundColor: _fieldColor,
                                backgroundImage: avatarProvider,
                                child: avatarProvider == null
                                    ? Icon(
                                        Icons.person,
                                        size: 40,
                                        color: _mutedColor,
                                      )
                                    : null,
                              ),
                            ),
                            Positioned(
                              right: -1,
                              bottom: -1,
                              child: PopupMenuButton<String>(
                                tooltip: _t('Profile photo', 'प्रोफ़ाइल फ़ोटो'),
                                onSelected: (value) {
                                  if (value == 'camera') {
                                    _chooseAvatar(useCamera: true);
                                  }
                                  if (value == 'gallery') _chooseAvatar();
                                  if (value == 'remove') _removeAvatar();
                                },
                                itemBuilder: (context) => [
                                  PopupMenuItem(
                                    value: 'camera',
                                    child: Text(_t('Take photo', 'फ़ोटो लें')),
                                  ),
                                  PopupMenuItem(
                                    value: 'gallery',
                                    child: Text(
                                      _t(
                                        'Choose from gallery',
                                        'गैलरी से चुनें',
                                      ),
                                    ),
                                  ),
                                  if (_profile?['avatar_path'] != null)
                                    PopupMenuItem(
                                      value: 'remove',
                                      child: Text(
                                        _t('Remove photo', 'फ़ोटो हटाएँ'),
                                      ),
                                    ),
                                ],
                                child: CircleAvatar(
                                  radius: 14,
                                  backgroundColor: _accentColor,
                                  child: _saving
                                      ? const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.camera_alt,
                                          size: 15,
                                          color: Colors.white,
                                        ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Center(
                        child: Text(
                          fullName.isEmpty
                              ? _t('Add your name', 'अपना नाम जोड़ें')
                              : fullName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: _textColor,
                          ),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Center(
                        child: Text(
                          accountEmail,
                          style: TextStyle(fontSize: 12, color: _mutedColor),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Center(
                        child: verified
                            ? _statusBadge(
                                Icons.verified,
                                _t('VERIFIED ACCOUNT', 'सत्यापित अकाउंट'),
                                const Color(0xFF1859D6),
                              )
                            : _statusBadge(
                                Icons.info_outline,
                                _t('EMAIL NOT VERIFIED', 'ईमेल सत्यापित नहीं'),
                                const Color(0xFFB66A12),
                              ),
                      ),
                      if (!verified && user?.isAnonymous == false)
                        TextButton(
                          onPressed: _saving ? null : _resendVerification,
                          child: Text(
                            _t(
                              'Resend verification email',
                              'सत्यापन ईमेल फिर भेजें',
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      _sectionCard(
                        title: _t('Personal Information', 'व्यक्तिगत जानकारी'),
                        trailing: _t('Tap to edit', 'बदलने के लिए टैप करें'),
                        children: [
                          _personalRow(
                            Icons.badge_outlined,
                            _t('Full Name', 'पूरा नाम'),
                            fullName.isEmpty ? '—' : fullName,
                            () => _editField('full_name'),
                          ),
                          _personalRow(
                            Icons.phone_outlined,
                            _t('Phone', 'फ़ोन'),
                            (_profile?['phone'] as String? ?? '').isEmpty
                                ? '—'
                                : _profile!['phone'] as String,
                            () => _editField('phone'),
                          ),
                          _personalRow(
                            Icons.email_outlined,
                            _t('Recovery Email', 'रिकवरी ईमेल'),
                            (_profile?['recovery_email'] as String? ?? '')
                                    .isEmpty
                                ? '—'
                                : _profile!['recovery_email'] as String,
                            () => _editField('recovery_email'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _sectionCard(
                        title: _t('Preferences', 'प्राथमिकताएँ'),
                        children: [
                          _preferenceTile(
                            icon: Icons.translate,
                            title: _t('Account Language', 'अकाउंट भाषा'),
                            subtitle: _t(
                              'Display and assistant notifications',
                              'ऐप और सहायता सूचनाएँ',
                            ),
                            child: SegmentedButton<String>(
                              showSelectedIcon: false,
                              segments: const [
                                ButtonSegment(
                                  value: 'en',
                                  label: Text('English'),
                                ),
                                ButtonSegment(
                                  value: 'hi',
                                  label: Text('हिन्दी'),
                                ),
                              ],
                              selected: {_language},
                              onSelectionChanged: _saving
                                  ? null
                                  : (selection) =>
                                        _setLanguage(selection.first),
                            ),
                          ),
                          _preferenceTile(
                            icon: Icons.nightlight_round,
                            title: _t('Dark Mode', 'डार्क मोड'),
                            subtitle: _t(
                              'Adjust app appearance',
                              'ऐप का रूप बदलें',
                            ),
                            child: Switch.adaptive(
                              value: _darkMode,
                              onChanged: _saving ? null : _setDarkMode,
                              activeTrackColor: _accentColor,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _sectionCard(
                        title: _t('Account & Security', 'अकाउंट और सुरक्षा'),
                        children: [
                          if (user?.isAnonymous == true)
                            _actionRow(
                              Icons.person_add_alt_1,
                              _t('Create an account', 'अकाउंट बनाएँ'),
                              _createAccount,
                            )
                          else ...[
                            _actionRow(
                              Icons.alternate_email,
                              _t('Change sign-in email', 'साइन-इन ईमेल बदलें'),
                              _changeEmail,
                            ),
                            _actionRow(
                              Icons.lock_outline,
                              _t('Change password', 'पासवर्ड बदलें'),
                              _changePassword,
                            ),
                          ],
                          _actionRow(
                            Icons.logout,
                            _t('Sign out', 'साइन आउट'),
                            _signOut,
                          ),
                          _actionRow(
                            Icons.delete_outline,
                            _t('Delete account', 'अकाउंट मिटाएँ'),
                            _deleteAccount,
                            danger: true,
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 10,
                        runSpacing: 4,
                        children: [
                          _footerLink(
                            _t(
                              'Account Cloud Services',
                              'अकाउंट क्लाउड सेवाएँ',
                            ),
                            () => _openInfoPage(
                              _t(
                                'Account Cloud Services',
                                'अकाउंट क्लाउड सेवाएँ',
                              ),
                              _t(
                                'Your profile and preferences are stored in your Supabase account. Profile photos are private and tied to your account. Road reports and route reviews use the app’s existing community sharing rules.',
                                'आपकी प्रोफ़ाइल और प्राथमिकताएँ आपके Supabase अकाउंट में सुरक्षित रहती हैं। प्रोफ़ाइल फ़ोटो निजी हैं। सड़क रिपोर्ट और रूट रिव्यू ऐप के मौजूदा सामुदायिक साझाकरण नियमों के अनुसार उपयोग होते हैं।',
                              ),
                            ),
                          ),
                          _footerLink(
                            _t('Terms', 'नियम'),
                            () => _openInfoPage(
                              _t('Terms of Use', 'उपयोग की शर्तें'),
                              _t(
                                'Use the app safely and do not interact with it while driving. Location-tagged reports and road reviews may be shared with other app users. Submit accurate reports and only photos you have permission to share.',
                                'ऐप का उपयोग सुरक्षित रूप से करें और वाहन चलाते समय इससे इंटरैक्ट न करें। स्थान सहित रिपोर्ट और सड़क समीक्षा अन्य ऐप उपयोगकर्ताओं के साथ साझा हो सकती हैं। सही जानकारी दें और केवल ऐसी फ़ोटो साझा करें जिनकी अनुमति आपके पास हो।',
                              ),
                            ),
                          ),
                          _footerLink(
                            _t('Privacy Statement', 'गोपनीयता'),
                            () => _openInfoPage(
                              _t('Privacy Statement', 'गोपनीयता वक्तव्य'),
                              _t(
                                'The app uses your account email for sign-in. Your name, phone, recovery email, language, appearance preference, and private profile photo are stored with your account. GPS is used while reporting or recording a road review; submitted report locations and review routes may be shared with the community. You can delete your account from Account & Security.',
                                'ऐप साइन-इन के लिए अकाउंट ईमेल का उपयोग करता है। आपका नाम, फ़ोन, रिकवरी ईमेल, भाषा, रूप-रंग प्राथमिकता और निजी प्रोफ़ाइल फ़ोटो अकाउंट के साथ सेव होते हैं। रिपोर्ट या सड़क समीक्षा रिकॉर्ड करते समय GPS उपयोग होता है; भेजे गए स्थान और रूट सामुदायिक उपयोगकर्ताओं के साथ साझा हो सकते हैं। Account & Security से अकाउंट मिटाया जा सकता है।',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Center(
                        child: Text(
                          'Pothole AI · Version 1.0.0',
                          style: TextStyle(fontSize: 10, color: _mutedColor),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(ImageProvider? avatarProvider) {
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          IconButton(
            onPressed: widget.onBack,
            icon: const Icon(Icons.arrow_back),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _t('PROFILE & ACCOUNT', 'प्रोफ़ाइल और अकाउंट'),
                  style: TextStyle(
                    fontSize: 9,
                    letterSpacing: .7,
                    color: _mutedColor,
                  ),
                ),
                Text(
                  _t('Profile', 'प्रोफ़ाइल'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _textColor,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: _t('Notifications', 'सूचनाएँ'),
            onPressed: _openNotifications,
            icon: Badge(
              isLabelVisible: _unreadCount > 0,
              label: Text(_unreadCount > 9 ? '9+' : '$_unreadCount'),
              child: const Icon(Icons.notifications_none),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: CircleAvatar(
              radius: 13,
              backgroundColor: _fieldColor,
              backgroundImage: avatarProvider,
              child: avatarProvider == null
                  ? Icon(Icons.person, size: 16, color: _mutedColor)
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadError() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 42),
          const SizedBox(height: 12),
          Text(
            _loadError ??
                _t('Profile could not be loaded.', 'प्रोफ़ाइल लोड नहीं हुई।'),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            label: Text(_t('Retry', 'फिर कोशिश करें')),
          ),
        ],
      ),
    ),
  );

  Widget _statusBadge(IconData icon, String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: .3,
            color: color,
          ),
        ),
      ],
    ),
  );

  Widget _sectionCard({
    required String title,
    String? trailing,
    required List<Widget> children,
  }) => Container(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
    decoration: BoxDecoration(
      color: _cardColor,
      borderRadius: BorderRadius.circular(15),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: _textColor,
                ),
              ),
            ),
            if (trailing != null)
              Text(trailing, style: TextStyle(fontSize: 9, color: _mutedColor)),
          ],
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    ),
  );

  Widget _personalRow(
    IconData icon,
    String label,
    String value,
    VoidCallback onTap,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Material(
      color: _fieldColor,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 15, color: _mutedColor),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(fontSize: 9, color: _mutedColor),
                    ),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: _textColor,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.edit_outlined, size: 16, color: _accentColor),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _preferenceTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget child,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Container(
      padding: const EdgeInsets.fromLTRB(9, 8, 8, 8),
      decoration: BoxDecoration(
        color: _fieldColor,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: _mutedColor),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 11, color: _textColor)),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 9, color: _mutedColor),
                ),
              ],
            ),
          ),
          child,
        ],
      ),
    ),
  );

  Widget _actionRow(
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool danger = false,
  }) => ListTile(
    dense: true,
    leading: Icon(
      icon,
      color: danger ? Colors.redAccent : _accentColor,
      size: 20,
    ),
    title: Text(
      label,
      style: TextStyle(
        fontSize: 13,
        color: danger ? Colors.redAccent : _textColor,
      ),
    ),
    trailing: Icon(Icons.chevron_right, color: _mutedColor),
    onTap: _saving ? null : onTap,
    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
  );

  Widget _footerLink(String label, VoidCallback onTap) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          color: _textColor,
          decoration: TextDecoration.underline,
        ),
      ),
    ),
  );
}

class _NotificationsScreen extends StatefulWidget {
  final ProfileAccountRepository account;
  const _NotificationsScreen({required this.account});

  @override
  State<_NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<_NotificationsScreen> {
  List<Map<String, dynamic>> _notifications = [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await widget.account.loadNotifications();
      if (mounted) setState(() => _notifications = rows);
    } catch (error) {
      if (mounted) {
        setState(() => _error = ProfileAccountRepository.friendlyError(error));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _markRead(String id) async {
    try {
      await widget.account.markNotificationRead(id);
      if (!mounted) return;
      setState(() {
        final index = _notifications.indexWhere((item) => item['id'] == id);
        if (index >= 0) {
          _notifications[index] = {
            ..._notifications[index],
            'read_at': DateTime.now().toIso8601String(),
          };
        }
      });
    } catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ProfileAccountRepository.friendlyError(error))),
      );
    }
  }

  Future<void> _markAllRead() async {
    try {
      await widget.account.markAllNotificationsRead();
      if (!mounted) return;
      setState(() {
        _notifications = _notifications
            .map(
              (item) => {
                ...item,
                'read_at': item['read_at'] ?? DateTime.now().toIso8601String(),
              },
            )
            .toList();
      });
    } catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ProfileAccountRepository.friendlyError(error))),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Notifications'),
      actions: [
        if (_notifications.any((item) => item['read_at'] == null))
          TextButton(
            onPressed: _markAllRead,
            child: const Text('Mark all read'),
          ),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!, textAlign: TextAlign.center),
                  TextButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
            ),
          )
        : _notifications.isEmpty
        ? const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.notifications_none, size: 42),
                  SizedBox(height: 12),
                  Text('No notifications yet.'),
                ],
              ),
            ),
          )
        : ListView.builder(
            itemCount: _notifications.length,
            itemBuilder: (context, index) {
              final item = _notifications[index];
              final read = item['read_at'] != null;
              return ListTile(
                leading: Icon(
                  read
                      ? Icons.notifications_none
                      : Icons.notifications_active_outlined,
                ),
                title: Text(item['title'] as String? ?? ''),
                subtitle: Text(item['body'] as String? ?? ''),
                trailing: read
                    ? null
                    : const Icon(Icons.circle, size: 9, color: Colors.blue),
                onTap: read ? null : () => _markRead(item['id'] as String),
              );
            },
          ),
  );
}

class _ProfileInfoScreen extends StatelessWidget {
  final String title;
  final String body;
  const _ProfileInfoScreen({required this.title, required this.body});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          body,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.6),
        ),
      ],
    ),
  );
}
