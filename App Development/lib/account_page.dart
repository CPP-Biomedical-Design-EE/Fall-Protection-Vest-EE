import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:fall_protection_vest_app/account_auth.dart';
import 'package:fall_protection_vest_app/app_colors.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({required this.auth, required this.initialUser, super.key});

  final AccountAuthService auth;
  final AccountUser? initialUser;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  StreamSubscription<AccountUser?>? _userSubscription;
  AccountUser? _user;
  bool _creatingAccount = false;
  bool _resettingPassword = false;
  bool _submitting = false;
  String? _error;
  String? _notice;

  bool get _hasEmailAccount => _user != null && !_user!.isAnonymous;
  bool get _isVerified => _hasEmailAccount && _user!.emailVerified;

  @override
  void initState() {
    super.initState();
    _user = widget.initialUser;
    _userSubscription = widget.auth.userChanges.listen((user) {
      if (mounted) setState(() => _user = user);
    });
  }

  @override
  void dispose() {
    _userSubscription?.cancel();
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
      _notice = null;
    });
    try {
      if (_resettingPassword) {
        await widget.auth.sendPasswordResetEmail(_emailController.text);
        if (!mounted) return;
        setState(() {
          _submitting = false;
          _notice =
              'If an account exists for that email, password reset instructions have been sent.';
        });
        return;
      }

      if (_creatingAccount) {
        _user = await widget.auth.createAccount(
          name: _nameController.text,
          email: _emailController.text,
          password: _passwordController.text,
        );
        if (!mounted) return;
        setState(() {
          _submitting = false;
          _notice =
              'Account created. Check your inbox and verify your email before using caregiver features.';
        });
        return;
      }

      _user = await widget.auth.signIn(
        email: _emailController.text,
        password: _passwordController.text,
      );
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _notice = _isVerified
            ? 'You are signed in.'
            : 'You are signed in, but caregiver features stay locked until your email is verified.';
      });
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      final currentUser = widget.auth.currentUser;
      setState(() {
        _user = currentUser;
        _submitting = false;
        _error = _resettingPassword && error.code == 'user-not-found'
            ? null
            : describeFirebaseAuthError(error);
        if (_resettingPassword && error.code == 'user-not-found') {
          _notice =
              'If an account exists for that email, password reset instructions have been sent.';
        } else if (_creatingAccount && currentUser != null) {
          _error =
              'The account was created, but setup did not finish: ${describeFirebaseAuthError(error)} You can resend the verification email below.';
        }
      });
    } on StateError catch (error) {
      if (!mounted) return;
      setState(() {
        _user = widget.auth.currentUser;
        _submitting = false;
        _error = error.message;
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _user = widget.auth.currentUser;
        _submitting = false;
        _error = 'Could not complete the account request: $error';
      });
    }
  }

  Future<void> _resendVerification() async {
    setState(() {
      _submitting = true;
      _error = null;
      _notice = null;
    });
    try {
      await widget.auth.resendVerificationEmail();
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _notice = 'A new verification email has been sent.';
      });
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = describeFirebaseAuthError(error);
      });
    } on StateError catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = error.message;
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Could not send the verification email: $error';
      });
    }
  }

  Future<void> _checkVerification() async {
    setState(() {
      _submitting = true;
      _error = null;
      _notice = null;
    });
    try {
      _user = await widget.auth.refreshCurrentUser();
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _notice = _isVerified
            ? 'Email verified. Caregiver features are now available.'
            : 'Email is not verified yet. Open the link in your inbox, then check again.';
      });
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = describeFirebaseAuthError(error);
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Could not refresh account status: $error';
      });
    }
  }

  Future<void> _signOut() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.auth.signOut();
      if (!mounted) return;
      setState(() {
        _user = null;
        _submitting = false;
        _creatingAccount = false;
        _resettingPassword = false;
        _notice = 'You are signed out. Guest mode is limited to testing.';
      });
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = describeFirebaseAuthError(error);
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Could not sign out: $error';
      });
    }
  }

  String? _validateEmail(String? value) {
    final email = value?.trim() ?? '';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      return 'Enter a valid email address.';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    if (!_creatingAccount && !_resettingPassword && (value ?? '').isEmpty) {
      return 'Enter your password.';
    }
    if (_creatingAccount && (value ?? '').length < 6) {
      return 'Use at least 6 characters.';
    }
    return null;
  }

  Widget _buildVerifiedAccount() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Icon(
        Icons.verified_user_rounded,
        size: 48,
        color: AppColors.success,
      ),
      const SizedBox(height: 12),
      Text(
        _user!.displayName.isEmpty
            ? 'Account verified'
            : 'Hello, ${_user!.displayName}',
        style: Theme.of(
          context,
        ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 6),
      Text(_user!.email, style: const TextStyle(color: AppColors.muted)),
      const SizedBox(height: 10),
      const Text(
        'Your email is verified. Caregiver features are unlocked for this account.',
        style: TextStyle(color: AppColors.success, height: 1.4),
      ),
      if (_notice != null) ...[
        const SizedBox(height: 10),
        Text(
          _notice!,
          style: const TextStyle(color: AppColors.success, height: 1.4),
        ),
      ],
      const SizedBox(height: 18),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Continue to app'),
        ),
      ),
      TextButton(
        onPressed: _submitting ? null : _signOut,
        child: const Text('Log out'),
      ),
    ],
  );

  Widget _buildVerificationRequired() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Icon(
        Icons.mark_email_unread_outlined,
        size: 48,
        color: AppColors.primary,
      ),
      const SizedBox(height: 12),
      Text(
        'Verify your email',
        style: Theme.of(
          context,
        ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 6),
      Text(_user!.email, style: const TextStyle(color: AppColors.muted)),
      const SizedBox(height: 10),
      const Text(
        'Caregiver features stay locked until you verify this email. Check your inbox or spam folder.',
        style: TextStyle(color: AppColors.muted, height: 1.4),
      ),
      if (_error != null) ...[
        const SizedBox(height: 10),
        Text(
          _error!,
          style: const TextStyle(color: AppColors.danger, height: 1.4),
        ),
      ],
      if (_notice != null) ...[
        const SizedBox(height: 10),
        Text(
          _notice!,
          style: const TextStyle(color: AppColors.success, height: 1.4),
        ),
      ],
      const SizedBox(height: 16),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _submitting ? null : _checkVerification,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('I verified — check again'),
        ),
      ),
      OutlinedButton.icon(
        onPressed: _submitting ? null : _resendVerification,
        icon: const Icon(Icons.email_outlined),
        label: const Text('Resend verification email'),
      ),
      TextButton(
        onPressed: _submitting ? null : _signOut,
        child: const Text('Log out'),
      ),
    ],
  );

  Widget _buildForm() => Form(
    key: _formKey,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _resettingPassword
              ? 'Reset password'
              : _creatingAccount
              ? 'Create account'
              : 'Log in',
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          _resettingPassword
              ? 'We’ll email you a secure password reset link.'
              : _creatingAccount
              ? 'Use your email to create a caregiver account.'
              : 'Log in with your email and password.',
          style: const TextStyle(color: Color(0xFF687076), height: 1.4),
        ),
        const SizedBox(height: 18),
        if (_creatingAccount) ...[
          TextFormField(
            controller: _nameController,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Name',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.person_outline_rounded),
            ),
            validator: (value) {
              final name = value?.trim() ?? '';
              if (name.isEmpty) return 'Enter your name.';
              if (name.length > 80) {
                return 'Name must be 80 characters or less.';
              }
              return null;
            },
          ),
          const SizedBox(height: 12),
        ],
        TextFormField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          textInputAction: _resettingPassword
              ? TextInputAction.done
              : TextInputAction.next,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(
            labelText: 'Email',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.email_outlined),
          ),
          validator: _validateEmail,
        ),
        if (!_resettingPassword) ...[
          const SizedBox(height: 12),
          TextFormField(
            controller: _passwordController,
            obscureText: true,
            textInputAction: _creatingAccount
                ? TextInputAction.next
                : TextInputAction.done,
            autofillHints: [
              _creatingAccount
                  ? AutofillHints.newPassword
                  : AutofillHints.password,
            ],
            decoration: const InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.lock_outline_rounded),
            ),
            validator: _validatePassword,
          ),
        ],
        if (_creatingAccount) ...[
          const SizedBox(height: 12),
          TextFormField(
            controller: _confirmPasswordController,
            obscureText: true,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Confirm password',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.lock_reset_rounded),
            ),
            validator: (value) {
              if (value != _passwordController.text) {
                return 'Passwords do not match.';
              }
              return null;
            },
          ),
        ],
        if (!_creatingAccount && !_resettingPassword)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _submitting
                  ? null
                  : () => setState(() {
                      _resettingPassword = true;
                      _error = null;
                      _notice = null;
                    }),
              child: const Text('Forgot password?'),
            ),
          ),
        const SizedBox(height: 8),
        if (_error != null) ...[
          Text(
            _error!,
            style: const TextStyle(color: Color(0xFFB42318), height: 1.4),
          ),
          const SizedBox(height: 8),
        ],
        if (_notice != null) ...[
          Text(
            _notice!,
            style: const TextStyle(color: Color(0xFF357255), height: 1.4),
          ),
          const SizedBox(height: 8),
        ],
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    _resettingPassword
                        ? 'Send reset link'
                        : _creatingAccount
                        ? 'Create account'
                        : 'Log in',
                  ),
          ),
        ),
        const SizedBox(height: 8),
        if (_resettingPassword)
          TextButton(
            onPressed: _submitting
                ? null
                : () => setState(() {
                    _resettingPassword = false;
                    _error = null;
                    _notice = null;
                  }),
            child: const Text('Back to log in'),
          )
        else
          TextButton(
            onPressed: _submitting
                ? null
                : () => setState(() {
                    _creatingAccount = !_creatingAccount;
                    _error = null;
                    _notice = null;
                  }),
            child: Text(
              _creatingAccount
                  ? 'Already have an account? Log in'
                  : 'New here? Create an account',
            ),
          ),
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: const Text('Continue as guest — limited testing'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Account')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: _isVerified
                  ? _buildVerifiedAccount()
                  : _hasEmailAccount
                  ? _buildVerificationRequired()
                  : _buildForm(),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Email/password sign-in uses Firebase Authentication. Guest mode is for local demonstration and testing only; it cannot connect to caregiver data.',
            style: TextStyle(color: Color(0xFF687076), height: 1.4),
          ),
        ],
      ),
    ),
  );
}
