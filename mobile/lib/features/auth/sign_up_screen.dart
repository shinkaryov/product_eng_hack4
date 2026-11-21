import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../data/api_client.dart';
import '../../data/providers.dart';
import '../../ui/fd.dart';
import 'sign_in_screen.dart';

/// Create account (design SignUp.dc.html). Registers, then signs in; the router
/// moves to Home when the session flips to signed in.
class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  static const _minPassword = 15;
  static const _maxPassword = 256;

  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  late final _termsTap = TapGestureRecognizer()..onTap = () => _noPage('Terms');
  late final _privacyTap = TapGestureRecognizer()..onTap = () => _noPage('Privacy Policy');

  bool _busy = false;
  String? _nameError;
  String? _emailError;
  String? _passwordError;
  String? _notice;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _termsTap.dispose();
    _privacyTap.dispose();
    super.dispose();
  }

  void _noPage(String what) => FdToast.show(context, '$what isn’t available in the app yet.', aboveNav: false);

  bool _validEmail(String e) {
    final at = e.indexOf('@');
    return at > 0 && at < e.length - 1 && !e.contains(' ');
  }

  Future<void> _submit() async {
    if (_busy) return;
    final name = _name.text.trim();
    final email = _email.text.trim();
    final password = _password.text;
    setState(() {
      _nameError = name.isEmpty ? 'Enter your name.' : null;
      _emailError = email.isEmpty ? 'Enter your email.' : (_validEmail(email) ? null : 'Enter a valid email address.');
      _passwordError = password.length < _minPassword
          ? 'Use at least $_minPassword characters.'
          : password.length > _maxPassword
              ? 'Use $_maxPassword characters or fewer.'
              : null;
      _notice = null;
    });
    if (_nameError != null || _emailError != null || _passwordError != null) return;

    setState(() => _busy = true);
    try {
      await ref.read(sessionProvider.notifier).signUp(name: name, email: email, password: password);
      TextInput.finishAutofillContext();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        final detail = e.detail.toLowerCase();
        if (e.isConflict) {
          _emailError = 'An account with this email already exists.';
        } else if (e.status == 422 && detail.contains('password')) {
          _passwordError = 'Use $_minPassword to $_maxPassword characters.';
        } else if (e.status == 422 && detail.contains('email')) {
          _emailError = 'Enter a valid email address.';
        } else {
          _notice = e.message;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _notice = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final linkStyle = TextStyle(color: c.brand);
    return FdPage(
      topPadding: FdSpace.s12,
      gap: FdSpace.s5,
      footer: const AuthFooter(),
      children: [
        const AuthLogo(),
        const AuthHeading(title: 'Create your account', subtitle: 'You get a private vault right away. Add your family later.'),
        if (_notice != null) FdNotice.text(_notice!, kind: FdNoticeKind.danger, icon: FdIcons.alert),
        AutofillGroup(
          child: FdGapColumn(gap: FdSpace.s5, children: [
            FdTextField(
              label: 'Your name',
              controller: _name,
              help: 'Shown to people you share with.',
              error: _nameError,
              textInputAction: TextInputAction.next,
              textCapitalization: TextCapitalization.words,
              autofillHints: const [AutofillHints.name],
              onChanged: (_) {
                if (_nameError != null) setState(() => _nameError = null);
              },
            ),
            FdTextField(
              label: 'Email',
              controller: _email,
              error: _emailError,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.email],
              onChanged: (_) {
                if (_emailError != null) setState(() => _emailError = null);
              },
            ),
            FdTextField(
              label: 'Password',
              controller: _password,
              placeholder: 'Create a password',
              help: 'At least $_minPassword characters.',
              error: _passwordError,
              obscure: true,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.newPassword],
              onSubmitted: (_) => _submit(),
              onChanged: (_) {
                if (_passwordError != null) setState(() => _passwordError = null);
              },
            ),
          ]),
        ),
        Text.rich(
          TextSpan(children: [
            const TextSpan(text: 'By creating an account you agree to the '),
            TextSpan(text: 'Terms', style: linkStyle, recognizer: _termsTap),
            const TextSpan(text: ' and '),
            TextSpan(text: 'Privacy Policy', style: linkStyle, recognizer: _privacyTap),
            const TextSpan(text: '.'),
          ]),
          style: FdType.meta.copyWith(color: c.inkSecondary),
        ),
        FdButton('Create account', block: true, loading: _busy, onPressed: _submit),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Already have an account? ', style: FdType.callout.copyWith(color: c.inkSecondary)),
            AuthLink('Sign in', onTap: () => context.go(Routes.signIn)),
          ],
        ),
      ],
    );
  }
}
