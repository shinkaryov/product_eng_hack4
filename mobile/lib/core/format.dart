import 'package:intl/intl.dart';

/// US formats only (market: United States). Never ISO dates in the UI.
final _date = DateFormat('MMM d, y', 'en_US');
final _dateShort = DateFormat('MMM d', 'en_US');
final _month = DateFormat('MMM', 'en_US');
final _weekday = DateFormat('EEEE', 'en_US');
final _time = DateFormat('h:mm a', 'en_US');

DateTime today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Mar 12, 2027
String formatDate(DateTime d) => _date.format(d);

/// Dec 1 when in the current year, otherwise Dec 1, 2027.
String formatDateSmart(DateTime d, {DateTime? now}) =>
    d.year == (now ?? DateTime.now()).year ? _dateShort.format(d) : _date.format(d);

/// Dec
String formatMonth(DateTime d) => _month.format(d);

/// Friday
String formatWeekday(DateTime d) => _weekday.format(d);

/// 1:40 PM
String formatTime(DateTime d) => _time.format(d.toLocal());

/// $1,240.00. Takes "1,240.00" or 1240 and an ISO currency code.
String formatMoney(Object amount, {String? currency}) {
  final n = amount is num ? amount : num.tryParse(amount.toString().replaceAll(',', ''));
  if (n == null) return '$amount${currency == null ? '' : ' $currency'}';
  final symbol = switch (currency?.toUpperCase()) {
    null || 'USD' => r'$',
    'EUR' => '€',
    'GBP' => '£',
    final other => '$other ',
  };
  return NumberFormat.currency(locale: 'en_US', symbol: symbol).format(n);
}

int daysUntil(DateTime due, [DateTime? now]) =>
    dateOnly(due).difference(dateOnly(now ?? DateTime.now())).inDays;

/// "10 days", "1 day", "Today", "Tomorrow".
String daysLabel(int n) {
  if (n == 0) return 'Today';
  if (n == 1) return 'Tomorrow';
  if (n == -1) return '1 day ago';
  if (n < 0) return '${-n} days ago';
  return '$n days';
}

/// "in 41 days" / "today" / "tomorrow" / "3 days ago"
String inDays(int n) {
  if (n == 0) return 'today';
  if (n == 1) return 'tomorrow';
  if (n == -1) return 'yesterday';
  if (n < 0) return '${-n} days ago';
  return 'in $n days';
}

/// "Uploaded 2 min ago", "Uploaded just now", "Uploaded Nov 20".
String uploadedAgo(DateTime at, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final d = n.difference(at.toLocal());
  if (d.inMinutes < 1) return 'Uploaded just now';
  if (d.inMinutes < 60) return 'Uploaded ${d.inMinutes} min ago';
  if (d.inHours < 24 && dateOnly(n) == dateOnly(at.toLocal())) return 'Uploaded ${d.inHours} h ago';
  return 'Uploaded ${formatDateSmart(at.toLocal(), now: n)}';
}

/// 1.4 MB · 184 KB
String formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
  return '$bytes B';
}

/// •••• 1190
String maskNumber(String value) {
  final digits = value.replaceAll(RegExp(r'[\s-]'), '');
  return digits.length <= 4 ? value : '•••• ${digits.substring(digits.length - 4)}';
}

/// "laura.reynolds@x.com" → "Laura Reynolds"; "Laura Reynolds" → "LR".
String nameFromEmail(String email) {
  final local = email.split('@').first;
  final parts = local.split(RegExp(r'[._\-+]+')).where((p) => p.isNotEmpty);
  return parts.map((p) => p[0].toUpperCase() + p.substring(1)).join(' ');
}

String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, parts.first.length.clamp(1, 2)).toUpperCase();
  return (parts.first[0] + parts.last[0]).toUpperCase();
}

/// "A, B and C"
String joinAnd(List<String> items) {
  if (items.isEmpty) return '';
  if (items.length == 1) return items.first;
  return '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';
}

String plural(int n, String one, [String? many]) => n == 1 ? '$n $one' : '$n ${many ?? '${one}s'}';

/// "policy_number" → "Policy number"
String humanize(String key) {
  final s = key.replaceAll('_', ' ').trim();
  if (s.isEmpty) return s;
  return s[0].toUpperCase() + s.substring(1).toLowerCase();
}
