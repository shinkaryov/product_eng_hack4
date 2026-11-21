import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../data/categories.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../ui/fd.dart';
import '../add/add_sheet.dart';
import 'vault_row.dart';

/// Vault tab: every document, newest first, filtered by group chip and name search.
class VaultScreen extends ConsumerStatefulWidget {
  const VaultScreen({super.key});

  @override
  ConsumerState<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends ConsumerState<VaultScreen> {
  final _search = TextEditingController();
  DocGroup? _group; // null = All

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    ref.invalidate(timelineProvider);
    try {
      await ref.read(documentsProvider.notifier).refresh();
    } catch (e) {
      if (mounted) FdToast.error(context, e);
    }
  }

  void _clearSearch() {
    _search.clear();
    setState(() {});
  }

  bool _matches(Document d, String q) {
    if (q.isEmpty) return true;
    final hay = [d.displayName, d.title, d.displayFilename, d.card?.issuer].whereType<String>().join(' ').toLowerCase();
    return q.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).every(hay.contains);
  }

  @override
  Widget build(BuildContext context) {
    final docsAsync = ref.watch(documentsProvider);
    final docs = docsAsync.valueOrNull;

    final children = <Widget>[_TopBar(count: docs?.length)];

    if (docs == null) {
      if (docsAsync.hasError) {
        children.add(FdErrorState(error: docsAsync.error!, onRetry: () => ref.invalidate(documentsProvider)));
      } else {
        children.add(const FdLoading());
      }
    } else if (docs.isEmpty) {
      children.add(const _EmptyVault());
    } else {
      final timeline = ref.watch(timelineProvider).valueOrNull ?? const <Deadline>[];
      final done = ref.watch(doneDeadlinesProvider);
      final q = _search.text.trim().toLowerCase();
      final sorted = [...docs]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final shown = sorted.where((d) => (_group == null || groupOf(d.category) == _group) && _matches(d, q)).toList();

      children.add(FdSearchField(controller: _search, onChanged: (_) => setState(() {})));
      if (shown.isEmpty && q.isNotEmpty) {
        children.add(_NoResults(
          query: _search.text.trim(),
          onAsk: () => context.go(Routes.askWith(_search.text.trim())),
          onClear: _clearSearch,
        ));
      } else {
        children.add(_GroupChips(selected: _group, onSelect: (g) => setState(() => _group = g)));
        if (shown.isEmpty) {
          children.add(_EmptyGroup(group: _group ?? DocGroup.other));
        } else {
          children.add(FdList(children: [
            for (final d in shown)
              VaultDocumentRow(
                key: ValueKey(d.id),
                doc: d,
                deadline: nearestDeadline(d.id, timeline, done),
                onTap: () => openDocument(context, d),
              ),
          ]));
        }
      }
    }

    return FdPage(
      withNav: true,
      topPadding: FdSpace.s3,
      onRefresh: _refresh,
      children: children,
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({this.count});
  final int? count;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: FdSize.tapMin),
      child: Row(children: [
        Expanded(child: Semantics(header: true, child: Text('Vault', style: FdType.title))),
        const SizedBox(width: FdSpace.s3),
        if (count != null) Text(plural(count!, 'document'), style: FdType.meta.copyWith(color: context.fd.inkSecondary)),
      ]),
    );
  }
}

/// Horizontal chip row that bleeds to the screen edges (design: negative 20 px margin).
class _GroupChips extends StatelessWidget {
  const _GroupChips({required this.selected, required this.onSelect});
  final DocGroup? selected;
  final ValueChanged<DocGroup?> onSelect;

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      FdChip('All', selected: selected == null, onTap: () => onSelect(null)),
      for (final g in DocGroup.values) FdChip(g.label, selected: selected == g, onTap: () => onSelect(g)),
    ];
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth + FdSpace.s5 * 2;
      return SizedBox(
        height: 44,
        child: OverflowBox(
          minWidth: w,
          maxWidth: w,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: FdSpace.s5, vertical: 2),
            itemCount: chips.length,
            separatorBuilder: (_, _) => const SizedBox(width: FdSpace.s2),
            itemBuilder: (_, i) => Center(child: chips[i]),
          ),
        ),
      );
    });
  }
}

/// Centered state: 56 px well, section title, explanation, optional actions.
class _CenteredState extends StatelessWidget {
  const _CenteredState({required this.icon, required this.title, required this.body, this.actions = const []});
  final FdIcons icon;
  final String title;
  final String body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: FdSpace.s10),
      child: FdGapColumn(
        gap: FdSpace.s3,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          FdWell(icon, size: 56, radius: FdRadius.lg, iconSize: 24),
          Semantics(header: true, child: Text(title, textAlign: TextAlign.center, style: FdType.section)),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Text(body, textAlign: TextAlign.center, style: FdType.callout.copyWith(color: context.fd.inkSecondary)),
          ),
          if (actions.isNotEmpty) FdRowWrap(alignment: WrapAlignment.center, children: actions),
        ],
      ),
    );
  }
}

class _NoResults extends StatelessWidget {
  const _NoResults({required this.query, required this.onAsk, required this.onClear});
  final String query;
  final VoidCallback onAsk;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => _CenteredState(
        icon: FdIcons.search,
        title: 'No documents match “$query”',
        body: 'Search looks at document names. To search inside documents, ask instead.',
        actions: [
          FdButton('Ask about it', icon: FdIcons.sparkle, onPressed: onAsk),
          FdButton.secondary('Clear search', onPressed: onClear),
        ],
      );
}

class _EmptyGroup extends StatelessWidget {
  const _EmptyGroup({required this.group});
  final DocGroup group;

  @override
  Widget build(BuildContext context) => _CenteredState(
        icon: group.icon,
        title: 'Nothing in ${group.label} yet',
        body: 'Documents you add show up here once we know what they are.',
      );
}

class _EmptyVault extends StatelessWidget {
  const _EmptyVault();

  @override
  Widget build(BuildContext context) => _CenteredState(
        icon: FdIcons.file,
        title: 'Your vault is empty',
        body: 'Add a lease, a policy or an ID. We read it and keep track of its dates.',
        actions: [FdButton('Add a document', icon: FdIcons.plus, onPressed: () => showAddSheet(context))],
      );
}
