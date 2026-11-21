import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api_client.dart';
import '../../data/providers.dart';
import '../../ui/fd.dart';
import 'household_data.dart';

/// "Have an invite code?" — join with the invitation ID and code the owner sent
/// (or the familydoc://join link pasted into the first field).
class JoinHouseholdForm extends ConsumerStatefulWidget {
  const JoinHouseholdForm({super.key});

  @override
  ConsumerState<JoinHouseholdForm> createState() => _JoinHouseholdFormState();
}

class _JoinHouseholdFormState extends ConsumerState<JoinHouseholdForm> {
  final _id = TextEditingController();
  final _code = TextEditingController();
  bool _open = false;
  bool _busy = false;
  String? _idError;
  String? _codeError;

  @override
  void dispose() {
    _id.dispose();
    _code.dispose();
    super.dispose();
  }

  void _onIdChanged(String v) {
    final parsed = parseInvite(v);
    if (parsed.secret != null) {
      _id.text = parsed.id;
      _code.text = parsed.secret!;
    }
  }

  Future<void> _join() async {
    final id = parseInvite(_id.text).id;
    final code = _code.text.trim();
    setState(() {
      _idError = id.isEmpty ? 'Enter the invitation ID.' : null;
      _codeError = code.isEmpty ? 'Enter the code.' : null;
    });
    if (id.isEmpty || code.isEmpty) return;
    setState(() => _busy = true);
    try {
      await ref.read(repositoryProvider).respondInvitation(id, secret: code, accept: true);
      if (mounted) FdToast.show(context, 'You joined the household', aboveNav: false);
      ref.invalidate(familyProvider);
      ref.invalidate(documentsProvider);
      await ref.read(familyProvider.future).catchError((_) => null);
    } on ApiException catch (e) {
      final msg = switch (e.status) {
        404 || 422 => 'We couldn’t find this invitation. Check the ID and code.',
        410 => 'This invitation has expired. Ask for a new one.',
        409 => 'This invitation was already used or declined.',
        403 => 'This invitation is for a different account, or the code is wrong.',
        _ => e.message,
      };
      if (mounted) setState(() => _codeError = msg);
    } catch (_) {
      if (mounted) setState(() => _codeError = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    if (!_open) {
      return Align(
        alignment: Alignment.centerLeft,
        child: FdButton.quiet('Have an invite code?', icon: FdIcons.key, onPressed: () => setState(() => _open = true)),
      );
    }
    return FdCard.pad(
      child: FdGapColumn(gap: FdSpace.s3, children: [
        Semantics(header: true, child: Text('Join a household', style: FdType.bodyStrong.copyWith(color: c.ink))),
        Text('Use the invitation ID and code the owner sent you. You can also paste their invite link.',
            style: FdType.meta.copyWith(color: c.inkSecondary)),
        FdTextField(
          label: 'Invitation ID',
          controller: _id,
          error: _idError,
          enabled: !_busy,
          textInputAction: TextInputAction.next,
          onChanged: _onIdChanged,
        ),
        FdTextField(
          label: 'Code',
          controller: _code,
          error: _codeError,
          enabled: !_busy,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _busy ? null : _join(),
        ),
        FdButton.secondary('Join household', loading: _busy, onPressed: _busy ? null : _join),
      ]),
    );
  }
}
