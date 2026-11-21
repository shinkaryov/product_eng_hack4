import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../ui/fd.dart';
import 'household_data.dart';
import 'invite_sheet.dart';
import 'join_form.dart';

/// Household (design Household): members, pending invitations, invite / leave.
/// Without a household: create one or join with an invitation.
class HouseholdScreen extends ConsumerWidget {
  const HouseholdScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final family = ref.watch(familyProvider);
    final appBar = FdAppBar(
      title: 'Household',
      trailing: FdIconButton(FdIcons.more, size: 24, semanticLabel: 'Settings', onPressed: () => context.push(Routes.settings)),
    );

    Future<void> refresh() async {
      ref.invalidate(familyProvider);
      ref.invalidate(householdInvitationsProvider);
      await ref.read(familyProvider.future).catchError((_) => null);
    }

    return family.when(
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      loading: () => FdPage(appBar: appBar, children: const [FdLoading()]),
      error: (e, _) => FdPage(
        appBar: appBar,
        onRefresh: refresh,
        children: [FdErrorState(error: e, onRetry: () => ref.invalidate(familyProvider))],
      ),
      data: (h) => h == null
          ? FdPage(appBar: appBar, children: const [_SetupView()])
          : FdPage(appBar: appBar, onRefresh: refresh, children: [_HouseholdView(household: h)]),
    );
  }
}

// ── No household ──────────────────────────────────────────────────────────

class _SetupView extends ConsumerStatefulWidget {
  const _SetupView();

  @override
  ConsumerState<_SetupView> createState() => _SetupViewState();
}

class _SetupViewState extends ConsumerState<_SetupView> {
  late final _name = TextEditingController(text: defaultHouseholdName(ref.read(currentUserProvider).displayName));
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give your household a name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(repositoryProvider).createFamily(name);
      ref.invalidate(familyProvider);
      await ref.read(familyProvider.future);
    } on ApiException catch (e) {
      if (e.isConflict) {
        // Already in one (e.g. joined on another device): show it.
        ref.invalidate(familyProvider);
      } else if (mounted) {
        setState(() => _error = e.status == 422 ? 'Use a shorter name.' : e.message);
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return FdGapColumn(children: [
      Semantics(header: true, child: Text('Set up your household', style: FdType.title.copyWith(color: c.ink))),
      Text(
        'Share documents and deadlines with the people you live with. You choose what to share. Everything else stays private.',
        style: FdType.body.copyWith(color: c.inkSecondary),
      ),
      FdTextField(
        label: 'Household name',
        controller: _name,
        error: _error,
        enabled: !_busy,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _busy ? null : _create(),
      ),
      FdButton('Create household', block: true, loading: _busy, onPressed: _busy ? null : _create),
      const JoinHouseholdForm(),
    ]);
  }
}

// ── In a household ────────────────────────────────────────────────────────

class _HouseholdView extends ConsumerWidget {
  const _HouseholdView({required this.household});
  final Household household;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.fd;
    final me = ref.watch(currentUserProvider);
    final prefs = ref.watch(localPrefsProvider);
    final members = ref.watch(membersProvider);
    final owner = household.isOwner;

    String nameOf(FamilyMember m) => m.userId == me.user.id ? me.displayName : displayNameFor(prefs, m.email);

    return FdGapColumn(children: [
      Semantics(header: true, child: Text(household.name, style: FdType.title.copyWith(color: c.ink))),
      const FdGroupLabel('Members'),
      members.when(
        skipLoadingOnRefresh: true,
        loading: () => const FdLoading(),
        error: (e, _) => FdErrorState(error: e, onRetry: () => ref.invalidate(membersProvider)),
        data: (list) {
          final sorted = [...list]..sort((a, b) {
              int rank(FamilyMember m) => m.role == 'OWNER' ? 0 : (m.userId == me.user.id ? 1 : 2);
              final r = rank(a).compareTo(rank(b));
              return r != 0 ? r : nameOf(a).toLowerCase().compareTo(nameOf(b).toLowerCase());
            });
          if (sorted.isEmpty) {
            return FdNotice.text('No members yet.', icon: FdIcons.people);
          }
          return FdList(children: [
            for (final m in sorted)
              _MemberRow(
                name: nameOf(m),
                meta: _roleMeta(m, isMe: m.userId == me.user.id),
                canManage: owner && m.userId != me.user.id,
                onManage: () => _memberOptions(context, ref, m, nameOf(m)),
              ),
          ]);
        },
      ),
      if (owner) ..._pendingInvitations(context, ref),
      FdNotice.text(
        'Members see only what’s shared with the household. You can’t see their private documents either.',
        kind: FdNoticeKind.info,
        icon: FdIcons.shieldCheck,
      ),
      if (owner) FdButton.secondary('Invite someone', icon: FdIcons.people, onPressed: () => showInviteSheet(context)),
      if (!owner)
        FdButton.quiet('Leave household', icon: FdIcons.logout, foreground: c.danger, onPressed: () => _leave(context, ref)),
    ]);
  }

  static String _roleMeta(FamilyMember m, {required bool isMe}) {
    final isOwner = m.role == 'OWNER';
    if (isOwner && isMe) return 'Owner (you)';
    if (isOwner) return 'Owner';
    if (isMe) return 'You';
    return 'Member';
  }

  Future<void> _memberOptions(BuildContext context, WidgetRef ref, FamilyMember m, String name) async {
    final remove = await showFdSheet<bool>(
      context,
      builder: (ctx) {
        final c = ctx.fd;
        return FdGapColumn(children: [
          Row(children: [
            FdAvatar(initials(name)),
            const SizedBox(width: FdSpace.s3),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Semantics(header: true, child: Text(name, style: FdType.headline.copyWith(color: c.ink))),
                Text(m.email, style: FdType.meta.copyWith(color: c.inkSecondary)),
              ]),
            ),
          ]),
          FdButton.danger('Remove from household', icon: FdIcons.trash, block: true, onPressed: () => Navigator.of(ctx).pop(true)),
        ]);
      },
    );
    if (remove != true || !context.mounted) return;
    final ok = await confirmFd(
      context,
      title: 'Remove $name?',
      body: 'They’ll lose access to everything shared with the household. Their own documents stay with them.',
      confirm: 'Remove',
    );
    if (!ok || !context.mounted) return;
    try {
      await ref.read(repositoryProvider).removeMember(household.id, m.userId);
      ref.invalidate(membersProvider);
      if (context.mounted) FdToast.show(context, '$name is no longer in the household', aboveNav: false);
    } catch (e) {
      if (context.mounted) FdToast.error(context, e);
    }
  }

  Future<void> _leave(BuildContext context, WidgetRef ref) async {
    final ok = await confirmFd(
      context,
      title: 'Leave ${household.name}?',
      body: 'You’ll lose access to documents shared with the household. Your own documents stay with you.',
      confirm: 'Leave',
    );
    if (!ok || !context.mounted) return;
    try {
      await ref.read(repositoryProvider).leaveFamily(household.id);
      ref.invalidate(familyProvider);
      ref.invalidate(documentsProvider);
      ref.invalidate(timelineProvider);
      if (context.mounted) FdToast.show(context, 'You left ${household.name}', aboveNav: false);
    } catch (e) {
      if (context.mounted) FdToast.error(context, e);
    }
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.name, required this.meta, required this.canManage, required this.onManage});
  final String name;
  final String meta;
  final bool canManage;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) => FdListRow(
        leading: FdAvatar(initials(name)),
        title: name,
        meta: meta,
        onTap: canManage ? onManage : null,
        trailing: canManage
            ? FdIconButton(FdIcons.more, semanticLabel: 'Options for $name', color: context.fd.inkSecondary, onPressed: onManage)
            : null,
      );
}

/// "Waiting for them": invitations the owner sent that nobody answered yet.
List<Widget> _pendingInvitations(BuildContext context, WidgetRef ref) {
  final c = context.fd;
  final async = ref.watch(householdInvitationsProvider);
  if (async.hasError && !async.hasValue) {
    return [
      FdNotice(
        kind: FdNoticeKind.neutral,
        icon: FdIcons.mail,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('We couldn’t load your invitations.'),
          FdButton.quiet('Try again', icon: FdIcons.retry, compact: true, onPressed: () => ref.invalidate(householdInvitationsProvider)),
        ]),
      ),
    ];
  }
  final pending = pendingInvitations(async.valueOrNull ?? const []);
  if (pending.isEmpty) return const [];
  return [
    const FdGroupLabel('Waiting for them'),
    FdList(children: [
      for (final inv in pending)
        FdListRow(
          leading: FdWell(FdIcons.mail, background: c.surfaceSunken, foreground: c.inkSecondary),
          title: 'Invitation sent',
          meta: inv.expiresAt == null ? 'Invitation' : 'Invitation · expires ${formatDateSmart(inv.expiresAt!.toLocal())}',
        ),
    ]),
  ];
}
