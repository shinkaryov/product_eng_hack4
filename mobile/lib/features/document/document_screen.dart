import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../data/categories.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../ui/fd.dart';
import 'doc_helpers.dart';
import 'document_tabs.dart';
import 'failed_view.dart';
import 'share_sheet.dart';

/// Document (design Document.dc.html) in the Vault tab: Details / File / Deadlines / Sharing.
/// FAILED documents show the Failed.dc.html state; documents still processing or
/// waiting for review show a card that opens the right screen.
class DocumentScreen extends ConsumerStatefulWidget {
  const DocumentScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<DocumentScreen> createState() => _DocumentScreenState();
}

class _DocumentScreenState extends ConsumerState<DocumentScreen> {
  int _tab = 0;

  String get id => widget.id;

  void _back() => context.canPop() ? context.pop() : context.go(Routes.vault);

  Widget _page({required List<Widget> children, Widget? trailing}) => FdPage(
        withNav: true,
        appBar: FdAppBar(onBack: _back, trailing: trailing),
        onRefresh: () async {
          ref.invalidate(documentProvider(id));
          ref.invalidate(extractionProvider(id));
          ref.invalidate(documentDeadlinesProvider(id));
          ref.invalidate(sharesProvider(id));
        },
        children: children,
      );

  @override
  Widget build(BuildContext context) {
    final docAsync = ref.watch(documentProvider(id));
    return docAsync.when(
      loading: () => FdPage(withNav: true, appBar: FdAppBar(onBack: _back), children: const [FdLoading()]),
      error: (e, _) => FdPage(
        withNav: true,
        appBar: FdAppBar(onBack: _back),
        children: [FdErrorState(error: e, onRetry: () => ref.invalidate(documentProvider(id)))],
      ),
      data: (doc) {
        if (doc.reviewStatus == ReviewStatus.failed && !doc.isWorking) return FailedDocumentView(doc: doc, onBack: _back);
        if (doc.reviewStatus != ReviewStatus.ready || doc.isWorking) return _pending(doc);
        return _ready(doc);
      },
    );
  }

  // ── Not ready yet ──────────────────────────────────────────────────────

  Widget _pending(Document doc) {
    final c = context.fd;
    final (Widget badge, String text, Widget button) = switch (doc.reviewStatus) {
      ReviewStatus.blocked => (
          const FdBadge('Not stored', kind: FdBadgeKind.failed, icon: FdIcons.ban),
          'We don’t store this kind of document, so we deleted the file.',
          FdButton.secondary('See why', block: true, onPressed: () => context.push(Routes.blocked(id))),
        ),
      ReviewStatus.reviewRequired when !doc.isWorking => (
          const FdBadge('Review', kind: FdBadgeKind.review, icon: FdIcons.sparkle),
          'Check the details we found. Nothing is saved until you confirm.',
          FdButton('Review details', block: true, onPressed: () => context.push(Routes.review(id))),
        ),
      _ => (
          const FdBadge('Reading', spinning: true),
          'We’re still reading this document. It usually takes under a minute.',
          FdButton.secondary('See progress', block: true, onPressed: () => context.push(Routes.processing(id))),
        ),
    };
    return _page(children: [
      DocHeader(meta: categoryPath(doc.category), title: doc.displayName, badges: [badge]),
      FdCard.pad(
        child: FdGapColumn(gap: FdSpace.s3, children: [
          Text(text, style: FdType.body.copyWith(color: c.ink)),
          button,
        ]),
      ),
    ]);
  }

  // ── Ready ──────────────────────────────────────────────────────────────

  Widget _ready(Document doc) {
    final me = ref.watch(currentUserProvider).user.id;
    final isOwner = doc.ownerId == me;
    final deadlines = ref.watch(documentDeadlinesProvider(id)).valueOrNull ?? const <Deadline>[];
    final done = ref.watch(doneDeadlinesProvider);
    final active = deadlines.where((d) => d.state != DeadlineState.rejected).toList();

    // Nearest confirmed, not done: first upcoming, otherwise the latest overdue one.
    final confirmed = active
        .where((d) => d.state == DeadlineState.confirmed && d.dueOn != null && !done.contains(d.id))
        .toList()
      ..sort((a, b) => a.dueOn!.compareTo(b.dueOn!));
    final upcoming = confirmed.where((d) => daysUntil(d.dueOn!) >= 0);
    final nearest = upcoming.isNotEmpty ? upcoming.first : (confirmed.isNotEmpty ? confirmed.last : null);

    final labels = ['Details', 'File', 'Deadlines', if (isOwner) 'Sharing'];
    final tab = _tab.clamp(0, labels.length - 1);

    final Widget body = switch (tab) {
      0 => DetailsTab(doc: doc, isOwner: isOwner),
      1 => FileTab(doc: doc, isOwner: isOwner),
      2 => DeadlinesTab(doc: doc, isOwner: isOwner),
      _ => SharingTab(doc: doc),
    };

    return _page(
      trailing: isOwner
          ? FdButton.quiet('Share', icon: FdIcons.link, compact: true, onPressed: () async {
              await showShareSheet(context, doc);
              ref.invalidate(sharesProvider(id));
            })
          : null,
      children: [
        DocHeader(
          meta: categoryPath(doc.category),
          title: doc.displayName,
          badges: [if (nearest != null) deadlineBadge(nearest)],
        ),
        FdTabs(
          labels: labels,
          selected: tab,
          counts: {if (active.isNotEmpty) 2: active.length},
          onSelect: (i) => setState(() => _tab = i),
        ),
        body,
      ],
    );
  }
}
