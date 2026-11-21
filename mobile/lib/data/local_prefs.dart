import 'package:shared_preferences/shared_preferences.dart';

/// Client-side state the backend doesn't model yet (see docs/api_contracts.md):
/// - "Mark as done" on deadlines (no DONE state on the backend)
/// - display names (User has only email)
/// - preferred reminder offsets (backend schedules 7 and 1 day)
class LocalPrefs {
  LocalPrefs(this._p);
  final SharedPreferences _p;

  static Future<LocalPrefs> load() async => LocalPrefs(await SharedPreferences.getInstance());

  Set<String> doneDeadlines(String userId) => (_p.getStringList('done.$userId') ?? const []).toSet();

  Future<void> setDoneDeadlines(String userId, Set<String> ids) => _p.setStringList('done.$userId', ids.toList());

  /// Display name by email (own name from Sign up; others are derived from email).
  String? displayName(String email) => _p.getString('name.${email.toLowerCase()}');

  Future<void> setDisplayName(String email, String name) => _p.setString('name.${email.toLowerCase()}', name.trim());

  List<int> reminderOffsets() =>
      (_p.getStringList('reminder_offsets') ?? const ['30', '7', '1']).map(int.parse).toList();

  Future<void> setReminderOffsets(List<int> v) => _p.setStringList('reminder_offsets', v.map((e) => '$e').toList());

  bool emailReminders() => _p.getBool('email_reminders') ?? true;
  Future<void> setEmailReminders(bool v) => _p.setBool('email_reminders', v);

  bool pushReminders() => _p.getBool('push_reminders') ?? false;
  Future<void> setPushReminders(bool v) => _p.setBool('push_reminders', v);
}
