import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'profile_account_repository.dart';
import 'shared_reports_repository.dart';

enum AccountAuthMode { signIn, signUp, forgotPassword, resetPassword }

class AccountAuthScreen extends StatefulWidget {
  final SharedReportsRepository repository;
  final AccountAuthMode initialMode;
  final VoidCallback? onPasswordReset;

  const AccountAuthScreen({
    super.key,
    required this.repository,
    this.initialMode = AccountAuthMode.signIn,
    this.onPasswordReset,
  });

  @override
  State<AccountAuthScreen> createState() => _AccountAuthScreenState();
}

class _AccountAuthScreenState extends State<AccountAuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  late AccountAuthMode _mode;
  bool _busy = false;
  String? _message;

  SupabaseClient get _client => widget.repository.client!;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  String get _title => switch (_mode) {
    AccountAuthMode.signIn => 'Welcome back',
    AccountAuthMode.signUp => 'Create your account',
    AccountAuthMode.forgotPassword => 'Reset your password',
    AccountAuthMode.resetPassword => 'Choose a new password',
  };

  Future<void> _submit() async {
    if (_busy || !(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      switch (_mode) {
        case AccountAuthMode.signIn:
          await _client.auth.signInWithPassword(
            email: _email.text.trim(),
            password: _password.text,
          );
          break;
        case AccountAuthMode.signUp:
          final name = _name.text.trim();
          final user = _client.auth.currentUser;
          if (user?.isAnonymous == true) {
            await _client.auth.updateUser(
              UserAttributes(
                email: _email.text.trim(),
                password: _password.text,
                data: {'full_name': name},
              ),
              emailRedirectTo: ProfileAccountRepository.authRedirect,
            );
            await ProfileAccountRepository(widget.repository)
                .updateProfile({'full_name': name});
            if (mounted && Navigator.of(context).canPop()) {
              Navigator.of(context).pop(true);
              return;
            }
          } else {
            final response = await _client.auth.signUp(
              email: _email.text.trim(),
              password: _password.text,
              data: {'full_name': name},
              emailRedirectTo: ProfileAccountRepository.authRedirect,
            );
            if (response.session == null && mounted) {
              setState(() {
                _mode = AccountAuthMode.signIn;
                _message =
                    'Check your inbox to verify your email, then sign in.';
              });
              return;
            }
          }
          if (mounted) {
            setState(() {
              _mode = AccountAuthMode.signIn;
              _message =
                  'Verification email sent. Confirm it before signing in.';
            });
          }
          return;
        case AccountAuthMode.forgotPassword:
          await _client.auth.resetPasswordForEmail(
            _email.text.trim(),
            redirectTo: ProfileAccountRepository.authRedirect,
          );
          if (mounted) {
            setState(() {
              _mode = AccountAuthMode.signIn;
              _message = 'If that account exists, a reset link was sent.';
            });
          }
          return;
        case AccountAuthMode.resetPassword:
          await _client.auth.updateUser(
            UserAttributes(password: _password.text),
          );
          widget.onPasswordReset?.call();
          return;
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = ProfileAccountRepository.friendlyError(error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _continueAsGuest() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await _client.auth.signInAnonymously();
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = ProfileAccountRepository.friendlyError(error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _changeMode(AccountAuthMode mode) {
    setState(() {
      _mode = mode;
      _message = null;
      _password.clear();
      _confirmPassword.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                const Icon(Icons.shield_outlined, size: 54),
                const SizedBox(height: 16),
                Text(
                  _title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your account keeps your profile and preferences in sync.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      if (_mode == AccountAuthMode.signUp) ...[
                        TextFormField(
                          controller: _name,
                          textCapitalization: TextCapitalization.words,
                          decoration: const InputDecoration(
                            labelText: 'Full name',
                          ),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? 'Enter your name.'
                              : null,
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (_mode != AccountAuthMode.resetPassword) ...[
                        TextFormField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email],
                          decoration: const InputDecoration(labelText: 'Email'),
                          validator: (value) {
                            final email = value?.trim() ?? '';
                            return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                                    .hasMatch(email)
                                ? null
                                : 'Enter a valid email address.';
                          },
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (_mode != AccountAuthMode.forgotPassword) ...[
                        TextFormField(
                          controller: _password,
                          obscureText: true,
                          autofillHints: _mode == AccountAuthMode.signIn
                              ? const [AutofillHints.password]
                              : null,
                          decoration: InputDecoration(
                            labelText: _mode == AccountAuthMode.resetPassword
                                ? 'New password'
                                : 'Password',
                          ),
                          validator: (value) {
                            if (_mode == AccountAuthMode.signIn) {
                              return (value?.isNotEmpty ?? false)
                                  ? null
                                  : 'Enter your password.';
                            }
                            return (value?.length ?? 0) >= 8
                                ? null
                                : 'Use at least 8 characters.';
                          },
                        ),
                        if (_mode == AccountAuthMode.signUp ||
                            _mode == AccountAuthMode.resetPassword) ...[
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _confirmPassword,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: 'Confirm password',
                            ),
                            validator: (value) => value == _password.text
                                ? null
                                : 'Passwords do not match.',
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
                if (_message != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    _message!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color:
                          _message!.startsWith('If that') ||
                              _message!.startsWith('Check your') ||
                              _message!.startsWith('Verification')
                          ? Colors.green
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(switch (_mode) {
                          AccountAuthMode.signIn => 'Sign in',
                          AccountAuthMode.signUp => 'Create account',
                          AccountAuthMode.forgotPassword => 'Send reset link',
                          AccountAuthMode.resetPassword => 'Save new password',
                        }),
                ),
                if (_mode == AccountAuthMode.signIn) ...[
                  TextButton(
                    onPressed: () =>
                        _changeMode(AccountAuthMode.forgotPassword),
                    child: const Text('Forgot password?'),
                  ),
                  TextButton(
                    onPressed: () => _changeMode(AccountAuthMode.signUp),
                    child: const Text('Create an account'),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : _continueAsGuest,
                    icon: const Icon(Icons.person_outline),
                    label: const Text('Continue as guest'),
                  ),
                ] else if (_mode != AccountAuthMode.resetPassword) ...[
                  TextButton(
                    onPressed: () => _changeMode(AccountAuthMode.signIn),
                    child: const Text('Back to sign in'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
