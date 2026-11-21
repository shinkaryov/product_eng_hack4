// Models mirror the backend JSON (product_eng_hack4, branch `back`).
// See docs/api_contracts.md there. Parsing is lenient: unknown/missing → null.

DateTime? _ts(Object? v) => v is String ? DateTime.tryParse(v) : null;
DateTime? _day(Object? v) {
  if (v is! String) return null;
  final d = DateTime.tryParse(v);
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

String? _str(Object? v) => v?.toString();
List<String> _strList(Object? v) => v is List ? v.map((e) => e.toString()).toList() : const [];

class User {
  const User({required this.id, required this.email, required this.timezone});
  final String id;
  final String email;
  final String timezone;

  factory User.fromJson(Map<String, dynamic> j) =>
      User(id: j['id'].toString(), email: j['email'] as String, timezone: (j['timezone'] as String?) ?? 'UTC');
}

class TokenPair {
  const TokenPair(this.access, this.refresh);
  final String access;
  final String refresh;
  factory TokenPair.fromJson(Map<String, dynamic> j) =>
      TokenPair(j['access_token'] as String, j['refresh_token'] as String);
}

/// Worker stage of the document.
enum ProcessingStage { pending, processing, completed, failed, unknown }

/// What the app shows: UPLOADED → PROCESSING → REVIEW_REQUIRED → READY, or BLOCKED / FAILED.
enum ReviewStatus { uploaded, processing, reviewRequired, ready, blocked, failed, unknown }

ReviewStatus _review(Object? v) => switch (v) {
      'UPLOADED' => ReviewStatus.uploaded,
      'PROCESSING' => ReviewStatus.processing,
      'REVIEW_REQUIRED' => ReviewStatus.reviewRequired,
      'READY' => ReviewStatus.ready,
      'BLOCKED' => ReviewStatus.blocked,
      'FAILED' => ReviewStatus.failed,
      _ => ReviewStatus.unknown,
    };

ProcessingStage _stage(Object? v) => switch (v) {
      'PENDING' => ProcessingStage.pending,
      'PROCESSING' => ProcessingStage.processing,
      'COMPLETED' => ProcessingStage.completed,
      'FAILED' => ProcessingStage.failed,
      _ => ProcessingStage.unknown,
    };

class SummaryCard {
  const SummaryCard({this.title, this.holder, this.issuer, this.keyFacts = const [], this.topics = const []});
  final String? title;
  final String? holder;
  final String? issuer;
  final List<String> keyFacts;
  final List<String> topics;

  factory SummaryCard.fromJson(Map<String, dynamic> j) => SummaryCard(
        title: _str(j['title']),
        holder: _str(j['holder']),
        issuer: _str(j['issuer']),
        keyFacts: _strList(j['key_facts']),
        topics: _strList(j['topics']),
      );
}

class Document {
  const Document({
    required this.id,
    required this.ownerId,
    required this.title,
    required this.category,
    required this.subtype,
    required this.reviewStatus,
    required this.stage,
    required this.resultRevision,
    required this.errorCode,
    required this.policyReason,
    required this.displayFilename,
    required this.mediaType,
    required this.sizeBytes,
    required this.summary,
    required this.card,
    required this.confirmedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String ownerId;
  final String? title;

  /// AI document type, e.g. HOME_INSURANCE. See categories.dart.
  final String? category;
  final String? subtype;
  final ReviewStatus reviewStatus;
  final ProcessingStage stage;
  final int? resultRevision;
  final String? errorCode;
  final String? policyReason;
  final String? displayFilename;
  final String? mediaType;
  final int? sizeBytes;
  final String? summary;
  final SummaryCard? card;
  final DateTime? confirmedAt;
  final DateTime createdAt;
  final DateTime? updatedAt;

  /// Title for lists: the reviewed title once READY, otherwise the filename.
  String get displayName {
    if (reviewStatus == ReviewStatus.ready && (title?.isNotEmpty ?? false)) return title!;
    return displayFilename ?? title ?? 'Document';
  }

  bool get isPdf => mediaType == 'application/pdf' || (displayFilename?.toLowerCase().endsWith('.pdf') ?? false);

  /// Still with the worker (keep polling).
  bool get isWorking =>
      reviewStatus == ReviewStatus.uploaded ||
      reviewStatus == ReviewStatus.processing ||
      stage == ProcessingStage.pending ||
      stage == ProcessingStage.processing;

  factory Document.fromJson(Map<String, dynamic> j) {
    final card = j['summary_card'];
    return Document(
      id: j['id'].toString(),
      ownerId: j['owner_id'].toString(),
      title: _str(j['title']),
      category: _str(j['category']),
      subtype: _str(j['subtype']),
      reviewStatus: _review(j['review_status']),
      stage: _stage(j['processing_stage'] ?? j['status']),
      resultRevision: (j['result_revision'] as num?)?.toInt(),
      errorCode: _str(j['error_code']),
      policyReason: _str(j['policy_reason']),
      displayFilename: _str(j['display_filename']),
      mediaType: _str(j['media_type']),
      sizeBytes: (j['size_bytes'] as num?)?.toInt(),
      summary: _str(j['summary']),
      card: card is Map<String, dynamic> ? SummaryCard.fromJson(card) : null,
      confirmedAt: _ts(j['confirmed_at']),
      createdAt: _ts(j['created_at']) ?? DateTime.now(),
      updatedAt: _ts(j['updated_at']),
    );
  }
}

/// One extracted fact with the exact quote it came from.
class ExtractedFact {
  const ExtractedFact({required this.group, required this.name, required this.value, this.quote, this.currency, this.period});
  final String group; // identifiers | terms | financials
  final String name;
  final String value;
  final String? quote;
  final String? currency;
  final String? period;
}

class Extraction {
  const Extraction({
    required this.documentId,
    required this.revision,
    required this.pages,
    required this.facts,
    required this.items,
    required this.overrides,
  });

  final String documentId;
  final int revision;
  final List<String> pages;

  /// Raw `facts` object: doc_type, expires_on, expires_on_quote, payment_due_on, warnings, needs_review…
  final Map<String, dynamic> facts;

  /// identifiers + terms + financials, in that order.
  final List<ExtractedFact> items;
  final Map<String, dynamic> overrides;

  String get fullText => pages.join('\n\n');
  bool get needsReview => facts['needs_review'] == true;
  DateTime? get expiresOn => _day(facts['expires_on']);
  String? get expiresQuote => _str(facts['expires_on_quote']);

  factory Extraction.fromJson(Map<String, dynamic> j) {
    final items = <ExtractedFact>[];
    for (final group in const ['identifiers', 'terms', 'financials']) {
      final list = j[group];
      if (list is! List) continue;
      for (final raw in list.whereType<Map<String, dynamic>>()) {
        final name = _str(raw['name']) ?? '';
        if (name.isEmpty) continue;
        items.add(ExtractedFact(
          group: group,
          name: name,
          value: _str(raw['value'] ?? raw['amount']) ?? '',
          quote: _str(raw['quote']),
          currency: _str(raw['currency']),
          period: _str(raw['period']),
        ));
      }
    }
    final pages = (j['pages'] is List ? j['pages'] as List : const [])
        .whereType<Map<String, dynamic>>()
        .map((p) => _str(p['text']) ?? '')
        .toList();
    return Extraction(
      documentId: j['document_id'].toString(),
      revision: (j['revision'] as num?)?.toInt() ?? 0,
      pages: pages,
      facts: (j['facts'] as Map?)?.cast<String, dynamic>() ?? const {},
      items: items,
      overrides: (j['overrides'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }
}

enum DeadlineState { proposed, confirmed, rejected }

class Deadline {
  const Deadline({
    required this.id,
    required this.documentId,
    required this.kind,
    required this.label,
    required this.dueOn,
    required this.state,
    required this.candidateKey,
    required this.evidenceQuote,
    required this.documentTitle,
  });

  final String id;
  final String documentId;

  /// CONTRACT_EXPIRATION, CANCELLATION, INSURANCE_EXPIRATION, WARRANTY_EXPIRATION,
  /// PAYMENT_DUE, DOCUMENT_EXPIRATION, OTHER.
  final String kind;
  final String? label;
  final DateTime? dueOn;
  final DeadlineState state;
  final String? candidateKey;
  final String? evidenceQuote;

  /// Only on GET /deadlines.
  final String? documentTitle;

  factory Deadline.fromJson(Map<String, dynamic> j) {
    final ev = j['evidence'];
    return Deadline(
      id: j['id'].toString(),
      documentId: j['document_id'].toString(),
      kind: _str(j['kind']) ?? 'OTHER',
      label: _str(j['label']),
      dueOn: _day(j['due_on']),
      state: switch (j['state']) {
        'CONFIRMED' => DeadlineState.confirmed,
        'REJECTED' => DeadlineState.rejected,
        _ => DeadlineState.proposed,
      },
      candidateKey: _str(j['candidate_key']),
      evidenceQuote: ev is Map ? _str(ev['quote']) : null,
      documentTitle: _str(j['document_title']),
    );
  }
}

class Reminder {
  const Reminder({required this.id, required this.deadlineId, required this.offsetDays, required this.scheduledAt, required this.status});
  final String id;
  final String deadlineId;
  final int offsetDays;
  final DateTime? scheduledAt;
  final String status; // SCHEDULED | DUE | DISMISSED
  factory Reminder.fromJson(Map<String, dynamic> j) => Reminder(
        id: j['id'].toString(),
        deadlineId: j['deadline_id'].toString(),
        offsetDays: (j['offset_days'] as num?)?.toInt() ?? 0,
        scheduledAt: _ts(j['scheduled_at']),
        status: _str(j['status']) ?? 'SCHEDULED',
      );
}

class Household {
  const Household({required this.id, required this.name, required this.role});
  final String id;
  final String name;
  final String role; // OWNER | MEMBER
  bool get isOwner => role == 'OWNER';
  factory Household.fromJson(Map<String, dynamic> j) =>
      Household(id: j['id'].toString(), name: j['name'] as String, role: _str(j['role']) ?? 'OWNER');
}

class FamilyMember {
  const FamilyMember({required this.userId, required this.email, required this.role, required this.joinedAt});
  final String userId;
  final String email;
  final String role;
  final DateTime? joinedAt;
  factory FamilyMember.fromJson(Map<String, dynamic> j) => FamilyMember(
        userId: j['user_id'].toString(),
        email: j['email'] as String,
        role: _str(j['role']) ?? 'MEMBER',
        joinedAt: _ts(j['joined_at']),
      );
}

class Invitation {
  const Invitation({required this.id, required this.state, required this.expiresAt, this.secret});
  final String id;
  final String state;
  final DateTime? expiresAt;

  /// Returned once, on create.
  final String? secret;
  factory Invitation.fromJson(Map<String, dynamic> j) => Invitation(
        id: j['id'].toString(),
        state: _str(j['state']) ?? 'PENDING',
        expiresAt: _ts(j['expires_at']),
        secret: _str(j['secret']),
      );
}

class ShareGrant {
  const ShareGrant({required this.userId, required this.grantedAt});
  final String userId;
  final DateTime? grantedAt;
  factory ShareGrant.fromJson(Map<String, dynamic> j) =>
      ShareGrant(userId: j['user_id'].toString(), grantedAt: _ts(j['granted_at']));
}

class Citation {
  const Citation({required this.documentId, required this.quote});
  final String documentId;
  final String? quote;
  factory Citation.fromJson(Map<String, dynamic> j) =>
      Citation(documentId: j['document_id'].toString(), quote: _str(j['quote']));
}

class ChatTurn {
  const ChatTurn({
    required this.id,
    required this.question,
    required this.answered,
    required this.answer,
    required this.citations,
    required this.createdAt,
  });
  final String id;
  final String question;

  /// ANSWERED vs INSUFFICIENT_INFORMATION.
  final bool answered;
  final String? answer;
  final List<Citation> citations;
  final DateTime? createdAt;

  factory ChatTurn.fromJson(Map<String, dynamic> j) => ChatTurn(
        id: j['id'].toString(),
        question: _str(j['question']) ?? '',
        answered: j['answer_status'] == 'ANSWERED',
        answer: _str(j['answer']),
        citations: (j['citations'] is List ? j['citations'] as List : const [])
            .whereType<Map<String, dynamic>>()
            .map(Citation.fromJson)
            .toList(),
        createdAt: _ts(j['created_at']),
      );
}

class ChatSession {
  const ChatSession({required this.id, required this.documentId, required this.turns});
  final String id;
  final String? documentId;
  final List<ChatTurn> turns;
  factory ChatSession.fromJson(Map<String, dynamic> j) => ChatSession(
        id: j['id'].toString(),
        documentId: _str(j['document_id']),
        turns: (j['turns'] is List ? j['turns'] as List : const [])
            .whereType<Map<String, dynamic>>()
            .map(ChatTurn.fromJson)
            .toList(),
      );
}
