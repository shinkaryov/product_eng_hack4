import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../data/categories.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../ui/fd.dart';
import 'doc_helpers.dart';

/// Confirm deadline (design Deadline.dc.html). Walks through the document's
/// PROPOSED deadlines one by one; derives a cancellation date from a notice period.
class DeadlineConfirmScreen extends ConsumerStatefulWidget {
  const DeadlineConfirmScreen({super.key, required this.documentId});
  final String documentId;

  @override
  ConsumerState<DeadlineConfirmScreen> createState() => _DeadlineConfirmScreenState();
}

class _DeadlineConfirmScreenState extends ConsumerState<DeadlineConfirmScreen> {
  List<Deadline>? _all;
  Object? _error;
  int _total = 0;
  bool _busy = false;
  DateTime? _firstSaved;
  bool _leaving = false;
  late final Set<int> _offsets = ref.read(localPrefsProvider).reminderOffsets().toSet();

  String get id => widget.documentId;

  List<Deadline> get _proposed => (_all ?? const []).where((d) => d.state == DeadlineState.proposed).toList();

  @override
  void initState() {
    super.initState();
    _load(initial: true);
  }

  Future<void> _load({bool initial = false}) async {
    setState(() => _error = null);
    try {
      final all = await ref.read(repositoryProvider).documentDeadlines(id);
      if (!mounted) return;
      setState(() {
        _all = all;
        if (initial) _total = _proposed.length;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null && _all == null) {
      return _page(children: [FdErrorState(error: _error!, onRetry: () => _load(initial: true))]);
    }
    final docAsync = ref.watch(documentProvider(id));
    final extAsync = ref.watch(extractionProvider(id));
    if (_leaving || _all == null || docAsync.isLoading && !docAsync.hasValue) return _page(children: const [FdLoading()]);
    if (docAsync.hasError && !docAsync.hasValue) {
      return _page(children: [FdErrorState(error: docAsync.error!, onRetry: () => ref.invalidate(documentProvider(id)))]);
    }
    final doc = docAsync.requireValue;
    final proposed = _proposed;
    if (proposed.isEmpty) return _empty(doc);
    // Wait for the extraction (notice period); continue without it if it fails.
    if (extAsync.isLoading && !extAsync.hasValue) return _page(children: const [FdLoading()]);
    return _confirm(doc, proposed.first, extAsync.valueOrNull);
  }

  Widget _page({required List<Widget> children, Widget? footer}) => FdPage(
        appBar: FdAppBar(title: 'Confirm deadline', onBack: () => context.canPop() ? context.pop() : context.go(Routes.document(id))),
        footer: footer,
        children: children,
      );

  // ── One proposed deadline ──────────────────────────────────────────────

  bool _derivable(Deadline d) =>
      d.dueOn != null && (d.kind == 'INSURANCE_EXPIRATION' || d.kind == 'CONTRACT_EXPIRATION');

  Widget _confirm(Document doc, Deadline d, Extraction? ext) {
    final c = context.fd;
    final notice = _derivable(d) ? noticePeriod(ext) : null;
    final derived = notice == null ? null : d.dueOn!.subtract(Duration(days: notice.days));
    final result = derived ?? d.dueOn;
    final position = _total - _proposed.length + 1;

    final quote = d.evidenceQuote ?? (d.candidateKey == 'expires_on' ? ext?.expiresQuote : null);
    final String title;
    final String callout;
    if (result == null) {
      title = 'Add the date';
      callout = 'We found a ${lowerFirst(deadlineTitle(d))} in your document but not the date. Pick it so we can remind you.';
    } else if (derived != null) {
      title = deadlineHeadline('CANCELLATION', derived);
      callout = 'Your document asks for notice before it ends. Here’s how we worked out the last day to change it.';
    } else {
      title = deadlineHeadline(d.kind, result, label: d.label);
      callout = 'We found this date in your document. Check it before we remind you.';
    }

    final resultLabel = derived != null ? 'Last day to cancel or renew' : deadlineTitle(d);

    return _page(
      footer: FdFooter(children: [
        FdButton('Confirm deadline', block: true, loading: _busy, onPressed: _busy ? null : () => result == null ? _changeDate(d, derived) : _accept(d, derived)),
        Row(children: [
          Expanded(child: FdButton.quiet('Change date', onPressed: _busy ? null : () => _changeDate(d, derived))),
          Expanded(child: FdButton.quiet('Not a deadline', foreground: c.inkSecondary, onPressed: _busy ? null : () => _reject(d))),
        ]),
      ]),
      children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_total > 1) Text('$position of $_total', style: FdType.meta.copyWith(color: c.inkSecondary)),
          Semantics(header: true, child: Text(title, style: FdType.title)),
          const SizedBox(height: FdSpace.s2),
          Text(callout, style: FdType.callout.copyWith(color: c.inkSecondary)),
        ]),
        FdCard.pad(
          child: Column(children: [
            FdStep(
              marker: '1',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('What the document says', style: FdType.bodyStrong),
                Text(doc.displayName, style: FdType.meta.copyWith(color: c.inkSecondary)),
                if (quote != null) FdQuote(text: quote, highlight: dateHighlight(quote)),
                if (notice?.fact.quote != null) FdQuote(text: notice!.fact.quote!, highlight: noticeHighlight(notice.fact.quote)),
                if (quote == null && notice?.fact.quote == null)
                  Padding(
                    padding: const EdgeInsets.only(top: FdSpace.s2),
                    child: Text('We didn’t keep the exact wording for this date.', style: FdType.callout.copyWith(color: c.inkSecondary)),
                  ),
              ]),
            ),
            FdStep(
              marker: '2',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Calculation', style: FdType.bodyStrong),
                const SizedBox(height: FdSpace.s2),
                if (derived != null) ...[
                  Text('${deadlineKindTitle(d.kind)} ${formatDate(d.dueOn!)}, minus ${plural(notice!.days, 'day')}', style: FdType.calc),
                  Text('Worked out from the notice period', style: FdType.meta.copyWith(color: c.inkSecondary)),
                ] else
                  Text(result == null ? 'No date found in the document' : 'Taken directly from the document', style: FdType.calc),
              ]),
            ),
            FdStep(
              marker: '3',
              result: true,
              last: true,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(resultLabel, style: FdType.bodyStrong),
                if (result != null) ...[
                  Text(formatDate(result), style: FdType.figure),
                  Text('${formatWeekday(result)}, ${inDays(daysUntil(result))}', style: FdType.meta.copyWith(color: c.inkSecondary)),
                ] else
                  Text('Not specified', style: FdType.body.copyWith(color: c.inkTertiary, fontStyle: FontStyle.italic)),
              ]),
            ),
          ]),
        ),
        _remindMe(),
      ],
    );
  }

  Widget _remindMe() {
    final c = context.fd;
    Widget chip(int n) => FdChip(
          '${plural(n, 'day')} before',
          selected: _offsets.contains(n),
          onTap: () {
            setState(() => _offsets.contains(n) ? _offsets.remove(n) : _offsets.add(n));
            final list = _offsets.toList()..sort((a, b) => b.compareTo(a));
            ref.read(localPrefsProvider).setReminderOffsets(list);
          },
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Remind me', style: FdType.fieldLabel.copyWith(color: c.ink)),
      const SizedBox(height: FdSpace.s1),
      FdRowWrap(gap: FdSpace.s2, children: [chip(30), chip(7), chip(1)]),
      const SizedBox(height: FdSpace.s1),
      Text('Only you get reminders. People you share with can see the date.', style: FdType.meta.copyWith(color: c.inkSecondary)),
      Text('The server currently sends reminders 7 and 1 day before.', style: FdType.meta.copyWith(color: c.inkSecondary)),
    ]);
  }

  // ── Actions ────────────────────────────────────────────────────────────

  bool _hasConfirmed(String kind, DateTime date) => (_all ?? const []).any(
      (x) => x.state == DeadlineState.confirmed && x.kind == kind && x.dueOn != null && dateOnly(x.dueOn!) == dateOnly(date));

  void _noteSaved(DateTime d) {
    if (_firstSaved == null || d.isBefore(_firstSaved!)) _firstSaved = d;
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _next();
    } catch (e) {
      if (mounted) FdToast.error(context, e);
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Confirm as shown. With a derived date: add the cancellation deadline and confirm the proposed one too.
  Future<void> _accept(Deadline d, DateTime? derived) => _run(() async {
        final repo = ref.read(repositoryProvider);
        if (derived != null) {
          if (!_hasConfirmed('CANCELLATION', derived)) {
            await repo.addDeadline(id, kind: 'CANCELLATION', date: derived, label: 'Last day to cancel or renew');
          }
          _noteSaved(derived);
        }
        await repo.updateDeadline(id, d.id, state: 'CONFIRMED');
        _noteSaved(d.dueOn!);
      });

  Future<void> _changeDate(Deadline d, DateTime? derivedDate) async {
    final derived = derivedDate != null;
    final picked = await pickDate(context, initial: derivedDate ?? d.dueOn, help: derived ? 'Last day to cancel or renew' : deadlineTitle(d));
    if (picked == null || !mounted) return;
    await _run(() async {
      final repo = ref.read(repositoryProvider);
      if (derived) {
        // The picked date replaces the worked-out cancellation date; the end date stays as found.
        if (!_hasConfirmed('CANCELLATION', picked)) {
          await repo.addDeadline(id, kind: 'CANCELLATION', date: picked, label: 'Last day to cancel or renew');
        }
        await repo.updateDeadline(id, d.id, state: 'CONFIRMED');
      } else {
        await repo.updateDeadline(id, d.id, date: picked, state: 'CONFIRMED');
      }
      _noteSaved(picked);
    });
  }

  Future<void> _reject(Deadline d) => _run(() => ref.read(repositoryProvider).updateDeadline(id, d.id, state: 'REJECTED'));

  /// Reload; when nothing is left, leave for the document.
  Future<void> _next() async {
    final all = await ref.read(repositoryProvider).documentDeadlines(id);
    if (!mounted) return;
    setState(() => _all = all);
    if (_proposed.isEmpty) _finish();
  }

  void _finish() {
    setState(() => _leaving = true);
    ref.invalidate(documentDeadlinesProvider(id));
    ref.invalidate(timelineProvider);
    context.go(Routes.document(id));
    final d = _firstSaved;
    FdToast.show(context, d == null ? 'Saved' : 'Saved. We’ll remind you before ${formatDateSmart(d)}.');
  }

  // ── Nothing proposed ───────────────────────────────────────────────────

  Widget _empty(Document doc) {
    final c = context.fd;
    final kind = kindForCategory(doc.category);
    return _page(
      footer: FdFooter(children: [
        FdButton('Add a date', block: true, icon: FdIcons.calendar, loading: _busy, onPressed: _busy ? null : () => _addDate(kind)),
        FdButton.quiet('Skip', onPressed: _busy ? null : () => context.go(Routes.document(id))),
      ]),
      children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Semantics(header: true, child: Text('No dates to confirm', style: FdType.title)),
          const SizedBox(height: FdSpace.s2),
          Text(
            'We didn’t find a date to remind you about in ${doc.displayName}. If it has one, add it and we’ll remind you before it.',
            style: FdType.callout.copyWith(color: c.inkSecondary),
          ),
        ]),
      ],
    );
  }

  Future<void> _addDate(String kind) async {
    final picked = await pickDate(context, help: deadlineKindTitle(kind));
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(repositoryProvider).addDeadline(id, kind: kind, date: picked, label: kind == 'OTHER' ? 'Deadline' : null);
      _noteSaved(picked);
      if (mounted) _finish();
    } catch (e) {
      if (mounted) FdToast.error(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
