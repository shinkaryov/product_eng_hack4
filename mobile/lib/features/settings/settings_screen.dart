import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../data/providers.dart';
import '../../ui/fd.dart';

/// Settings (design Settings.dc.html): profile, reminders, notifications, account.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  static const _offsets = [30, 7, 1];

  late Set<int> _reminders;
  late bool _email;
  late bool _push;
  bool _signingOut = false;

  @override
  void initState() {
    super.initState();
    final prefs = ref.read(localPrefsProvider);
    _reminders = prefs.reminderOffsets().toSet();
    _email = prefs.emailReminders();
    _push = prefs.pushReminders();
  }

  Future<void> _toggleOffset(int days) async {
    setState(() => _reminders.contains(days) ? _reminders.remove(days) : _reminders.add(days));
    final sorted = _reminders.toList()..sort((a, b) => b.compareTo(a));
    await ref.read(localPrefsProvider).setReminderOffsets(sorted);
  }

  Future<void> _setEmail(bool v) async {
    setState(() => _email = v);
    await ref.read(localPrefsProvider).setEmailReminders(v);
  }

  Future<void> _setPush(bool v) async {
    setState(() => _push = v);
    await ref.read(localPrefsProvider).setPushReminders(v);
  }

  Future<void> _editName(String current) async {
    final name = await showDialog<String>(context: context, builder: (_) => _NameDialog(initial: current));
    if (name == null || name.trim().isEmpty || name.trim() == current) return;
    await ref.read(sessionProvider.notifier).setDisplayName(name.trim());
    if (mounted) FdToast.show(context, 'Name updated', aboveNav: false);
  }

  Future<void> _signOut() async {
    setState(() => _signingOut = true);
    await ref.read(sessionProvider.notifier).signOut();
    // The router redirects to Sign in.
  }

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final session = ref.watch(sessionProvider);
    if (session is! SignedIn) {
      return const FdPage(appBar: FdAppBar(title: 'Settings'), children: [FdLoading()]);
    }
    final user = session.user;
    final family = ref.watch(familyProvider);
    final members = ref.watch(membersProvider);

    final householdMeta = family.when(
      loading: () => 'Loading…',
      error: (_, __) => 'Couldn’t load',
      data: (h) {
        if (h == null) return 'Not set up yet';
        final n = members.valueOrNull?.length;
        return n == null || n == 0 ? h.name : '${h.name} · ${plural(n, 'person', 'people')}';
      },
    );

    return FdPage(
      appBar: const FdAppBar(title: 'Settings'),
      children: [
        // Profile
        Semantics(
          button: true,
          label: 'Edit your name',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _editName(session.displayName),
            child: Row(children: [
              FdAvatar(session.initials, size: 56),
              const SizedBox(width: FdSpace.s3),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(session.displayName, style: FdType.headline.copyWith(color: c.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(user.email, style: FdType.meta.copyWith(color: c.inkSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
              ExcludeSemantics(
                child: FdIconButton(FdIcons.pencil, semanticLabel: 'Edit your name', color: c.inkSecondary, onPressed: () => _editName(session.displayName)),
              ),
            ]),
          ),
        ),

        // Reminders
        const FdSectionTitle('Reminders', topGap: FdSpace.s2),
        FdCard.pad(
          child: FdGapColumn(gap: FdSpace.s3, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Remind me before each deadline', style: FdType.fieldLabel.copyWith(color: c.ink)),
            FdRowWrap(gap: FdSpace.s2, children: [
              for (final d in _offsets)
                FdChip(
                  plural(d, 'day'),
                  selected: _reminders.contains(d),
                  icon: _reminders.contains(d) ? FdIcons.check : null,
                  onTap: () => _toggleOffset(d),
                ),
            ]),
            Text('You can change this for any single deadline.', style: FdType.meta.copyWith(color: c.inkSecondary)),
            Text('The server currently sends reminders 7 and 1 day before.', style: FdType.meta.copyWith(color: c.inkSecondary)),
          ]),
        ),

        // Notifications
        FdList(children: [
          FdListRow(
            title: 'Email',
            meta: user.email,
            trailing: FdSwitch(value: _email, onChanged: _setEmail, semanticLabel: 'Email reminders'),
          ),
          FdListRow(
            title: 'Phone notifications',
            meta: 'Not set up yet',
            trailing: FdSwitch(value: _push, onChanged: _setPush, semanticLabel: 'Phone notifications'),
          ),
          FdListRow(title: 'Time zone', meta: user.timezone.replaceAll('_', ' ')),
        ]),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: FdIcon.sm(FdIcons.lock, color: c.inkSecondary)),
          const SizedBox(width: FdSpace.s2),
          Expanded(
            child: Text('Notifications never include document details, only the deadline name and date.',
                style: FdType.meta.copyWith(color: c.inkSecondary)),
          ),
        ]),

        // Account
        const FdSectionTitle('Account', topGap: FdSpace.s2),
        FdList(children: [
          FdListRow(
            leading: const FdWell(FdIcons.people),
            title: 'Household',
            meta: householdMeta,
            chevron: true,
            onTap: () => context.push(Routes.household),
          ),
          const FdListRow(
            leading: FdWell(FdIcons.lock),
            title: 'Password',
            meta: 'Not available yet',
          ),
        ]),
        FdButton.secondary('Sign out', block: true, foreground: c.danger, loading: _signingOut, onPressed: _signOut),
      ],
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.initial});
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final v = _controller.text.trim();
    if (v.isEmpty) {
      setState(() => _error = 'Enter your name.');
      return;
    }
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Your name'),
      content: FdTextField(
        label: 'Name',
        controller: _controller,
        help: 'Shown to people you share with.',
        error: _error,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(FdSpace.s4, 0, FdSpace.s4, FdSpace.s4),
      actions: [
        FdButton.quiet('Cancel', onPressed: () => Navigator.of(context).pop()),
        FdButton('Save name', onPressed: _save),
      ],
    );
  }
}
