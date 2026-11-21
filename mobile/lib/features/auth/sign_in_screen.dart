import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../data/api_client.dart';
import '../../data/providers.dart';
import '../../ui/fd.dart';

/// Sign in (design SignIn.dc.html + SignInError.dc.html).
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _emailError;
  String? _passwordError;
  String? _notice;
  bool _wrongPassword = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final email = _email.text.trim();
    final password = _password.text;
    setState(() {
      _emailError = email.isEmpty
          ? 'Enter your email.'
          : (!email.contains('@') || email.startsWith('@') || email.endsWith('@'))
              ? 'Enter a valid email address.'
              : null;
      _passwordError = password.isEmpty ? 'Enter your password.' : null;
      _notice = null;
      _wrongPassword = false;
    });
    if (_emailError != null || _passwordError != null) return;

    setState(() => _busy = true);
    try {
      await ref.read(sessionProvider.notifier).signIn(email, password);
      TextInput.finishAutofillContext();
      // The router redirects to Home once the session is signed in.
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.isUnauthorized) {
          _wrongPassword = true;
          _passwordError = 'That password doesn’t match this email. Try again or reset it.';
        } else if (e.status == 422) {
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

  void _forgotPassword() => FdToast.show(context, 'Password reset isn’t available yet.', aboveNav: false);

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final session = ref.watch(sessionProvider);
    final expired = session is SignedOut && session.expired;

    return FdPage(
      topPadding: FdSpace.s12,
      gap: FdSpace.s5,
      footer: const AuthFooter(),
      children: [
        const AuthLogo(),
        const AuthHeading(title: 'Sign in', subtitle: 'Your documents and deadlines, in one place.'),
        if (_notice != null)
          FdNotice.text(_notice!, kind: FdNoticeKind.danger, icon: FdIcons.alert)
        else if (expired)
          FdNotice.text('Your session ended. Sign in again.', icon: FdIcons.lock),
        AutofillGroup(
          child: FdGapColumn(gap: FdSpace.s5, children: [
            FdTextField(
              label: 'Email',
              controller: _email,
              error: _emailError,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.email, AutofillHints.username],
              onChanged: (_) {
                if (_emailError != null) setState(() => _emailError = null);
              },
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              FdTextField(
                label: 'Password',
                controller: _password,
                error: _passwordError,
                obscure: true,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.password],
                onSubmitted: (_) => _submit(),
                onChanged: (_) {
                  if (_passwordError != null) setState(() => _passwordError = null);
                },
              ),
              AuthLink(
                _wrongPassword ? 'Reset password' : 'Forgot password?',
                onTap: _forgotPassword,
                style: FdType.meta,
              ),
            ]),
          ]),
        ),
        FdButton('Sign in', block: true, loading: _busy, onPressed: _submit),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('New here? ', style: FdType.callout.copyWith(color: c.inkSecondary)),
            AuthLink('Create an account', onTap: () => context.go(Routes.signUp)),
          ],
        ),
      ],
    );
  }
}

// ── Shared by Sign in and Sign up ─────────────────────────────────────────

/// Logo row: 32 px mark + "FamilyDoc".
class AuthLogo extends StatelessWidget {
  const AuthLogo({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Semantics(
      label: 'FamilyDoc',
      excludeSemantics: true,
      child: Row(children: [
        FdIcon(FdIcons.logo, size: 32, color: c.brand),
        const SizedBox(width: FdSpace.s2),
        Text('FamilyDoc', style: FdType.bodyStrong.copyWith(fontSize: 18, color: c.ink)),
      ]),
    );
  }
}

/// h1.title + callout subtitle (8 px apart).
class AuthHeading extends StatelessWidget {
  const AuthHeading({super.key, required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Semantics(header: true, child: Text(title, style: FdType.title.copyWith(color: c.ink))),
      const SizedBox(height: FdSpace.s2),
      Text(subtitle, style: FdType.callout.copyWith(color: c.inkSecondary)),
    ]);
  }
}

/// Brand-colored text link with a 44 px tall tap area.
class AuthLink extends StatelessWidget {
  const AuthLink(this.label, {super.key, required this.onTap, this.style});
  final String label;
  final VoidCallback onTap;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: FdSize.tapMin),
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: 1,
            child: Text(label, style: (style ?? FdType.callout).copyWith(color: c.brand)),
          ),
        ),
      ),
    );
  }
}

/// Footer lock line: "Your vault stays private until you share."
class AuthFooter extends StatelessWidget {
  const AuthFooter({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return FdFooter(border: false, children: [
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        FdIcon.sm(FdIcons.lock, color: c.inkSecondary),
        const SizedBox(width: FdSpace.s2),
        Flexible(child: Text('Your vault stays private until you share.', style: FdType.meta.copyWith(color: c.inkSecondary))),
      ]),
    ]);
  }
}
