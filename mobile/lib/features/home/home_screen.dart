import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../data/categories.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../ui/fd.dart';
import '../add/add_sheet.dart';
import '../document/types_sheet.dart';
import 'home_model.dart';
import 'home_widgets.dart';

/// Home tab (designs Main / HomeOk / HomeEmpty).
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    ref.invalidate(timelineProvider);
    ref.invalidate(familyProvider);
    try {
      await Future.wait([
        ref.read(documentsProvider.notifier).refresh(),
        ref.read(timelineProvider.future),
      ]);
    } catch (e) {
      if (context.mounted) FdToast.error(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final family = ref.watch(familyProvider);
    final docsAsync = ref.watch(documentsProvider);
    final timelineAsync = ref.watch(timelineProvider);
    final done = ref.watch(doneDeadlinesProvider);

    final firstName = user.displayName.trim().split(RegExp(r'\s+')).first;
    final vaultName = '${firstName.isEmpty ? 'Your' : '$firstName’s'} vault';
    final household = family.valueOrNull;
    final String? barTitle = family.hasValue ? (household?.name ?? vaultName) : (family.hasError ? vaultName : null);

    final topBar = HomeTopBar(
      title: barTitle,
      initials: user.initials,
      onTitle: () => context.push(Routes.household),
      onAvatar: () => context.push(household != null ? Routes.household : Routes.settings),
      avatarLabel: household != null ? 'Household and account' : 'Account',
    );

    final List<Widget> body;
    if (docsAsync.hasError && !docsAsync.hasValue) {
      body = [FdErrorState(error: docsAsync.error!, onRetry: () => ref.invalidate(documentsProvider))];
    } else if (!docsAsync.hasValue || (!timelineAsync.hasValue && !timelineAsync.hasError)) {
      body = const [FdLoading()];
    } else {
      final model = HomeModel.build(docs: docsAsync.value!, timeline: timelineAsync.valueOrNull ?? const [], done: done);
      final timelineFailed = timelineAsync.hasError && !timelineAsync.hasValue;
      body = model.isEmpty
          ? _emptyBody(context, model)
          : _vaultBody(context, ref, model, timelineFailed: timelineFailed);
    }

    return FdPage(
      withNav: true,
      topPadding: FdSpace.s3,
      onRefresh: () => _refresh(context, ref),
      children: [topBar, ...body],
    );
  }

  // ── New vault (HomeEmpty) ───────────────────────────────────────────────

  List<Widget> _emptyBody(BuildContext context, HomeModel m) {
    final c = context.fd;
    final pending = _pendingRows(context, m);
    return [
      Padding(
        padding: const EdgeInsets.only(top: FdSpace.s3),
        child: FdCard.pad(
          child: FdGapColumn(gap: FdSpace.s3, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const FdWell(FdIcons.file, size: 52, radius: FdRadius.lg, iconSize: 24),
            Semantics(header: true, child: Text('Add your first document', style: FdType.lead.copyWith(color: c.ink))),
            Text(
              'Start with a lease or an insurance policy. We’ll find the dates that matter and remind you before they pass.',
              style: FdType.callout.copyWith(color: c.inkSecondary),
            ),
            FdRowWrap(children: [
              FdButton('Scan', icon: FdIcons.scan, onPressed: () => context.push(Routes.scan)),
              FdButton.secondary('Upload a file', icon: FdIcons.upload, onPressed: () => showAddSheet(context)),
            ]),
          ]),
        ),
      ),
      if (pending.isNotEmpty) FdList(children: pending),
      const FdSectionTitle('What we can read', topGap: FdSpace.s2),
      FdTileGrid(children: [
        for (final g in DocGroup.values.where((g) => g != DocGroup.other)) FdTile(icon: g.icon, name: g.label, empty: true),
        FdTile(icon: FdIcons.search, name: 'All types', empty: true, onTap: () => showTypesSheet(context, pickable: false)),
      ]),
      HomeCardLink(
        icon: FdIcons.people,
        title: 'Invite your household',
        meta: 'Share some or all documents with family',
        onTap: () => context.push(Routes.household),
      ),
    ];
  }

  // ── Vault with documents (Main / HomeOk) ────────────────────────────────

  List<Widget> _vaultBody(BuildContext context, WidgetRef ref, HomeModel m, {required bool timelineFailed}) {
    final ok = m.attentionCount == 0;
    final waiting = [
      for (final d in m.review) _reviewCard(context, d),
    ];
    final pending = _pendingRows(context, m);
    final sectionGap = ok ? FdSpace.s2 : FdSpace.s4;

    return [
      Padding(
        padding: const EdgeInsets.only(top: FdSpace.s3),
        child: timelineFailed ? _timelineError(context, ref) : _status(m),
      ),
      if (!timelineFailed) ..._deadlines(context, ref, m),
      if (waiting.isNotEmpty || pending.isNotEmpty) ...[
        FdSectionTitle('Waiting for your review', topGap: sectionGap),
        ...waiting,
        if (pending.isNotEmpty) FdList(children: pending),
      ],
      FdSectionTitle('Your documents', topGap: sectionGap),
      FdTileGrid(children: _tiles(context, m, ok: ok)),
      HomeCardLink(
        brand: true,
        icon: FdIcons.sparkle,
        title: 'Ask about your documents',
        meta: '“${m.sampleQuestion}”',
        onTap: () => context.go(Routes.ask),
      ),
    ];
  }

  Widget _status(HomeModel m) {
    final n = m.attentionCount;
    if (n == 0) {
      return const FdStatus(
        kind: FdStatusKind.ok,
        title: 'Your documents are in order',
        subtitle: 'Nothing is due in the next 30 days.',
      );
    }
    final title = '${plural(n, 'thing')} ${n == 1 ? 'needs' : 'need'} your attention';
    if (m.soon.isNotEmpty) {
      final first = m.soon.first.dueOn!;
      final days = daysUntil(first);
      final when = days == 0 ? 'today' : days == 1 ? 'tomorrow' : formatDateSmart(first);
      return FdStatus(kind: FdStatusKind.attention, title: title, subtitle: 'The first one is due $when.');
    }
    final subtitle = m.overdue.length == 1
        ? _overdueSentence(m.overdue.first, m.byId[m.overdue.first.documentId])
        : 'The oldest one was due ${formatDateSmart(m.overdue.first.dueOn!)}.';
    return FdStatus(kind: FdStatusKind.overdue, title: title, subtitle: subtitle);
  }

  String _overdueSentence(Deadline d, Document? doc) {
    final date = formatDateSmart(d.dueOn!);
    final name = deadlineDocName(d, doc);
    if (isExpiryKind(d.kind)) return '$name expired $date.';
    if (d.label?.trim().isNotEmpty ?? false) return '${d.label!.trim()} was due $date.';
    if (d.kind == 'PAYMENT_DUE') return 'A payment for $name was due $date.';
    return 'A deadline for $name was $date.';
  }

  Widget _timelineError(BuildContext context, WidgetRef ref) {
    return FdNotice(
      kind: FdNoticeKind.danger,
      icon: FdIcons.alert,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Couldn’t load your deadlines.'),
        FdButton.quiet('Try again', compact: true, onPressed: () => ref.invalidate(timelineProvider)),
      ]),
    );
  }

  void _openForDeadline(BuildContext context, HomeModel m, Deadline d) {
    final doc = m.byId[d.documentId];
    if (doc != null) {
      openDocument(context, doc);
    } else {
      context.go(Routes.document(d.documentId));
    }
  }

  void _markDone(BuildContext context, WidgetRef ref, Deadline d) {
    final notifier = ref.read(doneDeadlinesProvider.notifier);
    notifier.markDone(d.id);
    FdToast.show(context, 'Marked as done', actionLabel: 'Undo', onAction: () => notifier.undo(d.id));
  }

  List<Widget> _deadlines(BuildContext context, WidgetRef ref, HomeModel m) {
    if (m.attentionCount == 0) {
      final next = m.later.take(2).toList();
      if (next.isEmpty) return const [];
      return [
        const FdSectionTitle('Next up', topGap: FdSpace.s2),
        FdList(children: [for (final d in next) _deadlineRow(context, m, d)]),
      ];
    }

    final out = <Widget>[];
    final hero = m.soon.isEmpty ? null : m.soon.first;
    if (hero != null) {
      final doc = m.byId[hero.documentId];
      final name = deadlineDocName(hero, doc);
      final hasLabel = hero.label?.trim().isNotEmpty ?? false;
      final due = 'Due ${formatDate(hero.dueOn!)}.';
      out.add(HomeHero(
        date: hero.dueOn!,
        days: daysUntil(hero.dueOn!),
        eyebrow: deadlineKindEyebrow(hero.kind),
        title: hasLabel ? hero.label!.trim() : name,
        meta: hasLabel ? '$name. $due' : due,
        onDone: () => _markDone(context, ref, hero),
        onView: () => _openForDeadline(context, m, hero),
      ));
    }

    final rows = <Widget>[
      for (final d in m.overdue) _overdueRow(context, m, d),
      for (final d in m.soon.skip(1)) _deadlineRow(context, m, d),
    ];
    if (rows.isNotEmpty) out.add(FdList(children: rows));
    return out;
  }

  Widget _overdueRow(BuildContext context, HomeModel m, Deadline d) {
    final doc = m.byId[d.documentId];
    final date = formatDateSmart(d.dueOn!);
    final expiry = isExpiryKind(d.kind);
    final issuer = doc?.card?.issuer?.trim();
    final String meta;
    if (expiry) {
      meta = (issuer != null && issuer.isNotEmpty) ? '$issuer, expired $date' : 'Expired $date';
    } else {
      meta = '${deadlineTitle(d)}, was due $date';
    }
    return FdListRow(
      leading: FdWell(groupOf(doc?.category).icon),
      title: deadlineDocName(d, doc),
      meta: meta,
      trailing: FdBadge(expiry ? 'Expired' : 'Overdue', kind: FdBadgeKind.overdue, icon: FdIcons.xCircle),
      onTap: () => _openForDeadline(context, m, d),
    );
  }

  Widget _deadlineRow(BuildContext context, HomeModel m, Deadline d) {
    final doc = m.byId[d.documentId];
    final days = daysUntil(d.dueOn!);
    final issuer = doc?.card?.issuer?.trim();
    final source = (issuer != null && issuer.isNotEmpty) ? issuer : deadlineDocName(d, doc);
    return FdListRow(
      leading: FdDateTile.forDays(d.dueOn!, days),
      title: deadlineTitle(d),
      meta: '$source · ${inDays(days)}',
      chevron: true,
      onTap: () => _openForDeadline(context, m, d),
    );
  }

  // ── Review / processing rows ────────────────────────────────────────────

  Widget _reviewCard(BuildContext context, Document d) {
    final type = docTypeOf(d.category);
    final label = (type == null || type.group == DocGroup.other) ? 'We couldn’t tell what this is' : 'Looks like ${_lowerFirst(type.label)}';
    final n = d.card?.keyFacts.length ?? 0;
    return FdCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FdListRow(
          leading: const FdWell(FdIcons.file),
          title: d.displayFilename ?? d.displayName,
          meta: uploadedAgo(d.createdAt),
        ),
        FdSuggest(
          label: label,
          value: n > 0 ? '${plural(n, 'detail')} found. Review them' : 'Review them',
          chevron: true,
          onTap: () => openDocument(context, d),
        ),
      ]),
    );
  }

  /// Reading / Couldn’t read / Not stored rows.
  List<Widget> _pendingRows(BuildContext context, HomeModel m) => [
        for (final d in m.working)
          FdListRow(
            leading: const FdWell(FdIcons.file),
            title: d.displayName,
            meta: uploadedAgo(d.createdAt),
            trailing: const FdBadge('Reading', spinning: true),
            onTap: () => openDocument(context, d),
          ),
        for (final d in m.failed)
          FdListRow(
            leading: const FdWell(FdIcons.file),
            title: d.displayName,
            meta: uploadedAgo(d.createdAt),
            trailing: const FdBadge('Couldn’t read', kind: FdBadgeKind.failed, icon: FdIcons.xCircle),
            onTap: () => openDocument(context, d),
          ),
        for (final d in m.blocked)
          FdListRow(
            leading: const FdWell(FdIcons.file),
            title: d.displayName,
            meta: blockedShort(d.policyReason),
            trailing: const FdBadge('Not stored', icon: FdIcons.lock),
            onTap: () => openDocument(context, d),
          ),
      ];

  // ── Tiles ───────────────────────────────────────────────────────────────

  List<Widget> _tiles(BuildContext context, HomeModel m, {required bool ok}) {
    void toVault() => context.go(Routes.vault);
    Widget tile(DocGroup g) {
      final overdue = m.groupOverdue[g] ?? 0;
      String? flag;
      var flagOverdue = false;
      FdIcons? flagIcon;
      if (overdue > 0) {
        flag = '$overdue expired';
        flagOverdue = true;
      } else if (m.groupSoon.contains(g)) {
        flag = 'Due soon';
      } else if (g == DocGroup.other && m.unsorted > 0) {
        flag = '${m.unsorted} unsorted';
        flagIcon = FdIcons.search;
      }
      return FdTile(
        icon: g.icon,
        name: g.label,
        count: m.groupCounts[g],
        flag: flag,
        flagOverdue: flagOverdue,
        flagIcon: flagIcon,
        onTap: toVault,
      );
    }

    if (ok) {
      return [
        for (final g in DocGroup.values.where((g) => g != DocGroup.other)) tile(g),
        FdTile(icon: FdIcons.grid, name: 'All documents', count: m.total, onTap: toVault),
      ];
    }
    return [for (final g in DocGroup.values) tile(g)];
  }
}

String _lowerFirst(String s) {
  if (s.length < 2) return s.toLowerCase();
  // Keep acronyms ("ID card").
  if (s[1].toUpperCase() == s[1] && s[1].toLowerCase() != s[1]) return s;
  return s[0].toLowerCase() + s.substring(1);
}
