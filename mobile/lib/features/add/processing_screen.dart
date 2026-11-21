import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../ui/fd.dart';

/// "Adding a document" (design Processing). Polls the document and moves on to
/// Review, Blocked or the document itself when the worker is done.
class ProcessingScreen extends ConsumerStatefulWidget {
  const ProcessingScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends ConsumerState<ProcessingScreen> {
  bool _moved = false;

  void _route(Document d) {
    if (_moved || d.isWorking) return;
    _moved = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      switch (d.reviewStatus) {
        case ReviewStatus.reviewRequired:
          context.pushReplacement(Routes.review(d.id));
        case ReviewStatus.blocked:
          context.pushReplacement(Routes.blocked(d.id));
        default:
          context.go(Routes.document(d.id));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(documentProvider(widget.id));
    final current = async.valueOrNull;
    if (current != null) _route(current);
    final notFound = async.error is ApiException && (async.error as ApiException).isNotFound;

    return FdPage(
      appBar: const FdAppBar(title: 'Adding a document'),
      footer: FdFooter(children: [
        FdButton.secondary('Back to Home', block: true, onPressed: () => context.go(Routes.home)),
      ]),
      children: [
        if (async.hasValue) ...[
          _ProgressCard(doc: async.requireValue),
          // Polling stopped on an error: let the user check again.
          if (async.hasError)
            FdNotice(
              kind: FdNoticeKind.danger,
              icon: FdIcons.alert,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(async.error is ApiException
                    ? (async.error as ApiException).message
                    : 'We couldn’t check on this document. Try again.'),
                FdButton.quiet('Check again',
                    icon: FdIcons.retry, compact: true, onPressed: () => ref.invalidate(documentProvider(widget.id))),
              ]),
            ),
        ] else if (async.hasError && notFound)
          FdNotice.text('This document isn’t in your vault anymore.', kind: FdNoticeKind.neutral, icon: FdIcons.file)
        else if (async.hasError)
          FdErrorState(error: async.error!, onRetry: () => ref.invalidate(documentProvider(widget.id)))
        else
          const FdLoading(),
        if (!notFound)
          FdNotice.text(
            'Usually under 15 seconds. You can leave this screen: it will wait in “Waiting for your review” on Home.',
            kind: FdNoticeKind.info,
            icon: FdIcons.clock,
          ),
      ],
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.doc});
  final Document doc;

  String get _meta {
    final type = doc.isPdf
        ? 'PDF'
        : switch (doc.mediaType) {
            'image/jpeg' => 'JPG',
            'image/png' => 'PNG',
            _ => null,
          };
    return [?type, if (doc.sizeBytes != null) formatBytes(doc.sizeBytes!)].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final working = doc.isWorking;
    final reading = doc.reviewStatus == ReviewStatus.processing || doc.stage == ProcessingStage.processing;
    final progress = !working ? 1.0 : (reading ? 0.6 : 0.25);

    return FdCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FdListRow(
          leading: const FdWell(FdIcons.file),
          title: doc.displayFilename ?? doc.displayName,
          meta: _meta,
          trailing: working
              ? const FdBadge('Reading', spinning: true)
              : const FdBadge('Done', kind: FdBadgeKind.ok, icon: FdIcons.checkCircle),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(FdSpace.s4, 0, FdSpace.s4, FdSpace.s4),
          child: FdGapColumn(gap: FdSpace.s3, children: [
            TweenAnimationBuilder<double>(
              tween: Tween(end: progress),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOut,
              builder: (_, v, _) => FdProgress(value: v),
            ),
            _Step(
              icon: FdIcon(FdIcons.checkCircle, color: c.success),
              title: 'Saved privately',
            ),
            _Step(
              icon: working ? FdSpinner(size: 20, color: c.brand) : FdIcon(FdIcons.checkCircle, color: c.success),
              title: 'Reading the document',
              meta: working ? 'Working out what it is' : null,
            ),
            _Step(
              icon: FdIcon(FdIcons.clock, color: working ? c.inkTertiary : c.brand),
              title: 'Finding dates and deadlines',
              pending: working,
            ),
          ]),
        ),
      ]),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.icon, required this.title, this.meta, this.pending = false});
  final Widget icon;
  final String title;
  final String? meta;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Semantics(
      label: pending ? '$title, not started' : null,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        icon,
        const SizedBox(width: FdSpace.s3),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: FdType.callout.copyWith(color: pending ? c.inkTertiary : c.ink)),
            if (meta != null) Text(meta!, style: FdType.meta.copyWith(color: c.inkSecondary)),
          ]),
        ),
      ]),
    );
  }
}
