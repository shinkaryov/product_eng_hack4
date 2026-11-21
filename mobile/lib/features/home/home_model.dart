import '../../core/format.dart';
import '../../data/categories.dart';
import '../../data/models.dart';

/// Pure view-model for Home: what's due, what needs review, tile counts.
class HomeModel {
  HomeModel._({
    required this.docs,
    required this.byId,
    required this.overdue,
    required this.soon,
    required this.later,
    required this.review,
    required this.working,
    required this.failed,
    required this.blocked,
    required this.groupCounts,
    required this.groupSoon,
    required this.groupOverdue,
    required this.unsorted,
  });

  final List<Document> docs;
  final Map<String, Document> byId;

  /// Due before today, oldest first.
  final List<Deadline> overdue;

  /// Due today .. 30 days, soonest first.
  final List<Deadline> soon;

  /// Due after 30 days, soonest first.
  final List<Deadline> later;

  final List<Document> review;
  final List<Document> working;
  final List<Document> failed;
  final List<Document> blocked;

  /// READY + REVIEW_REQUIRED documents per group.
  final Map<DocGroup, int> groupCounts;
  final Set<DocGroup> groupSoon;
  final Map<DocGroup, int> groupOverdue;

  /// OTHER documents still waiting for review.
  final int unsorted;

  int get total => groupCounts.values.fold(0, (a, b) => a + b);

  /// No stored documents and no deadlines: show the new-vault screen.
  bool get isEmpty => total == 0 && overdue.isEmpty && soon.isEmpty && later.isEmpty;

  int get attentionCount => overdue.length + soon.length;

  factory HomeModel.build({required List<Document> docs, required List<Deadline> timeline, required Set<String> done}) {
    final now = today();
    final byId = {for (final d in docs) d.id: d};
    final active = timeline
        .where((d) => d.dueOn != null && d.state != DeadlineState.rejected && !done.contains(d.id))
        .toList()
      ..sort((a, b) => a.dueOn!.compareTo(b.dueOn!));

    final overdue = <Deadline>[];
    final soon = <Deadline>[];
    final later = <Deadline>[];
    for (final d in active) {
      final n = daysUntil(d.dueOn!, now);
      if (n < 0) {
        overdue.add(d);
      } else if (n <= 30) {
        soon.add(d);
      } else {
        later.add(d);
      }
    }

    final counts = {for (final g in DocGroup.values) g: 0};
    var unsorted = 0;
    for (final d in docs) {
      if (d.reviewStatus == ReviewStatus.ready || d.reviewStatus == ReviewStatus.reviewRequired) {
        final g = groupOf(d.category);
        counts[g] = counts[g]! + 1;
        if (g == DocGroup.other && d.reviewStatus == ReviewStatus.reviewRequired) unsorted++;
      }
    }

    final groupSoon = <DocGroup>{};
    for (final d in soon) {
      final doc = byId[d.documentId];
      if (doc != null) groupSoon.add(groupOf(doc.category));
    }
    final groupOverdue = <DocGroup, int>{};
    for (final d in overdue) {
      final doc = byId[d.documentId];
      if (doc != null) {
        final g = groupOf(doc.category);
        groupOverdue[g] = (groupOverdue[g] ?? 0) + 1;
      }
    }

    List<Document> where(bool Function(Document) f) => docs.where(f).toList();

    return HomeModel._(
      docs: docs,
      byId: byId,
      overdue: overdue,
      soon: soon,
      later: later,
      review: where((d) => d.reviewStatus == ReviewStatus.reviewRequired && !d.isWorking),
      working: where((d) => d.isWorking && d.reviewStatus != ReviewStatus.blocked && d.reviewStatus != ReviewStatus.failed),
      failed: where((d) => d.reviewStatus == ReviewStatus.failed),
      blocked: where((d) => d.reviewStatus == ReviewStatus.blocked),
      groupCounts: counts,
      groupSoon: groupSoon,
      groupOverdue: groupOverdue,
      unsorted: unsorted,
    );
  }

  /// A sample question for the Ask card, based on what's in the vault.
  String get sampleQuestion {
    if ((groupCounts[DocGroup.warranties] ?? 0) > 0) return 'Which warranties expire next month?';
    if (docs.any((d) => d.category?.toUpperCase() == 'LEASE')) return 'What does my lease say about pets?';
    if ((groupCounts[DocGroup.insurance] ?? 0) > 0) return 'What does my policy cover?';
    if ((groupCounts[DocGroup.vehicle] ?? 0) > 0) return 'When is my car registration due?';
    if ((groupCounts[DocGroup.ids] ?? 0) > 0) return 'When does my passport expire?';
    return 'When does my next document expire?';
  }
}

const _expiryKinds = {'INSURANCE_EXPIRATION', 'CONTRACT_EXPIRATION', 'WARRANTY_EXPIRATION', 'DOCUMENT_EXPIRATION'};

bool isExpiryKind(String kind) => _expiryKinds.contains(kind);

/// Deadline headline: its own label, else the kind ("Policy ends").
String deadlineTitle(Deadline d) => (d.label?.trim().isNotEmpty ?? false) ? d.label!.trim() : deadlineKindTitle(d.kind);

/// Document name for a deadline: the timeline's title, else the document in the list.
String deadlineDocName(Deadline d, Document? doc) {
  final t = d.documentTitle?.trim();
  if (t != null && t.isNotEmpty) return t;
  return doc?.displayName ?? 'Document';
}
