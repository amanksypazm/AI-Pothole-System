import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Profile-only section for the AI Pothole System.
///
/// This widget intentionally does NOT implement the pothole alert engine.
/// The alert-distance logic can be connected later when the pothole
/// latitude/longitude data system is ready.
class ProfileSection extends StatefulWidget {
  final int reportCount;
  final int reviewCount;

  const ProfileSection({super.key, this.reportCount = 0, this.reviewCount = 0});

  @override
  State<ProfileSection> createState() => _ProfileSectionState();
}

class _ProfileSectionState extends State<ProfileSection> {
  static const MethodChannel _profileChannel = MethodChannel(
    'com.example.pothole_app/road_tools',
  );

  final TextEditingController _nameController = TextEditingController();

  String? _avatarPath;
  String? _publicId;
  bool _editing = false;
  bool _saving = false;

  String? _savedName;
  String? _savedAvatarPath;
  int _alertDistance = 100;
  bool _voiceAlerts = true;
  bool _vibrationAlerts = true;
  String _distanceUnit = 'km';

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _generatePublicIdIfNeeded(SharedPreferences prefs) async {
    var publicId = prefs.getString('profilePublicId');

    if (publicId == null || !RegExp(r'^[A-Z0-9]{5,10}$').hasMatch(publicId)) {
      final random = math.Random.secure();
      const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
      publicId = List.generate(
        10,
        (_) => alphabet[random.nextInt(alphabet.length)],
      ).join();
      await prefs.setString('profilePublicId', publicId);
    }

    _publicId = publicId;
  }

  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    await _generatePublicIdIfNeeded(prefs);

    final loadedName =
        prefs.getString('profileDisplayName') ?? 'Road Safety Driver';
    final loadedAvatar = prefs.getString('profileAvatarPath');
    final alertDistance = prefs.getInt('profileAlertDistance') ?? 100;
    final voiceAlerts = prefs.getBool('profileVoiceAlerts') ?? true;
    final vibrationAlerts = prefs.getBool('profileVibrationAlerts') ?? true;
    final distanceUnit = prefs.getString('profileDistanceUnit') ?? 'km';

    if (!mounted) return;

    setState(() {
      _savedName = loadedName;
      _savedAvatarPath = loadedAvatar;
      _avatarPath = loadedAvatar;
      _nameController.text = loadedName;
      _alertDistance = [100, 200, 300].contains(alertDistance)
          ? alertDistance
          : 100;
      _voiceAlerts = voiceAlerts;
      _vibrationAlerts = vibrationAlerts;
      _distanceUnit = distanceUnit == 'mi' ? 'mi' : 'km';
    });
  }

  Future<void> _setAlertDistance(int distance) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('profileAlertDistance', distance);
    if (!mounted) return;
    setState(() => _alertDistance = distance);
    _showMessage('Alert distance set to $distance m.');
  }

  Future<void> _setAlertEnabled({
    required String preferenceKey,
    required bool enabled,
    required bool isVoice,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(preferenceKey, enabled);
    if (!mounted) return;
    setState(() {
      if (isVoice) {
        _voiceAlerts = enabled;
      } else {
        _vibrationAlerts = enabled;
      }
    });
    _showMessage(enabled ? 'Alert enabled.' : 'Alert disabled.');
  }

  Future<void> _setDistanceUnit(String unit) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('profileDistanceUnit', unit);
    if (!mounted) return;
    setState(() => _distanceUnit = unit);
    _showMessage('Units updated.');
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _chooseAvatar() async {
    try {
      final path = await _profileChannel.invokeMethod<String>(
        'pickProfilePhoto',
      );

      if (path == null || path.isEmpty) return;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('profileAvatarPath', path);

      if (!mounted) return;
      setState(() => _avatarPath = path);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile photo updated successfully.')),
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Could not open photos.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not change profile photo: $e')),
      );
    }
  }

  Future<void> _saveProfile() async {
    final name = _nameController.text.trim();

    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please enter your name.')));
      return;
    }

    setState(() => _saving = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('profileDisplayName', name);
      await prefs.setString('profilePublicId', _publicId ?? '');

      if (_avatarPath != null && _avatarPath!.isNotEmpty) {
        await prefs.setString('profileAvatarPath', _avatarPath!);
      } else {
        await prefs.remove('profileAvatarPath');
      }

      if (!mounted) return;
      setState(() {
        _editing = false;
        _savedName = name;
        _savedAvatarPath = _avatarPath;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile saved successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save profile: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _cancelEditing() {
    if (!mounted) return;
    setState(() {
      _editing = false;
      _avatarPath = _savedAvatarPath;
      _nameController.text = _savedName ?? 'Road Safety Driver';
    });
  }

  Future<void> _copyUserId() async {
    final id = _publicId;
    if (id == null || id.isEmpty) return;

    await Clipboard.setData(ClipboardData(text: id));

    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('User ID copied.')));
  }

  Widget _buildAvatar({required double radius, required bool editable}) {
    final exists =
        _avatarPath != null &&
        _avatarPath!.isNotEmpty &&
        File(_avatarPath!).existsSync();

    return InkWell(
      onTap: editable ? _chooseAvatar : null,
      borderRadius: BorderRadius.circular(radius + 10),
      child: Stack(
        alignment: Alignment.bottomRight,
        children: [
          CircleAvatar(
            radius: radius,
            backgroundColor: const Color(0xFF18354A),
            backgroundImage: exists ? FileImage(File(_avatarPath!)) : null,
            child: exists
                ? null
                : Icon(
                    Icons.person,
                    size: radius * .85,
                    color: const Color(0xFF7DE5E9),
                  ),
          ),
          if (editable)
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: const Color(0xFF26C6DA),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF090F19), width: 3),
              ),
              child: const Icon(
                Icons.camera_alt,
                size: 17,
                color: Colors.white,
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      title,
      style: const TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: Colors.white,
      ),
    ),
  );

  Widget _settingsCard({required Widget child}) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFF101D2D),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: const Color(0xFF294158)),
    ),
    child: child,
  );

  Widget _alertSwitch({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    required bool showDivider,
  }) => Column(
    children: [
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF9CAFC1),
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            activeTrackColor: const Color(0xFF20C8FF),
            onChanged: onChanged,
          ),
        ],
      ),
      if (showDivider)
        const Divider(color: Color(0xFF294158), height: 18, thickness: 1),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 30),
      children: [
        const Text(
          'ACCOUNT',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
            color: Color(0xFF20C8FF),
          ),
        ),
        const Text(
          'Profile & settings',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 18),
        _settingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _buildAvatar(radius: 30, editable: _editing),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _nameController.text.trim().isEmpty
                              ? 'Road Safety Driver'
                              : _nameController.text.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Community contributor',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF9CAFC1),
                          ),
                        ),
                        const SizedBox(height: 4),
                        InkWell(
                          onTap: _copyUserId,
                          child: Text(
                            'ID: ${_publicId ?? 'Loading...'}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF20C8FF),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: _editing ? 'Cancel editing' : 'Edit profile',
                    onPressed: _editing
                        ? _cancelEditing
                        : () => setState(() => _editing = true),
                    icon: Icon(
                      _editing ? Icons.close : Icons.edit_outlined,
                      color: const Color(0xFF20C8FF),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        _showMessage('Logged out of prototype profile.'),
                    child: const Text(
                      'Log out',
                      style: TextStyle(
                        color: Color(0xFF20C8FF),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              if (_editing) ...[
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: _chooseAvatar,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Change profile photo'),
                ),
                TextField(
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Your name',
                    labelStyle: const TextStyle(color: Colors.white60),
                    prefixIcon: const Icon(Icons.person_outline),
                    filled: true,
                    fillColor: const Color(0xFF0B1624),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _saveProfile,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check),
                    label: Text(_saving ? 'Saving...' : 'Save profile'),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 22),
        _sectionTitle('Alert preferences'),
        _settingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Alert distance',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [100, 200, 300].map((distance) {
                  final selected = _alertDistance == distance;
                  return Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: distance == 300 ? 0 : 8),
                      child: OutlinedButton(
                        onPressed: () => _setAlertDistance(distance),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          foregroundColor: selected
                              ? const Color(0xFF20C8FF)
                              : const Color(0xFF9CAFC1),
                          backgroundColor: selected
                              ? const Color(0x1F20C8FF)
                              : const Color(0xFF101D2D),
                          side: BorderSide(
                            color: selected
                                ? const Color(0xFF20C8FF)
                                : const Color(0xFF294158),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text('$distance m'),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 10),
              _alertSwitch(
                title: 'Voice alerts',
                subtitle: 'Spoken warning before hazards.',
                value: _voiceAlerts,
                onChanged: (value) => _setAlertEnabled(
                  preferenceKey: 'profileVoiceAlerts',
                  enabled: value,
                  isVoice: true,
                ),
                showDivider: true,
              ),
              _alertSwitch(
                title: 'Vibration alerts',
                subtitle: 'Short haptic warning when parked.',
                value: _vibrationAlerts,
                onChanged: (value) => _setAlertEnabled(
                  preferenceKey: 'profileVibrationAlerts',
                  enabled: value,
                  isVoice: false,
                ),
                showDivider: false,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _sectionTitle('Units'),
        _settingsCard(
          child: Row(
            children: [
              _unitButton('km', 'Kilometres'),
              _unitButton('mi', 'Miles'),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0x1AF5AE35),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0x4DF5AE35)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.shield_outlined, color: Color(0xFFFFD28A)),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Set your route and preferences before driving. Keep your attention on the road.',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFFFE0A3),
                  ),
                ),
              ),
            ],
          ),
        ),
        TextButton(
          onPressed: () =>
              _showMessage('Help & Feedback is ready when you are parked.'),
          style: TextButton.styleFrom(
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 18),
            alignment: Alignment.centerLeft,
          ),
          child: const Row(
            children: [
              Expanded(
                child: Text(
                  'Help & Feedback',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Icon(Icons.chevron_right),
            ],
          ),
        ),
      ],
    );
  }

  Widget _unitButton(String unit, String label) {
    final selected = _distanceUnit == unit;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: FilledButton(
          onPressed: () => _setDistanceUnit(unit),
          style: FilledButton.styleFrom(
            backgroundColor: selected
                ? const Color(0xFF20C8FF)
                : const Color(0xFF152438),
            foregroundColor: selected
                ? const Color(0xFF07111F)
                : const Color(0xFFCBD5E1),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }
}
