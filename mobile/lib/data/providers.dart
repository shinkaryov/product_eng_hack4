import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import 'api_client.dart';
import 'local_prefs.dart';
import 'models.dart';
import 'repository.dart';

// ── Infrastructure ────────────────────────────────────────────────────────

/// Overridden in main() after SharedPreferences loads.
final localPrefsProvider = Provider<LocalPrefs>((ref) => throw UnimplementedError('override in main'));

final tokenStoreProvider = Provider<TokenStore>((ref) => TokenStore());

final apiClientProvider = Provider<ApiClient>((ref) {
  final api = ApiClient(tokens: ref.watch(tokenStoreProvider));
  api.onSessionExpired = () => ref.read(sessionProvider.notifier).expired();
  return api;
});

final repositoryProvider = Provider<VaultRepository>((ref) => VaultRepository(ref.watch(apiClientProvider)));

// ── Session ───────────────────────────────────────────────────────────────

sealed class SessionState {
  const SessionState();
}

class SessionLoading extends SessionState {
  const SessionLoading();
}

class SignedOut extends SessionState {
  const SignedOut({this.expired = false});
  final bool expired;
}

class SignedIn extends SessionState {
  const SignedIn(this.user, this.displayName);
  final User user;
  final String displayName;
  String get initials => initialsOf(displayName);
}

String initialsOf(String name) => initials(name);

class SessionNotifier extends Notifier<SessionState> {
  @override
  SessionState build() {
    Future.microtask(_restore);
    return const SessionLoading();
  }

  VaultRepository get _repo => ref.read(repositoryProvider);
  LocalPrefs get _prefs => ref.read(localPrefsProvider);

  SignedIn _signedIn(User u) => SignedIn(u, _prefs.displayName(u.email) ?? nameFromEmail(u.email));

  Future<void> _restore() async {
    final api = ref.read(apiClientProvider);
    if (await api.tokens.readRefresh() == null) {
      state = const SignedOut();
      return;
    }
    try {
      await api.refresh();
      state = _signedIn(await _repo.me());
    } on ApiException catch (e) {
      // Offline at launch: keep the token, show Sign in with the error on retry.
      state = SignedOut(expired: e.isUnauthorized);
    }
  }

  /// Throws [ApiException] (401 = wrong email or password).
  Future<void> signIn(String email, String password) async {
    final pair = await _repo.login(email.trim(), password);
    await ref.read(tokenStoreProvider).save(pair);
    state = _signedIn(await _repo.me());
  }

  /// Register then log in. Name is kept on the device (no display_name on the backend yet).
  Future<void> signUp({required String name, required String email, required String password}) async {
    final tz = DateTime.now().timeZoneName;
    try {
      await _repo.register(email.trim(), password, timezone: _ianaGuess(tz));
    } on ApiException catch (e) {
      // Unknown timezone → retry with backend default (UTC).
      if (e.status == 422 && e.detail.toLowerCase().contains('timezone')) {
        await _repo.register(email.trim(), password);
      } else {
        rethrow;
      }
    }
    if (name.trim().isNotEmpty) await _prefs.setDisplayName(email.trim(), name);
    await signIn(email, password);
  }

  Future<void> setDisplayName(String name) async {
    final s = state;
    if (s is! SignedIn) return;
    await _prefs.setDisplayName(s.user.email, name);
    state = _signedIn(s.user);
  }

  Future<void> signOut() async {
    try {
      await _repo.logout();
    } catch (_) {}
    await ref.read(tokenStoreProvider).clear();
    ref.invalidate(documentsProvider);
    ref.invalidate(timelineProvider);
    ref.invalidate(familyProvider);
    state = const SignedOut();
  }

  void expired() {
    if (state is SignedIn) state = const SignedOut(expired: true);
  }

  static String? _ianaGuess(String abbr) => switch (abbr) {
        'EET' || 'EEST' => 'Europe/Kyiv',
        'CET' || 'CEST' => 'Europe/Berlin',
        'GMT' || 'BST' => 'Europe/London',
        'EST' || 'EDT' => 'America/New_York',
        'CST' || 'CDT' => 'America/Chicago',
        'MST' || 'MDT' => 'America/Denver',
        'PST' || 'PDT' => 'America/Los_Angeles',
        _ => null,
      };
}

final sessionProvider = NotifierProvider<SessionNotifier, SessionState>(SessionNotifier.new);

/// The signed-in user; only read under the signed-in shell.
final currentUserProvider = Provider<SignedIn>((ref) {
  final s = ref.watch(sessionProvider);
  if (s is SignedIn) return s;
  throw StateError('Not signed in');
});

// ── Documents ─────────────────────────────────────────────────────────────

class DocumentsNotifier extends AsyncNotifier<List<Document>> {
  Timer? _poll;

  @override
  Future<List<Document>> build() async {
    ref.onDispose(() => _poll?.cancel());
    final docs = await ref.read(repositoryProvider).documents();
    _schedulePoll(docs);
    return docs;
  }

  /// While anything is with the worker, refresh every 2 s.
  void _schedulePoll(List<Document> docs) {
    _poll?.cancel();
    if (docs.any((d) => d.isWorking)) {
      _poll = Timer(const Duration(seconds: 2), () async {
        try {
          final fresh = await ref.read(repositoryProvider).documents();
          state = AsyncData(fresh);
          _schedulePoll(fresh);
          // Documents that just finished may have proposed deadlines.
          ref.invalidate(timelineProvider);
        } catch (_) {
          _schedulePoll(docs);
        }
      });
    }
  }

  Future<void> refresh() async {
    final docs = await ref.read(repositoryProvider).documents();
    state = AsyncData(docs);
    _schedulePoll(docs);
  }

  /// Put a fresh copy of one document into the list (after upload/confirm/edit).
  void upsert(Document d) {
    final list = [...?state.valueOrNull];
    final i = list.indexWhere((x) => x.id == d.id);
    if (i >= 0) {
      list[i] = d;
    } else {
      list.insert(0, d);
    }
    state = AsyncData(list);
    _schedulePoll(list);
  }

  void remove(String id) {
    state = AsyncData([...?state.valueOrNull?.where((d) => d.id != id)]);
  }
}

final documentsProvider = AsyncNotifierProvider<DocumentsNotifier, List<Document>>(DocumentsNotifier.new);

/// One document, polled every 2 s while the worker has it.
final documentProvider = StreamProvider.autoDispose.family<Document, String>((ref, id) async* {
  final repo = ref.read(repositoryProvider);
  while (true) {
    final d = await repo.document(id);
    yield d;
    ref.read(documentsProvider.notifier).upsert(d);
    if (!d.isWorking) break;
    await Future<void>.delayed(const Duration(seconds: 2));
  }
});

final extractionProvider = FutureProvider.autoDispose.family<Extraction, String>(
    (ref, id) => ref.read(repositoryProvider).extraction(id));

final documentDeadlinesProvider = FutureProvider.autoDispose.family<List<Deadline>, String>(
    (ref, id) => ref.read(repositoryProvider).documentDeadlines(id));

final sharesProvider = FutureProvider.autoDispose.family<List<ShareGrant>, String>(
    (ref, id) => ref.read(repositoryProvider).shares(id));

// ── Deadlines ─────────────────────────────────────────────────────────────

final timelineProvider = FutureProvider<List<Deadline>>((ref) => ref.read(repositoryProvider).timeline());

/// Deadline ids marked done on this device.
class DoneDeadlinesNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    final s = ref.watch(sessionProvider);
    if (s is! SignedIn) return {};
    return ref.read(localPrefsProvider).doneDeadlines(s.user.id);
  }

  Future<void> _save(Set<String> v) async {
    final s = ref.read(sessionProvider);
    state = v;
    if (s is SignedIn) await ref.read(localPrefsProvider).setDoneDeadlines(s.user.id, v);
  }

  /// Marks done and dismisses that deadline's pending reminders on the backend.
  Future<void> markDone(String id) async {
    await _save({...state, id});
    try {
      final repo = ref.read(repositoryProvider);
      final rs = await repo.reminders();
      for (final r in rs.where((r) => r.deadlineId == id && r.status != 'DISMISSED')) {
        await repo.dismissReminder(r.id);
      }
    } catch (_) {
      // Local state is enough for the UI.
    }
  }

  Future<void> undo(String id) => _save({...state}..remove(id));
}

final doneDeadlinesProvider = NotifierProvider<DoneDeadlinesNotifier, Set<String>>(DoneDeadlinesNotifier.new);

// ── Household ─────────────────────────────────────────────────────────────

final familyProvider = FutureProvider<Household?>((ref) => ref.read(repositoryProvider).myFamily());

final membersProvider = FutureProvider.autoDispose<List<FamilyMember>>((ref) async {
  final f = await ref.watch(familyProvider.future);
  if (f == null) return const [];
  return ref.read(repositoryProvider).members(f.id);
});

/// Display name for any email: own saved name, else derived from the email.
String displayNameFor(LocalPrefs prefs, String email) => prefs.displayName(email) ?? nameFromEmail(email);
