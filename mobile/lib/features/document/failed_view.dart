import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../data/categories.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../ui/fd.dart';
import 'doc_helpers.dart';
import 'types_sheet.dart';

/// "Couldn’t read" state of a document (design Failed.dc.html).
class FailedDocumentView extends ConsumerStatefulWidget {
  const FailedDocumentView({super.key, required this.doc, required this.onBack});
  final Document doc;
  final VoidCallback onBack;

  @override
  ConsumerState<FailedDocumentView> createState() => _FailedDocumentViewState();
}

class _FailedDocumentViewState extends ConsumerState<FailedDocumentView> {
  String? _busy; // which action is running

  Document get doc => widget.doc;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final meta = [
      fileTypeLabel(doc),
      if (doc.sizeBytes != null) formatBytes(doc.sizeBytes!),
      formatDateSmart(doc.createdAt.toLocal()),
    ].join(' · ');
    final idle = _busy == null;
    return FdPage(
      withNav: true,
      appBar: FdAppBar(onBack: widget.onBack),
      children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(doc.category == null ? 'Document' : groupOf(doc.category).label, style: FdType.meta.copyWith(color: c.inkSecondary)),
          Semantics(header: true, child: Text(doc.displayFilename ?? doc.displayName, style: FdType.title)),
          const SizedBox(height: FdSpace.s2),
          FdRowWrap(children: [
            const FdBadge('Couldn’t read', kind: FdBadgeKind.failed, icon: FdIcons.xCircle),
            Text(meta, style: FdType.meta.copyWith(color: c.inkSecondary)),
          ]),
        ]),
        FdNotice.text('We couldn’t read this file. It’s saved, so nothing is lost.', kind: FdNoticeKind.danger, icon: FdIcons.alert),
        Text(
          'Blurry, dark or rotated scans are hard to read. A clearer photo usually helps. You can also type the details yourself.',
          style: FdType.callout.copyWith(color: c.inkSecondary),
        ),
        FdGapColumn(gap: FdSpace.s3, children: [
          FdButton('Try again', icon: FdIcons.retry, block: true, loading: _busy == 'retry', onPressed: idle ? _retry : null),
          FdButton.secondary('Fill in the details myself', icon: FdIcons.pencil, block: true, loading: _busy == 'type', onPressed: idle ? _fillIn : null),
          FdButton.secondary('Scan it again', icon: FdIcons.scan, block: true, onPressed: idle ? () => context.push(Routes.scan) : null),
        ]),
        Center(
          child: FdButton.quiet('Delete file', foreground: c.danger, loading: _busy == 'delete', onPressed: idle ? _delete : null),
        ),
      ],
    );
  }

  Future<void> _retry() async {
    setState(() => _busy = 'retry');
    try {
      final d = await ref.read(repositoryProvider).reprocess(doc.id);
      ref.read(documentsProvider.notifier).upsert(d);
      ref.invalidate(documentProvider(doc.id));
      if (mounted) context.push(Routes.processing(doc.id));
    } catch (e) {
      if (mounted) FdToast.error(context, e);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// The backend can't confirm a document without an extraction, so only the type is saved.
  Future<void> _fillIn() async {
    final code = await showTypesSheet(context, selected: doc.category);
    if (code == null || !mounted) return;
    setState(() => _busy = 'type');
    try {
      final d = await ref.read(repositoryProvider).updateDocument(doc.id, category: code);
      ref.read(documentsProvider.notifier).upsert(d);
      ref.invalidate(documentProvider(doc.id));
      if (mounted) FdToast.show(context, 'Saved the type. Try again to read the details.');
    } catch (e) {
      if (mounted) FdToast.error(context, e);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _delete() async {
    final ok = await confirmFd(
      context,
      title: 'Delete this file?',
      body: 'It will be removed from your vault. This can’t be undone.',
      confirm: 'Delete',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = 'delete');
    try {
      await ref.read(repositoryProvider).deleteDocument(doc.id);
      ref.read(documentsProvider.notifier).remove(doc.id);
      if (!mounted) return;
      context.go(Routes.vault);
      FdToast.show(context, 'Deleted');
    } catch (e) {
      if (mounted) {
        setState(() => _busy = null);
        FdToast.error(context, e);
      }
    }
  }
}
