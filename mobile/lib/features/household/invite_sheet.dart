import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../ui/fd.dart';
import 'household_data.dart';

/// "Invite someone": email → POST /families/invitations → the one-time code to send.
Future<void> showInviteSheet(BuildContext context) => showFdSheet<void>(context, builder: (_) => const _InviteSheet());

class _InviteSheet extends ConsumerStatefulWidget {
  const _InviteSheet();

  @override
  ConsumerState<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends ConsumerState<_InviteSheet> {
  final _email = TextEditingController();
  bool _busy = false;
  String? _error;
  Invitation? _sent;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final email = _email.text.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(() => _error = 'Enter an email address, like name@example.com.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final inv = await ref.read(repositoryProvider).invite(email);
      ref.invalidate(householdInvitationsProvider);
      if (mounted) setState(() => _sent = inv);
    } on ApiException catch (e) {
      final msg = switch (e.status) {
        404 => 'This email doesn’t have a FamilyDoc account yet. Ask them to sign up first.',
        409 => 'They’re already in the household or already invited.',
        403 => 'Only the household owner can invite people.',
        422 => 'Enter an email address, like name@example.com.',
        _ => e.message,
      };
      if (mounted) setState(() => _error = msg);
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final sent = _sent;
    if (sent != null && sent.secret != null) return _sentView(context, sent, sent.secret!);
    if (sent != null) {
      // No code came back: nothing to share, just confirm.
      return FdGapColumn(children: [
        Semantics(header: true, child: Text('Invitation sent', style: FdType.headline.copyWith(color: c.ink))),
        FdButton('Done', block: true, onPressed: () => Navigator.of(context).pop()),
      ]);
    }
    return FdGapColumn(children: [
      Semantics(header: true, child: Text('Invite someone', style: FdType.headline.copyWith(color: c.ink))),
      Text('They need a FamilyDoc account. You’ll get a code to send them, and they join with it.',
          style: FdType.callout.copyWith(color: c.inkSecondary)),
      FdTextField(
        label: 'Email',
        controller: _email,
        error: _error,
        keyboardType: TextInputType.emailAddress,
        textInputAction: TextInputAction.send,
        autofillHints: const [AutofillHints.email],
        autofocus: true,
        enabled: !_busy,
        onSubmitted: (_) => _busy ? null : _send(),
      ),
      FdButton('Send invite', block: true, loading: _busy, onPressed: _busy ? null : _send),
    ]);
  }

  Widget _sentView(BuildContext context, Invitation inv, String secret) {
    final c = context.fd;
    final expires = inv.expiresAt == null ? '' : ' It works until ${formatDateSmart(inv.expiresAt!.toLocal())}.';
    return FdGapColumn(children: [
      Semantics(header: true, child: Text('Send them this code', style: FdType.headline.copyWith(color: c.ink))),
      FdNotice.text(
        'They need the invitation ID and code to join. We show the code only once, so send it now.$expires',
        kind: FdNoticeKind.info,
        icon: FdIcons.key,
      ),
      _CopyBox(label: 'Invitation ID', value: inv.id, copied: 'Invitation ID copied'),
      _CopyBox(label: 'Code', value: secret, copied: 'Code copied', strong: true),
      _CopyBox(label: 'Invite link', value: inviteLink(inv.id, secret), copied: 'Invite link copied'),
      FdButton('Done', block: true, onPressed: () => Navigator.of(context).pop()),
    ]);
  }
}

/// Sunken box with a value and a Copy button.
class _CopyBox extends StatelessWidget {
  const _CopyBox({required this.label, required this.value, required this.copied, this.strong = false});
  final String label;
  final String value;
  final String copied;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Container(
      padding: const EdgeInsets.fromLTRB(FdSpace.s4, FdSpace.s3, FdSpace.s2, FdSpace.s3),
      decoration: BoxDecoration(color: c.surfaceSunken, borderRadius: BorderRadius.circular(FdRadius.md)),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: FdType.meta.copyWith(color: c.inkSecondary)),
            SelectableText(value, style: (strong ? FdType.bodyStrong : FdType.callout).copyWith(color: c.ink)),
          ]),
        ),
        const SizedBox(width: FdSpace.s2),
        FdIconButton(
          FdIcons.copy,
          semanticLabel: 'Copy ${label.toLowerCase()}',
          color: c.brand,
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: value));
            if (context.mounted) FdToast.show(context, copied, aboveNav: false);
          },
        ),
      ]),
    );
  }
}
