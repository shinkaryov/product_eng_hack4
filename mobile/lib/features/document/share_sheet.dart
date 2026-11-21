import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../ui/fd.dart';

/// Share sheet (design Share.dc.html) for one READY document.
/// Only household sharing exists on the backend; the other options are shown disabled.
Future<void> showShareSheet(BuildContext context, Document doc) async {
  // Pushing /household needs a context outside the sheet.
  final router = GoRouter.of(context);
  await showFdSheet<void>(context, builder: (_) => _ShareSheet(doc: doc, onSetUpHousehold: () => router.push(Routes.household)));
}

class _ShareSheet extends ConsumerStatefulWidget {
  const _ShareSheet({required this.doc, required this.onSetUpHousehold});
  final Document doc;
  final VoidCallback onSetUpHousehold;

  @override
  ConsumerState<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends ConsumerState<_ShareSheet> {
  bool _busy = false;

  /// Set after Share / Stop sharing so the sheet doesn't wait for a refetch.
  List<ShareGrant>? _grants;

  Document get doc => widget.doc;

  @override
  Widget build(BuildContext context) {
    final familyAsync = ref.watch(familyProvider);
    final sharesAsync = ref.watch(sharesProvider(doc.id));
    final grants = _grants ?? sharesAsync.valueOrNull;

    if (familyAsync.hasError || (sharesAsync.hasError && _grants == null)) {
      return FdErrorState(
        error: familyAsync.error ?? sharesAsync.error!,
        onRetry: () {
          ref.invalidate(familyProvider);
          ref.invalidate(sharesProvider(doc.id));
        },
      );
    }
    if (!familyAsync.hasValue || grants == null) return const FdLoading();

    final family = familyAsync.value;
    final members = family == null ? const <FamilyMember>[] : (ref.watch(membersProvider).valueOrNull ?? const <FamilyMember>[]);
    if (family != null && ref.watch(membersProvider).isLoading && members.isEmpty) return const FdLoading();

    return grants.isNotEmpty ? _shared(family, members, grants) : _editing(family, members);
  }

  Widget _editing(Household? family, List<FamilyMember> members) {
    final c = context.fd;
    final canShare = family != null && members.length > 1;
    final householdSubtitle = family == null
        ? 'Set up a household first'
        : members.length > 1
            ? '${family.name}, ${plural(members.length, 'member')}'
            : 'Invite someone to your household first';

    return FdGapColumn(gap: FdSpace.s4, children: [
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(header: true, child: Text('Share “${doc.displayName}”', style: FdType.headline)),
        Text('Private until you share it', style: FdType.meta.copyWith(color: c.inkSecondary)),
      ]),
      FdGapColumn(gap: FdSpace.s2, children: [
        FdOption(
          title: 'Household',
          subtitle: householdSubtitle,
          selected: canShare,
          trailing: FdIcon(FdIcons.people, color: c.inkSecondary),
          onTap: canShare
              ? null
              : () {
                  Navigator.of(context).pop();
                  widget.onSetUpHousehold();
                },
        ),
        FdOption(
          title: 'A person',
          subtitle: 'Not available yet',
          selected: false,
          enabled: false,
          trailing: FdIcon(FdIcons.mail, color: c.inkTertiary),
        ),
        FdOption(
          title: 'Link that expires',
          subtitle: 'Not available yet',
          selected: false,
          enabled: false,
          trailing: FdIcon(FdIcons.link, color: c.inkTertiary),
        ),
      ]),
      Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Hide sensitive details', style: FdType.bodyStrong.copyWith(color: c.inkTertiary)),
            Text('Not available yet', style: FdType.meta.copyWith(color: c.inkSecondary)),
          ]),
        ),
        const SizedBox(width: FdSpace.s3),
        const FdSwitch(value: false, semanticLabel: 'Hide sensitive details, not available yet'),
      ]),
      FdButton(
        'Share with household',
        block: true,
        loading: _busy,
        onPressed: canShare && !_busy ? () => _share(family) : null,
      ),
    ]);
  }

  Widget _shared(Household? family, List<FamilyMember> members, List<ShareGrant> grants) {
    final prefs = ref.read(localPrefsProvider);
    final granted = grants.map((g) => g.userId).toSet();
    final names = members.where((m) => granted.contains(m.userId)).map((m) => displayNameFor(prefs, m.email)).toList();
    final who = names.isEmpty ? 'People in your household' : joinAnd(names);

    return FdGapColumn(gap: FdSpace.s4, children: [
      FdStatus(
        kind: FdStatusKind.ok,
        compact: false,
        title: 'Shared with your household',
        titleStyle: FdType.headline,
        subtitle: '$who can open it now.',
      ),
      FdNotice.text('They can view and download. They can’t edit or reshare.', kind: FdNoticeKind.info, icon: FdIcons.shieldCheck),
      FdButton('Done', block: true, onPressed: _busy ? null : () => Navigator.of(context).pop()),
      FdButton.danger('Stop sharing', loading: _busy, onPressed: _busy ? null : _stop),
    ]);
  }

  Future<void> _share(Household family) async {
    setState(() => _busy = true);
    try {
      final grants = await ref.read(repositoryProvider).shareWithFamily(doc.id, family.id);
      ref.invalidate(sharesProvider(doc.id));
      if (mounted) setState(() => _grants = grants);
    } catch (e) {
      if (mounted) FdToast.error(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    try {
      await ref.read(repositoryProvider).stopSharing(doc.id);
      ref.invalidate(sharesProvider(doc.id));
      if (!mounted) return;
      setState(() => _grants = const []);
      FdToast.show(context, 'Stopped sharing. Only you can see this document.', aboveNav: false);
    } catch (e) {
      if (mounted) FdToast.error(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
