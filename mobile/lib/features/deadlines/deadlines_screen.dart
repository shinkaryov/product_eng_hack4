import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../data/categories.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../ui/fd.dart';

/// Rows within this many days go to "Next 30 days".
const _soonDays = 30;

/// Deadlines tab: confirmed deadlines grouped Overdue / Next 30 days / Later / Done.
class DeadlinesScreen extends ConsumerWidget {
  const DeadlinesScreen({super.key});

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(documentsProvider);
    ref.invalidate(timelineProvider);
    try {
      await ref.read(timelineProvider.future);
    } catch (_) {
      // The error state below shows it.
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timelineAsync = ref.watch(timelineProvider);
    final done = ref.watch(doneDeadlinesProvider);
    final children = <Widget>[const _TopBar()];

    final timeline = timelineAsync.valueOrNull;
    if (timeline == null) {
      if (timelineAsync.hasError) {
        children.add(FdErrorState(error: timelineAsync.error!, onRetry: () => ref.invalidate(timelineProvider)));
      } else {
        children.add(const FdLoading());
      }
    } else {
      final all = timeline.where((d) => d.state == DeadlineState.confirmed && d.dueOn != null).toList()
        ..sort((a, b) => a.dueOn!.compareTo(b.dueOn!));
      final overdue = <Deadline>[], soon = <Deadline>[], later = <Deadline>[], finished = <Deadline>[];
      for (final d in all) {
        final n = daysUntil(d.dueOn!);
        if (done.contains(d.id)) {
          finished.add(d);
        } else if (n < 0) {
          overdue.add(d);
        } else if (n <= _soonDays) {
          soon.add(d);
        } else {
          later.add(d);
        }
      }

      if (all.isEmpty) {
        children.add(const _Empty());
      } else {
        void open(Deadline d) => _openDocument(context, ref, d.documentId);
        void markDone(Deadline d) {
          ref.read(doneDeadlinesProvider.notifier).markDone(d.id);
          FdToast.show(
            context,
            'Marked as done. Reminders stopped.',
            actionLabel: 'Undo',
            onAction: () => ref.read(doneDeadlinesProvider.notifier).undo(d.id),
          );
        }

        void section(String title, List<Deadline> items, Widget Function(Deadline) row) {
          if (items.isEmpty) return;
          children
            ..add(FdSectionTitle(title, topGap: FdSpace.s2))
            ..add(FdList(children: [for (final d in items) row(d)]));
        }

        Widget openRow(Deadline d) => _DeadlineRow(deadline: d, onTap: () => open(d), onDone: () => markDone(d));
        Widget laterRow(Deadline d) => _DeadlineRow(deadline: d, onTap: () => open(d));

        section('Overdue', overdue, openRow);
        section('Next 30 days', soon, openRow);
        section('Later', later, laterRow);
        section('Done', finished, (d) => _DoneRow(deadline: d, onTap: () => open(d)));
      }
    }

    return FdPage(
      withNav: true,
      topPadding: FdSpace.s3,
      onRefresh: () => _refresh(ref),
      children: children,
    );
  }

  static void _openDocument(BuildContext context, WidgetRef ref, String id) {
    final docs = ref.read(documentsProvider).valueOrNull ?? const <Document>[];
    for (final d in docs) {
      if (d.id == id) return openDocument(context, d);
    }
    context.go(Routes.document(id));
  }
}

/// "Renters insurance: policy ends" when there's no label of its own.
String _titleOf(Deadline d) {
  final label = d.label?.trim();
  if (label != null && label.isNotEmpty) return label;
  final kind = deadlineKindTitle(d.kind);
  final doc = d.documentTitle?.trim();
  if (doc == null || doc.isEmpty) return kind;
  return '$doc: ${kind[0].toLowerCase()}${kind.substring(1)}';
}

/// Meta: the document (or the full date when the title already names it) · how far away.
String _metaOf(Deadline d) {
  final n = daysUntil(d.dueOn!);
  final when = n < 0
      ? (n == -1 ? '1 day overdue' : '${-n} days overdue')
      : n == 0
          ? 'Today'
          : n == 1
              ? 'Tomorrow'
              : n <= _soonDays
                  ? '$n days left'
                  : '$n days';
  final hasLabel = d.label?.trim().isNotEmpty ?? false;
  final doc = d.documentTitle?.trim();
  final lead = hasLabel && doc != null && doc.isNotEmpty ? doc : formatDate(d.dueOn!);
  return '$lead · $when';
}

class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: FdSize.tapMin),
      child: Row(children: [
        Expanded(child: Semantics(header: true, child: Text('Deadlines', style: FdType.title))),
        const SizedBox(width: FdSpace.s3),
        FdButton.quiet('Reminders', icon: FdIcons.bell, onPressed: () => context.push(Routes.settings)),
      ]),
    );
  }
}

class _DeadlineRow extends StatelessWidget {
  const _DeadlineRow({required this.deadline, required this.onTap, this.onDone});
  final Deadline deadline;
  final VoidCallback onTap;
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    final due = deadline.dueOn!;
    return FdListRow(
      title: _titleOf(deadline),
      meta: _metaOf(deadline),
      leading: FdDateTile.forDays(due, daysUntil(due)),
      trailing: onDone == null ? null : FdIconButton(FdIcons.check, bordered: true, semanticLabel: 'Mark as done', onPressed: onDone),
      onTap: onTap,
    );
  }
}

class _DoneRow extends StatelessWidget {
  const _DoneRow({required this.deadline, required this.onTap});
  final Deadline deadline;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return FdListRow(
      title: _titleOf(deadline),
      titleColor: c.inkSecondary,
      meta: 'Done · reminders stopped',
      leading: FdWell(FdIcons.check, background: c.successSoft, foreground: c.success),
      onTap: onTap,
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: FdSpace.s10),
      child: FdGapColumn(
        gap: FdSpace.s3,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const FdWell(FdIcons.calendar, size: 56, radius: FdRadius.lg, iconSize: 24),
          Semantics(header: true, child: Text('No deadlines yet', textAlign: TextAlign.center, style: FdType.section)),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Text(
              'When you confirm a date in one of your documents, like a policy end or a notice deadline, it shows up here with reminders.',
              textAlign: TextAlign.center,
              style: FdType.callout.copyWith(color: context.fd.inkSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
