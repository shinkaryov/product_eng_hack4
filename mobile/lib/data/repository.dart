import 'api_client.dart';
import 'models.dart';

List<Map<String, dynamic>> _list(dynamic json) =>
    (json is List ? json : const []).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
Map<String, dynamic> _map(dynamic json) => (json as Map).cast<String, dynamic>();

/// Every backend call in one place. Screens go through providers, not this directly.
class VaultRepository {
  VaultRepository(this.api);
  final ApiClient api;

  // ── Auth ────────────────────────────────────────────────────────────────
  Future<void> register(String email, String password, {String? timezone}) =>
      api.postPublic('/auth/register', {'email': email, 'password': password, 'timezone': ?timezone});

  Future<TokenPair> login(String email, String password) async =>
      TokenPair.fromJson(_map(await api.postPublic('/auth/login', {'email': email, 'password': password})));

  Future<void> logout() => api.post('/auth/logout');

  Future<User> me() async => User.fromJson(_map(await api.get('/users/me')));

  // ── Documents ───────────────────────────────────────────────────────────
  Future<List<Document>> documents({String scope = 'all'}) async {
    final all = <Document>[];
    String? cursor;
    // Paginate: cursor = id of the last row, up to 100 per page.
    for (var i = 0; i < 20; i++) {
      final page = _list(await api.get('/documents', query: {'scope': scope, 'limit': 100, 'cursor': cursor}))
          .map(Document.fromJson)
          .toList();
      all.addAll(page);
      if (page.length < 100) break;
      cursor = page.last.id;
    }
    all.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return all;
  }

  Future<Document> document(String id) async => Document.fromJson(_map(await api.get('/documents/$id')));

  Future<Document> upload({required List<int> bytes, required String filename, required String mediaType}) async =>
      Document.fromJson(await api.upload('/documents', bytes: bytes, filename: filename, mediaType: mediaType));

  Future<Document> updateDocument(String id, {String? title, String? category}) async => Document.fromJson(
      _map(await api.patch('/documents/$id', {'title': ?title, 'category': ?category})));

  Future<void> deleteDocument(String id) => api.delete('/documents/$id');

  Future<Document> reprocess(String id) async => Document.fromJson(_map(await api.post('/documents/$id/reprocess')));

  Future<List<int>> file(String id) => api.download('/documents/$id/file');

  Future<Extraction> extraction(String id) async => Extraction.fromJson(_map(await api.get('/documents/$id/extraction')));

  Future<Extraction> correct(String id, {required int expectedRevision, required Map<String, Object?> fields}) async =>
      Extraction.fromJson(_map(await api.patch('/documents/$id/extraction', {'expected_revision': expectedRevision, 'fields': fields})));

  Future<Document> confirm(String id, {required int resultRevision, required int extractionRevision}) async =>
      Document.fromJson(_map(await api.post('/documents/$id/confirm', {
        'expected_result_revision': resultRevision,
        'expected_extraction_revision': extractionRevision,
      })));

  // ── Deadlines & reminders ───────────────────────────────────────────────
  /// Confirmed deadlines of the owner, ordered by date, with document_title.
  Future<List<Deadline>> timeline() async => _list(await api.get('/deadlines')).map(Deadline.fromJson).toList();

  Future<List<Deadline>> documentDeadlines(String id, {String? state}) async =>
      _list(await api.get('/documents/$id/deadlines', query: {'state': state})).map(Deadline.fromJson).toList();

  Future<Deadline> addDeadline(String docId, {required String kind, required DateTime date, String? label}) async =>
      Deadline.fromJson(_map(await api.post('/documents/$docId/deadlines', {'type': kind, 'date': _iso(date), 'label': ?label})));

  Future<Deadline> updateDeadline(String docId, String deadlineId, {DateTime? date, String? label, String? state}) async =>
      Deadline.fromJson(_map(await api.patch('/documents/$docId/deadlines/$deadlineId', {
        if (date != null) 'date': _iso(date),
        'label': ?label,
        'state': ?state,
      })));

  Future<List<Reminder>> reminders({String? state}) async =>
      _list(await api.get('/reminders', query: {'state': state})).map(Reminder.fromJson).toList();

  Future<void> dismissReminder(String id) => api.post('/reminders/$id/dismiss');

  // ── Household ───────────────────────────────────────────────────────────
  /// null when the user isn't in a household (404).
  Future<Household?> myFamily() async {
    try {
      return Household.fromJson(_map(await api.get('/families/me')));
    } on ApiException catch (e) {
      if (e.isNotFound) return null;
      rethrow;
    }
  }

  Future<Household> createFamily(String name) async => Household.fromJson({..._map(await api.post('/families', {'name': name})), 'role': 'OWNER'});

  Future<List<FamilyMember>> members(String familyId) async =>
      _list(await api.get('/families/$familyId/members')).map(FamilyMember.fromJson).toList();

  Future<List<Invitation>> invitations() async => _list(await api.get('/families/invitations')).map(Invitation.fromJson).toList();

  Future<Invitation> invite(String email) async => Invitation.fromJson(_map(await api.post('/families/invitations', {'email': email})));

  Future<void> respondInvitation(String id, {required String secret, required bool accept}) =>
      api.post('/families/invitations/$id/respond', {'secret': secret, 'decision': accept ? 'accept' : 'reject'});

  Future<void> removeMember(String familyId, String userId) => api.delete('/families/$familyId/members/$userId');

  Future<void> leaveFamily(String familyId, {String? successor}) =>
      api.post('/families/$familyId/leave', {'successor_user_id': successor});

  // ── Sharing ─────────────────────────────────────────────────────────────
  Future<List<ShareGrant>> shares(String docId) async =>
      _list(await api.get('/documents/$docId/shares')).map(ShareGrant.fromJson).toList();

  Future<List<ShareGrant>> shareWithFamily(String docId, String familyId) async =>
      _list(await api.post('/documents/$docId/shares', {'family_id': familyId})).map(ShareGrant.fromJson).toList();

  Future<void> stopSharing(String docId) => api.delete('/documents/$docId/shares');

  // ── Chat (per document) ─────────────────────────────────────────────────
  Future<ChatSession> createChat(String docId) async => ChatSession.fromJson(_map(await api.post('/documents/$docId/chat', {})));

  Future<List<ChatSession>> chats(String docId) async =>
      _list(await api.get('/documents/$docId/chat')).map(ChatSession.fromJson).toList();

  Future<ChatSession> chat(String chatId) async => ChatSession.fromJson(_map(await api.get('/chat/$chatId')));

  Future<ChatTurn> ask(String chatId, String message) async =>
      ChatTurn.fromJson(_map(await api.post('/chat/$chatId/messages', {'message': message})));

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
