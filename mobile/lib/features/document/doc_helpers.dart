import 'package:flutter/material.dart';

import '../../data/categories.dart';
import '../../data/models.dart';
import '../../ui/fd.dart';

// Shared pieces of the document flow (Review, Document, Confirm deadline).

/// One label/value row built from the summary card, extracted facts and overrides.
class DocField {
  const DocField({
    required this.key,
    required this.label,
    required this.value,
    this.raw,
    this.edited = false,
    this.identifier = false,
    this.isDate = false,
  });

  /// Override key used with PATCH /extraction (`fields: {key: value}`).
  final String key;
  final String label;

  /// Display value; null when the field is expected but missing ("Not specified").
  final String? value;

  /// Unformatted value (initial text in the edit dialog, full value for Copy).
  final String? raw;
  final bool edited;
  final bool identifier;
  final bool isDate;

  bool get missing => value == null;
}

/// Fields we expect per type; shown as "Not specified" when the document has none.
/// (key, label, isDate). Matching is by substring of the extracted fact name.
const _expected = <String, List<(String, String, bool)>>{
  'HOME_INSURANCE': [('deductible', 'Deductible', false)],
  'AUTO_INSURANCE': [('deductible', 'Deductible', false)],
  'HEALTH_INSURANCE': [('deductible', 'Deductible', false)],
  'LEASE': [('rent', 'Monthly rent', false)],
  'UTILITY_BILL': [('payment_due_on', 'Payment due', true), ('amount_due', 'Amount due', false)],
};

/// Types where an end date is expected (insurance, IDs, warranties, registrations, leases).
bool _expectsExpiry(String? category) {
  final g = groupOf(category);
  if (g == DocGroup.insurance || g == DocGroup.ids) return category?.toUpperCase() != 'BIRTH_CERTIFICATE';
  return const {'WARRANTY', 'VEHICLE_REGISTRATION', 'LEASE'}.contains(category?.toUpperCase());
}

final _isoDay = RegExp(r'^\d{4}-\d{2}-\d{2}$');

DateTime? parseIsoDay(String? v) {
  if (v == null || !_isoDay.hasMatch(v.trim())) return null;
  final d = DateTime.tryParse(v.trim());
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

String isoDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String? _nonEmpty(Object? v) {
  final s = v?.toString().trim();
  return s == null || s.isEmpty ? null : s;
}

String _periodLabel(String period) => switch (period.toLowerCase()) {
      'annual' || 'annually' || 'yearly' || 'year' || 'per year' => 'Annual',
      'monthly' || 'month' || 'per month' => 'Monthly',
      'weekly' || 'week' => 'Weekly',
      'quarterly' => 'Quarterly',
      _ => '',
    };

String _itemLabel(ExtractedFact f) {
  final name = f.name.toLowerCase();
  if (name == 'notice_period' || name == 'cancellation_notice') return 'Cancellation notice';
  final base = humanize(f.name);
  if (f.group == 'financials' && f.period != null) {
    final p = _periodLabel(f.period!);
    if (p.isNotEmpty && !base.toLowerCase().startsWith(p.toLowerCase())) return '$p ${base.toLowerCase()}';
  }
  return base;
}

String _formatItem(ExtractedFact f, String raw) {
  final day = parseIsoDay(raw);
  if (day != null) return formatDate(day);
  if (f.group == 'financials') {
    final n = num.tryParse(raw.replaceAll(RegExp(r'[,\s$€£]'), ''));
    if (n == null) return raw;
    final money = formatMoney(n, currency: f.currency);
    final p = f.period == null ? '' : _periodLabel(f.period!);
    // Unknown periods (e.g. "per visit") go after the amount.
    return f.period != null && p.isEmpty ? '$money ${f.period}' : money;
  }
  return raw;
}

String _issuerLabel(String? category) => switch (groupOf(category)) {
      DocGroup.insurance => 'Insurer',
      DocGroup.ids => 'Issued by',
      _ => 'Issuer',
    };

String _holderLabel(String? category) => switch (groupOf(category)) {
      DocGroup.insurance => 'Policyholder',
      DocGroup.ids => 'Name',
      _ => 'Holder',
    };

String _expiryLabel(String? category) => groupOf(category) == DocGroup.insurance ? 'Coverage' : 'Expires';

String _expiryValue(String? category, DateTime d) =>
    groupOf(category) == DocGroup.insurance ? 'Until ${formatDate(d)}' : formatDate(d);

/// Rows for Review and Details: card issuer/holder, identifiers, end date, terms,
/// financials, then expected-but-missing fields. Overrides win over extracted values.
List<DocField> buildFields(Document doc, Extraction? ext) {
  final out = <DocField>[];
  final overrides = ext?.overrides ?? const <String, dynamic>{};
  final items = ext?.items ?? const <ExtractedFact>[];
  final itemValues = items.map((i) => i.value.trim().toLowerCase()).toSet();

  void cardRow(String key, String label, String? v) {
    final ov = _nonEmpty(overrides[key]);
    final value = ov ?? _nonEmpty(v);
    if (value == null) return;
    if (ov == null && itemValues.contains(value.toLowerCase())) return; // already an extracted fact
    out.add(DocField(key: key, label: label, value: value, raw: value, edited: ov != null));
  }

  cardRow('issuer', _issuerLabel(doc.category), doc.card?.issuer);
  cardRow('holder', _holderLabel(doc.category), doc.card?.holder);

  DocField itemRow(ExtractedFact f) {
    final ov = _nonEmpty(overrides[f.name]);
    final raw = ov ?? f.value;
    return DocField(
      key: f.name,
      label: _itemLabel(f),
      value: raw.trim().isEmpty ? null : _formatItem(f, raw.trim()),
      raw: raw,
      edited: ov != null,
      identifier: f.group == 'identifiers',
      isDate: parseIsoDay(f.value) != null,
    );
  }

  out.addAll(items.where((i) => i.group == 'identifiers').map(itemRow));

  // Dates from facts.
  final facts = ext?.facts ?? const <String, dynamic>{};
  void dateRow(String key, String label, String Function(DateTime) fmt) {
    final ov = _nonEmpty(overrides[key]);
    final raw = ov ?? _nonEmpty(facts[key]);
    if (raw == null) return;
    final d = parseIsoDay(raw);
    out.add(DocField(key: key, label: label, value: d == null ? raw : fmt(d), raw: raw, edited: ov != null, isDate: true));
  }

  dateRow('expires_on', _expiryLabel(doc.category), (d) => _expiryValue(doc.category, d));
  dateRow('payment_due_on', 'Payment due', formatDate);

  out.addAll(items.where((i) => i.group == 'terms').map(itemRow));
  out.addAll(items.where((i) => i.group == 'financials').map(itemRow));

  // Expected but missing.
  bool present(String key) =>
      out.any((f) => f.key == key) ||
      _nonEmpty(overrides[key]) != null ||
      _nonEmpty(facts[key]) != null ||
      items.any((i) => i.name.toLowerCase().contains(key));

  if (ext != null) {
    if (_expectsExpiry(doc.category) && !present('expires_on')) {
      out.add(DocField(key: 'expires_on', label: _expiryLabel(doc.category), value: null, isDate: true));
    }
    for (final (key, label, isDate) in _expected[doc.category?.toUpperCase()] ?? const <(String, String, bool)>[]) {
      if (!present(key)) out.add(DocField(key: key, label: label, value: null, isDate: isDate));
    }
  }
  return out;
}

/// "PDF", "JPG", "PNG".
String fileTypeLabel(Document doc) {
  switch (doc.mediaType) {
    case 'application/pdf':
      return 'PDF';
    case 'image/jpeg':
      return 'JPG';
    case 'image/png':
      return 'PNG';
  }
  final name = doc.displayFilename ?? '';
  final dot = name.lastIndexOf('.');
  if (dot > 0 && dot < name.length - 1) return name.substring(dot + 1).toUpperCase();
  return 'File';
}

/// "PDF, 3 pages" when pages are known, otherwise "PDF · 184 KB".
String fileMeta(Document doc, {int? pages}) {
  final type = fileTypeLabel(doc);
  if (pages != null && pages > 0 && doc.isPdf) return '$type, ${plural(pages, 'page')}';
  if (doc.sizeBytes != null) return '$type · ${formatBytes(doc.sizeBytes!)}';
  return type;
}

/// Lowercase the first letter unless it starts an acronym ("ID card").
String lowerFirst(String s) {
  if (s.length < 2) return s.toLowerCase();
  if (s[1].toUpperCase() == s[1] && s[1].toLowerCase() != s[1]) return s;
  return s[0].toLowerCase() + s.substring(1);
}

// ── Deadlines ─────────────────────────────────────────────────────────────

String deadlineTitle(Deadline d) =>
    (d.label?.trim().isNotEmpty ?? false) ? d.label!.trim() : deadlineKindTitle(d.kind);

/// "Cancel or renew by Jan 1, 2027", "Policy ends Jan 31, 2027". [short] uses Dec 1 in the current year.
String deadlineHeadline(String kind, DateTime date, {String? label, bool short = false}) {
  final ds = short ? formatDateSmart(date) : formatDate(date);
  return switch (kind) {
    'CANCELLATION' => 'Cancel or renew by $ds',
    'INSURANCE_EXPIRATION' => 'Policy ends $ds',
    'CONTRACT_EXPIRATION' => 'Contract ends $ds',
    'WARRANTY_EXPIRATION' => 'Warranty ends $ds',
    'PAYMENT_DUE' => 'Pay by $ds',
    'DOCUMENT_EXPIRATION' => 'Expires $ds',
    _ => (label?.trim().isNotEmpty ?? false) ? '${label!.trim()}, $ds' : 'Due $ds',
  };
}

/// Deadline kind that fits a document type, for dates added by hand.
String kindForCategory(String? category) {
  final c = category?.toUpperCase();
  switch (groupOf(c)) {
    case DocGroup.insurance:
      return 'INSURANCE_EXPIRATION';
    case DocGroup.ids:
    case DocGroup.vehicle:
      return 'DOCUMENT_EXPIRATION';
    case DocGroup.warranties:
      return c == 'WARRANTY' ? 'WARRANTY_EXPIRATION' : 'OTHER';
    case DocGroup.home:
      return c == 'UTILITY_BILL' ? 'PAYMENT_DUE' : 'CONTRACT_EXPIRATION';
    case DocGroup.other:
      return 'OTHER';
  }
}

FdIcons deadlineIcon(String kind) => kind == 'INSURANCE_EXPIRATION' ? FdIcons.umbrella : FdIcons.calendar;

/// Badge for the header: overdue / soon / upcoming, with the headline as text.
Widget deadlineBadge(Deadline d) {
  final n = daysUntil(d.dueOn!);
  final text = deadlineHeadline(d.kind, d.dueOn!, label: d.label, short: true);
  if (n < 0) return FdBadge(text, kind: FdBadgeKind.overdue, icon: FdIcons.xCircle);
  if (n <= 30) return FdBadge(text, kind: FdBadgeKind.soon, icon: FdIcons.alert);
  return FdBadge(text, kind: FdBadgeKind.upcoming, icon: FdIcons.clock);
}

/// Notice period in days from the extracted terms ("thirty (30) days" → 30), or null.
({int days, ExtractedFact fact})? noticePeriod(Extraction? ext) {
  if (ext == null) return null;
  for (final f in ext.items) {
    if (!f.name.toLowerCase().contains('notice')) continue;
    final raw = _nonEmpty(ext.overrides[f.name]) ?? f.value;
    final n = parseDays(raw);
    if (n != null && n > 0) return (days: n, fact: f);
  }
  return null;
}

const _words = {
  'seven': 7, 'ten': 10, 'fourteen': 14, 'fifteen': 15, 'twenty': 20, 'thirty': 30,
  'forty-five': 45, 'forty five': 45, 'sixty': 60, 'ninety': 90,
};

int? parseDays(String text) {
  final t = text.toLowerCase();
  final weeks = RegExp(r'\(?(\d+)\)?\s*weeks?').firstMatch(t);
  final days = RegExp(r'\(?(\d+)\)?\s*(calendar\s+|business\s+)?days?').firstMatch(t);
  if (days != null) return int.parse(days.group(1)!);
  if (weeks != null) return int.parse(weeks.group(1)!) * 7;
  for (final e in _words.entries) {
    if (RegExp('\\b${e.key}\\s+(calendar\\s+)?days?').hasMatch(t)) return e.value;
  }
  return null;
}

final _dateInQuote = RegExp(
  r'(\b\d{1,2}/\d{1,2}/\d{2,4}\b)|'
  r'(\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2},?\s+\d{4})|'
  r'(\b\d{1,2}\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{4})|'
  r'(\b\d{4}-\d{2}-\d{2}\b)',
  caseSensitive: false,
);

/// The last date-looking part of a quote (end dates come last in "02/01/2026 to 01/31/2027").
String? dateHighlight(String? quote) {
  if (quote == null) return null;
  final all = _dateInQuote.allMatches(quote).toList();
  return all.isEmpty ? null : all.last.group(0);
}

/// "at least thirty (30) days before" inside a notice clause.
String? noticeHighlight(String? quote) {
  if (quote == null) return null;
  final m = RegExp(r'(at least\s+)?([a-z\-]+\s+)?\(?\d+\)?\s+(calendar\s+|business\s+)?days?(\s+before)?', caseSensitive: false)
      .firstMatch(quote);
  return m?.group(0);
}

// ── Dialogs ───────────────────────────────────────────────────────────────

DateTime _clampDay(DateTime d, DateTime first, DateTime last) => d.isBefore(first) ? first : (d.isAfter(last) ? last : d);

/// Themed date picker (the app theme styles it).
Future<DateTime?> pickDate(BuildContext context, {DateTime? initial, String? help}) {
  final t = today();
  final first = DateTime(t.year - 30);
  final last = DateTime(t.year + 50);
  return showDatePicker(
    context: context,
    initialDate: _clampDay(initial ?? t, first, last),
    firstDate: first,
    lastDate: last,
    helpText: help,
  );
}

/// Edit one detail. Returns the trimmed text, or null when cancelled.
Future<String?> showEditFieldDialog(BuildContext context, {required String label, String? initial, String? help}) =>
    showDialog<String>(context: context, builder: (_) => _EditFieldDialog(label: label, initial: initial, help: help));

class _EditFieldDialog extends StatefulWidget {
  const _EditFieldDialog({required this.label, this.initial, this.help});
  final String label;
  final String? initial;
  final String? help;

  @override
  State<_EditFieldDialog> createState() => _EditFieldDialogState();
}

class _EditFieldDialogState extends State<_EditFieldDialog> {
  late final _c = TextEditingController(text: widget.initial ?? '');

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _save() {
    final v = _c.text.trim();
    if (v.isEmpty) return;
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.label),
      content: FdTextField(
        label: widget.label,
        controller: _c,
        autofocus: true,
        help: widget.help,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(FdSpace.s4, 0, FdSpace.s4, FdSpace.s4),
      actions: [
        FdButton.quiet('Cancel', onPressed: () => Navigator.of(context).pop()),
        FdButton('Save', onPressed: _save),
      ],
    );
  }
}

/// .fd-doc — plain text box (surface, line border, 13/22).
class DocTextBox extends StatelessWidget {
  const DocTextBox(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Container(
      padding: const EdgeInsets.all(FdSpace.s4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(FdRadius.md),
        border: Border.all(color: c.line),
      ),
      child: Text(text, style: FdType.body.copyWith(fontSize: 13, height: 22 / 13, color: c.ink)),
    );
  }
}

/// Page header: meta line, title, optional badge row (8 px below).
class DocHeader extends StatelessWidget {
  const DocHeader({super.key, required this.meta, required this.title, this.badges = const []});
  final String meta;
  final String title;
  final List<Widget> badges;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(meta, style: FdType.meta.copyWith(color: c.inkSecondary)),
      Semantics(header: true, child: Text(title, style: FdType.title)),
      if (badges.isNotEmpty) ...[
        const SizedBox(height: FdSpace.s2),
        FdRowWrap(children: badges),
      ],
    ]);
  }
}
