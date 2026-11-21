import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/router.dart';
import '../../data/categories.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../ui/fd.dart';
import 'doc_helpers.dart';
import 'share_sheet.dart';

// Tab bodies of the Document screen. Each returns a column that sits in the page's 16 px gap.

/// One deadline row (well, title, date + reminders, days badge).
class DeadlineRow extends StatelessWidget {
  const DeadlineRow({super.key, required this.deadline, this.done = false, this.onTap});
  final Deadline deadline;
  final bool done;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final d = deadline;
    final due = d.dueOn;
    final proposed = d.state == DeadlineState.proposed;
    final n = due == null ? null : daysUntil(due);
    final String meta;
    if (due == null) {
      meta = 'No date yet';
    } else if (proposed) {
      meta = '${formatDate(due)}. Check this date';
    } else if (!done && n! >= 0) {
      meta = '${formatDate(due)}. Reminders 7 and 1 day before';
    } else {
      meta = formatDate(due);
    }
    final Widget? badge = proposed
        ? const FdBadge('To confirm', kind: FdBadgeKind.review, icon: FdIcons.sparkle)
        : done
            ? const FdBadge('Done', kind: FdBadgeKind.ok, icon: FdIcons.check)
            : n == null
                ? null
                : FdBadge.days(n);
    return FdListRow(
      leading: FdWell(deadlineIcon(d.kind)),
      title: deadlineTitle(d),
      meta: meta,
      metaWraps: true,
      trailing: badge,
      onTap: onTap,
      chevron: onTap != null,
    );
  }
}

List<Deadline> _sorted(Iterable<Deadline> list) => list.toList()
  ..sort((a, b) {
    if (a.dueOn == null) return 1;
    if (b.dueOn == null) return -1;
    return a.dueOn!.compareTo(b.dueOn!);
  });

// ── Details ─────────────────────────────────────────────────────────────

class DetailsTab extends ConsumerWidget {
  const DetailsTab({super.key, required this.doc, required this.isOwner});
  final Document doc;
  final bool isOwner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final extAsync = ref.watch(extractionProvider(doc.id));
    final deadlines = ref.watch(documentDeadlinesProvider(doc.id)).valueOrNull ?? const <Deadline>[];
    final done = ref.watch(doneDeadlinesProvider);
    final confirmed = _sorted(deadlines.where((d) => d.state == DeadlineState.confirmed));
    final proposed = deadlines.where((d) => d.state == DeadlineState.proposed).length;

    final Widget fields = extAsync.when(
      loading: () => const FdLoading(),
      error: (e, _) => FdErrorState(error: e, onRetry: () => ref.invalidate(extractionProvider(doc.id))),
      data: (ext) {
        final rows = buildFields(doc, ext);
        if (rows.isEmpty) return FdNotice.text('We didn’t find any details in this document.', icon: FdIcons.file);
        return FdFields(rows: [for (final f in rows) _row(context, f)]);
      },
    );

    return FdGapColumn(gap: FdSpace.s4, children: [
      fields,
      if (confirmed.isNotEmpty || (isOwner && proposed > 0)) ...[
        const FdSectionTitle('Deadlines'),
        FdList(children: [
          for (final d in confirmed) DeadlineRow(deadline: d, done: done.contains(d.id)),
          if (isOwner && proposed > 0)
            FdListRow(
              leading: const FdWell(FdIcons.sparkle),
              title: proposed == 1 ? '1 date to confirm' : '$proposed dates to confirm',
              meta: 'We found these in your document',
              chevron: true,
              onTap: () => context.push(Routes.confirmDeadline(doc.id)),
            ),
        ]),
      ],
      _PrivacyNotice(doc: doc, isOwner: isOwner),
    ]);
  }

  Widget _row(BuildContext context, DocField f) {
    if (f.missing) return FdFieldRow(label: f.label, value: 'Not specified', missing: true);
    if (f.identifier && f.raw != null) {
      return FdFieldRow(
        label: f.label,
        value: maskNumber(f.raw!),
        trailing: FdIconButton(
          FdIcons.copy,
          semanticLabel: 'Copy ${f.label.toLowerCase()}',
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: f.raw!));
            if (context.mounted) FdToast.show(context, 'Copied');
          },
        ),
      );
    }
    return FdFieldRow(label: f.label, value: f.value!);
  }
}

class _PrivacyNotice extends ConsumerWidget {
  const _PrivacyNotice({required this.doc, required this.isOwner});
  final Document doc;
  final bool isOwner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isOwner) {
      return FdNotice.text('Shared with you. You can view and download it.', icon: FdIcons.people);
    }
    final shares = ref.watch(sharesProvider(doc.id)).valueOrNull;
    final family = ref.watch(familyProvider).valueOrNull;
    if (shares == null) return const SizedBox.shrink();
    if (shares.isEmpty) return FdNotice.text('Private. Only you can see this document.', icon: FdIcons.lock);
    return FdNotice.text('Shared with ${family?.name ?? 'your household'}.', icon: FdIcons.people);
  }
}

// ── File ────────────────────────────────────────────────────────────────

class FileTab extends ConsumerStatefulWidget {
  const FileTab({super.key, required this.doc, required this.isOwner});
  final Document doc;
  final bool isOwner;

  @override
  ConsumerState<FileTab> createState() => _FileTabState();
}

class _FileTabState extends ConsumerState<FileTab> {
  bool _downloading = false;
  bool _deleting = false;

  Document get doc => widget.doc;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final pages = ref.watch(extractionProvider(doc.id)).valueOrNull?.pages.length;
    final summary = doc.summary?.trim() ?? '';
    return FdGapColumn(gap: FdSpace.s4, children: [
      FdFields(rows: [
        FdFieldRow(label: 'Name', value: doc.displayFilename ?? doc.displayName),
        FdFieldRow(label: 'Type', value: doc.isPdf && (pages ?? 0) > 0 ? '${fileTypeLabel(doc)}, ${plural(pages!, 'page')}' : fileTypeLabel(doc)),
        if (doc.sizeBytes != null) FdFieldRow(label: 'Size', value: formatBytes(doc.sizeBytes!)),
        FdFieldRow(label: 'Uploaded', value: formatDate(doc.createdAt.toLocal())),
      ]),
      FdButton.secondary('Download a copy', block: true, loading: _downloading, onPressed: _downloading ? null : _download),
      if (summary.isNotEmpty) ...[
        const FdSectionTitle('Summary'),
        DocTextBox(summary),
      ],
      if (widget.isOwner)
        Center(
          child: FdButton.quiet('Delete document', icon: FdIcons.trash, foreground: c.danger, loading: _deleting, onPressed: _deleting ? null : _delete),
        ),
    ]);
  }

  Future<void> _download() async {
    setState(() => _downloading = true);
    try {
      final bytes = await ref.read(repositoryProvider).file(doc.id);
      final dir = await getApplicationDocumentsDirectory();
      final file = await _uniqueFile(dir, doc.displayFilename ?? 'document');
      await file.writeAsBytes(bytes, flush: true);
      if (mounted) FdToast.show(context, 'Saved a copy as ${file.uri.pathSegments.last}');
    } catch (e) {
      if (mounted) FdToast.error(context, e);
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  static Future<File> _uniqueFile(Directory dir, String filename) async {
    final safe = filename.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
    final dot = safe.lastIndexOf('.');
    final stem = dot > 0 ? safe.substring(0, dot) : safe;
    final ext = dot > 0 ? safe.substring(dot) : '';
    var candidate = File('${dir.path}/$safe');
    for (var i = 2; await candidate.exists(); i++) {
      candidate = File('${dir.path}/$stem ($i)$ext');
    }
    return candidate;
  }

  Future<void> _delete() async {
    final ok = await confirmFd(
      context,
      title: 'Delete this document?',
      body: 'The file, its details and deadlines will be removed, also for people you shared it with. This can’t be undone.',
      confirm: 'Delete',
    );
    if (!ok || !mounted) return;
    setState(() => _deleting = true);
    try {
      await ref.read(repositoryProvider).deleteDocument(doc.id);
      ref.read(documentsProvider.notifier).remove(doc.id);
      ref.invalidate(timelineProvider);
      if (!mounted) return;
      context.go(Routes.vault);
      FdToast.show(context, 'Deleted');
    } catch (e) {
      if (mounted) {
        setState(() => _deleting = false);
        FdToast.error(context, e);
      }
    }
  }
}

// ── Deadlines ───────────────────────────────────────────────────────────

class DeadlinesTab extends ConsumerStatefulWidget {
  const DeadlinesTab({super.key, required this.doc, required this.isOwner});
  final Document doc;
  final bool isOwner;

  @override
  ConsumerState<DeadlinesTab> createState() => _DeadlinesTabState();
}

class _DeadlinesTabState extends ConsumerState<DeadlinesTab> {
  bool _adding = false;

  Document get doc => widget.doc;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final async = ref.watch(documentDeadlinesProvider(doc.id));
    final done = ref.watch(doneDeadlinesProvider);
    final addButton = widget.isOwner
        ? Align(
            alignment: Alignment.centerLeft,
            child: FdButton.quiet('Add a deadline', icon: FdIcons.plus, loading: _adding, onPressed: _adding ? null : _add),
          )
        : null;
    return async.when(
      loading: () => const FdLoading(),
      error: (e, _) => FdErrorState(error: e, onRetry: () => ref.invalidate(documentDeadlinesProvider(doc.id))),
      data: (all) {
        final list = _sorted(all.where((d) => d.state != DeadlineState.rejected));
        return FdGapColumn(gap: FdSpace.s4, children: [
          if (list.isEmpty)
            Text('No deadlines yet. Add a date and we’ll remind you 7 and 1 day before.', style: FdType.callout.copyWith(color: c.inkSecondary))
          else
            FdList(children: [
              for (final d in list)
                DeadlineRow(
                  deadline: d,
                  done: done.contains(d.id),
                  onTap: d.state == DeadlineState.proposed && widget.isOwner ? () => context.push(Routes.confirmDeadline(doc.id)) : null,
                ),
            ]),
          ?addButton,
        ]);
      },
    );
  }

  Future<void> _add() async {
    final kind = kindForCategory(doc.category);
    final date = await pickDate(context, help: 'Deadline date');
    if (date == null || !mounted) return;
    final label = await showEditFieldDialog(
      context,
      label: 'What’s due',
      initial: kind == 'OTHER' ? null : deadlineKindTitle(kind),
      help: 'For example: Renew registration',
    );
    if (label == null || !mounted) return;
    setState(() => _adding = true);
    try {
      await ref.read(repositoryProvider).addDeadline(doc.id, kind: kind, date: date, label: label);
      ref.invalidate(documentDeadlinesProvider(doc.id));
      ref.invalidate(timelineProvider);
      if (mounted) FdToast.show(context, 'Saved. We’ll remind you before ${formatDateSmart(date)}.');
    } catch (e) {
      if (mounted) FdToast.error(context, e);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }
}

// ── Sharing ─────────────────────────────────────────────────────────────

class SharingTab extends ConsumerStatefulWidget {
  const SharingTab({super.key, required this.doc});
  final Document doc;

  @override
  ConsumerState<SharingTab> createState() => _SharingTabState();
}

class _SharingTabState extends ConsumerState<SharingTab> {
  bool _stopping = false;

  Document get doc => widget.doc;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final async = ref.watch(sharesProvider(doc.id));
    final family = ref.watch(familyProvider).valueOrNull;
    return async.when(
      loading: () => const FdLoading(),
      error: (e, _) => FdErrorState(error: e, onRetry: () => ref.invalidate(sharesProvider(doc.id))),
      data: (shares) {
        final shared = shares.isNotEmpty;
        return FdGapColumn(gap: FdSpace.s4, children: [
          FdCard.pad(
            child: Row(children: [
              FdWell(shared ? FdIcons.people : FdIcons.lock),
              const SizedBox(width: FdSpace.s3),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(shared ? 'Shared with your household · ${plural(shares.length, 'person', 'people')}' : 'Not shared',
                      style: FdType.listTitle),
                  Text(
                    shared
                        ? '${family?.name ?? 'Your household'} can view and download it. They can’t edit or reshare.'
                        : 'Only you can see this document.',
                    style: FdType.meta.copyWith(color: c.inkSecondary),
                  ),
                ]),
              ),
            ]),
          ),
          FdButton(shared ? 'Share settings' : 'Share', icon: FdIcons.link, block: true, onPressed: () async {
            await showShareSheet(context, doc);
            ref.invalidate(sharesProvider(doc.id));
          }),
          if (shared) FdButton.danger('Stop sharing', block: true, loading: _stopping, onPressed: _stopping ? null : _stop),
        ]);
      },
    );
  }

  Future<void> _stop() async {
    final ok = await confirmFd(
      context,
      title: 'Stop sharing?',
      body: 'People in your household won’t be able to open this document anymore. Copies they downloaded stay with them.',
      confirm: 'Stop sharing',
    );
    if (!ok || !mounted) return;
    setState(() => _stopping = true);
    try {
      await ref.read(repositoryProvider).stopSharing(doc.id);
      ref.invalidate(sharesProvider(doc.id));
      if (mounted) FdToast.show(context, 'Stopped sharing. Only you can see this document.');
    } catch (e) {
      if (mounted) FdToast.error(context, e);
    } finally {
      if (mounted) setState(() => _stopping = false);
    }
  }
}
