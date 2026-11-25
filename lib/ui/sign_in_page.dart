// DJ sign-in screen (NEW — not yet in the app shell).
//
// PLUG-IN (not done here, on purpose): after Firebase is configured
// (see FIREBASE-SETUP.md), show this screen from Settings — add an
// "Account" card to lib/ui/settings_page.dart that opens SignInPage,
// and create the Account once in main.dart with Account.create(
// dataDir: dataDir) and hold it in DjAppState next to the other
// services. Do NOT gate the app on it: DJ works fully offline
// without an account; the account is only for sync.
//
// Design law: white #FFFFFF, ink #1D1D1F, blue #0071E3, Inter only.
// No gradients, no glow, no pill buttons.
import 'package:flutter/material.dart';

import '../features/account/account.dart';
import '../features/account/auth_service.dart';
import '../theme.dart';

class SignInPage extends StatefulWidget {
  const SignInPage({
    super.key,
    required this.account,
    required this.onSignedIn,
    required this.onContinueWithoutAccount,
  });

  /// The DJ account (see lib/features/account/account.dart).
  final Account account;

  /// Called after a successful sign-in / account creation.
  final VoidCallback onSignedIn;

  /// Called when the user chooses to use DJ without an account.
  final VoidCallback onContinueWithoutAccount;

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _createMode = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter your email and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_createMode) {
        await widget.account.signUp(email, password);
      } else {
        await widget.account.signIn(email, password);
      }
      if (mounted) widget.onSignedIn();
    } on AuthFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Something went wrong. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DjColors.white,
      appBar: AppBar(
        title: const Text('DJ account'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _createMode ? 'Create your DJ account' : 'Sign in to DJ',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: DjColors.ink,
                fontFamily: 'Inter',
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Your DJ account syncs your routines, settings, summaries '
              'and memory between your laptop and phone. DJ works '
              'without an account too.',
              style: TextStyle(color: DjColors.ink, fontFamily: 'Inter'),
            ),
            const SizedBox(height: 16),
            const Text('Email'),
            const SizedBox(height: 4),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                hintText: 'you@example.com',
              ),
            ),
            const SizedBox(height: 12),
            const Text('Password'),
            const SizedBox(height: 4),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: 'Your DJ password',
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Text(
                _error!,
                style: const TextStyle(
                  color: DjColors.red,
                  fontFamily: 'Inter',
                ),
              ),
            if (_error != null) const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _busy ? null : _submit,
                child: Text(
                  _busy
                      ? 'Please wait...'
                      : _createMode
                          ? 'Create account'
                          : 'Sign in',
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _createMode = !_createMode;
                          _error = null;
                        }),
                child: Text(
                  _createMode
                      ? 'Already have an account? Sign in'
                      : 'Create account',
                ),
              ),
            ),
            Center(
              child: TextButton(
                onPressed:
                    _busy ? null : widget.onContinueWithoutAccount,
                child: const Text('Continue without an account'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
