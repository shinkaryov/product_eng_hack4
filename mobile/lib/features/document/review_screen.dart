import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../data/api_client.dart';
import '../../data/categories.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../ui/fd.dart';
import 'doc_helpers.dart';
import 'types_sheet.dart';

/// Review details (design Review.dc.html): check what AI filled in, fix it, confirm.
class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  /// Latest extraction returned by a correction (newer than the provider's copy).
  Extraction? _ext;
  bool _saving = false;
  bool _confirming = false;

  String get id => widget.id;

  @override
  Widget build(BuildContext context) {
    final docAsync = ref.watch(documentProvider(id));
    return docAsync.when(
      loading: () => _shell(children: const [FdLoading()]),
      error: (e, _) => _shell(children: [FdErrorState(error: e, onRetry: () => ref.invalidate(documentProvider(id)))]),
      data: (doc) {
        if (doc.isWorking) {
          return _shell(children: [
            const FdLoading(label: 'Still reading your document…'),
            Center(child: FdButton.quiet('See progress', onPressed: () => context.pushReplacement(Routes.processing(id)))),
          ]);
        }
        switch (doc.reviewStatus) {
          case ReviewStatus.blocked:
            return _shell(children: [
              FdNotice.text('We don’t store this kind of document, so we deleted the file.', kind: FdNoticeKind.danger, icon: FdIcons.ban),
              FdButton.secondary('See why', block: true, onPressed: () => context.pushReplacement(Routes.blocked(id))),
            ]);
          case ReviewStatus.failed:
            return _shell(children: [
              FdNotice.text('We couldn’t read this file. It’s saved, so nothing is lost.', kind: FdNoticeKind.danger, icon: FdIcons.alert),
              FdButton.secondary('Open document', block: true, onPressed: () => context.go(Routes.document(id))),
            ]);
          default:
            return _review(doc);
        }
      },
    );
  }

  Widget _shell({required List<Widget> children, Widget? footer}) => FdPage(
        appBar: const FdAppBar(title: 'Review details'),
        footer: footer,
        children: children,
      );

  Widget _review(Document doc) {
    final extAsync = ref.watch(extractionProvider(id));
    final ext = _ext ?? extAsync.valueOrNull;
    if (ext == null) {
      if (extAsync.hasError) {
        return _shell(children: [
          FdErrorState(error: extAsync.error!, onRetry: () => ref.invalidate(extractionProvider(id))),
        ]);
      }
      return _shell(children: const [FdLoading()]);
    }

    final readOnly = doc.reviewStatus == ReviewStatus.ready;
    final c = context.fd;
    final fields = buildFields(doc, ext);
    final warnings = (ext.facts['warnings'] is List ? ext.facts['warnings'] as List : const [])
        .map((w) => w.toString().trim())
        .where((w) => w.isNotEmpty)
        .toList();

    return _shell(
      footer: FdFooter(children: [
        if (readOnly)
          FdButton('Open document', block: true, onPressed: () => context.go(Routes.document(id)))
        else
          FdButton('Confirm details', block: true, loading: _confirming, onPressed: _saving || _confirming ? null : () => _confirm(doc, ext)),
      ]),
      children: [
        FdCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FdListRow(
              title: doc.displayFilename ?? doc.displayName,
              meta: fileMeta(doc, pages: ext.pages.length),
              leading: const FdWell(FdIcons.file),
            ),
            FdSuggest(
              label: 'Category',
              value: categoryPath(doc.category),
              trailing: readOnly
                  ? null
                  : FdButton.quiet('Change', compact: true, onPressed: _saving ? null : () => _changeType(doc)),
            ),
          ]),
        ),
        Text(
          readOnly ? 'These details are saved. To change them, open the document.' : 'Check these details. Nothing is saved until you confirm.',
          style: FdType.callout.copyWith(color: c.inkSecondary),
        ),
        if (fields.isEmpty)
          FdNotice.text('We didn’t find any details in this document. You can still confirm it.', icon: FdIcons.file)
        else
          FdFields(
            head: readOnly ? null : 'Filled in from your document. Tap the pencil to fix anything we got wrong.',
            rows: [for (final f in fields) _row(f, ext, readOnly)],
          ),
        if (warnings.isNotEmpty)
          FdNotice(
            kind: FdNoticeKind.info,
            icon: FdIcons.alert,
            child: FdGapColumn(gap: FdSpace.s1, children: [for (final w in warnings) Text(w)]),
          ),
      ],
    );
  }

  Widget _row(DocField f, Extraction ext, bool readOnly) {
    if (f.missing) {
      return FdFieldRow(
        label: f.label,
        value: 'Not specified',
        missing: true,
        trailing: readOnly ? null : FdButton.quiet('Add', compact: true, onPressed: _saving ? null : () => _edit(f, ext)),
      );
    }
    return FdFieldRow(
      label: f.label,
      value: f.value!,
      trailing: readOnly
          ? null
          : Row(mainAxisSize: MainAxisSize.min, children: [
              if (f.edited) const FdEditedTag() else const FdAiMark(),
              const SizedBox(width: FdSpace.s1),
              FdIconButton(
                FdIcons.pencil,
                semanticLabel: 'Edit ${f.label.toLowerCase()}',
                onPressed: _saving ? null : () => _edit(f, ext),
              ),
            ]),
    );
  }

  Future<void> _edit(DocField f, Extraction ext) async {
    String? value;
    if (f.isDate) {
      final d = await pickDate(context, initial: parseIsoDay(f.raw), help: f.label);
      if (d != null) value = isoDay(d);
    } else {
      value = await showEditFieldDialog(context, label: f.label, initial: f.raw);
    }
    if (value == null || value == f.raw || !mounted) return;
    setState(() => _saving = true);
    try {
      final fresh = await ref.read(repositoryProvider).correct(id, expectedRevision: ext.revision, fields: {f.key: value});
      if (!mounted) return;
      setState(() => _ext = fresh);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isConflict) {
        _reloadExtraction();
        FdToast.show(context, 'This document changed. We loaded the latest details, so check them again.', aboveNav: false);
      } else {
        FdToast.error(context, e);
      }
    } catch (e) {
      if (mounted) FdToast.error(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _reloadExtraction() {
    setState(() => _ext = null);
    ref.invalidate(extractionProvider(id));
  }

  Future<void> _changeType(Document doc) async {
    final code = await showTypesSheet(context, selected: doc.category);
    if (code == null || code == doc.category || !mounted) return;
    setState(() => _saving = true);
    try {
      final updated = await ref.read(repositoryProvider).updateDocument(id, category: code);
      ref.read(documentsProvider.notifier).upsert(updated);
      ref.invalidate(documentProvider(id));
    } catch (e) {
      if (mounted) FdToast.error(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirm(Document doc, Extraction ext) async {
    setState(() => _confirming = true);
    final repo = ref.read(repositoryProvider);
    try {
      final confirmed = await repo.confirm(id, resultRevision: doc.resultRevision ?? 0, extractionRevision: ext.revision);
      ref.read(documentsProvider.notifier).upsert(confirmed);
      ref.invalidate(documentProvider(id));
      ref.invalidate(documentDeadlinesProvider(id));
      ref.invalidate(timelineProvider);
      List<Deadline> proposed = const [];
      try {
        proposed = await repo.documentDeadlines(id, state: 'PROPOSED');
      } catch (_) {
        // The document is saved; deadlines can be confirmed later from the document.
      }
      if (!mounted) return;
      if (proposed.isNotEmpty) {
        context.pushReplacement(Routes.confirmDeadline(id));
      } else {
        context.go(Routes.document(id));
        FdToast.show(context, 'Saved');
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _confirming = false);
      if (e.isConflict) {
        _reloadExtraction();
        ref.invalidate(documentProvider(id));
        FdToast.show(context, 'This document changed. We loaded the latest details, so check them again.', aboveNav: false);
      } else {
        FdToast.error(context, e);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _confirming = false);
      FdToast.error(context, e);
    }
  }
}
