import 'package:flutter/material.dart';

import '../../data/categories.dart';
import '../../data/models.dart';
import '../../ui/fd.dart';

/// Deadlines shown in the Vault ask for attention only when this close.
const _badgeWindowDays = 90;

/// The confirmed deadline a document row talks about: the nearest upcoming one,
/// otherwise the most recent one that already passed. Done deadlines are skipped.
Deadline? nearestDeadline(String documentId, List<Deadline> timeline, Set<String> done) {
  final mine = timeline
      .where((d) => d.documentId == documentId && d.state == DeadlineState.confirmed && d.dueOn != null && !done.contains(d.id))
      .toList()
    ..sort((a, b) => a.dueOn!.compareTo(b.dueOn!));
  if (mine.isEmpty) return null;
  final now = today();
  for (final d in mine) {
    if (!d.dueOn!.isBefore(now)) return d;
  }
  return mine.last;
}

/// "ends Jan 31, 2027", "notice due Dec 1", "ended Nov 9".
String _deadlinePhrase(Deadline d) {
  final due = d.dueOn!;
  final past = daysUntil(due) < 0;
  final verb = switch (d.kind) {
    'INSURANCE_EXPIRATION' || 'CONTRACT_EXPIRATION' => past ? 'ended' : 'ends',
    'WARRANTY_EXPIRATION' => past ? 'warranty ended' : 'warranty ends',
    'DOCUMENT_EXPIRATION' => past ? 'expired' : 'expires',
    'CANCELLATION' => past ? 'notice was due' : 'notice due',
    'PAYMENT_DUE' => past ? 'payment was due' : 'payment due',
    _ => past ? 'was due' : 'due',
  };
  return '$verb ${formatDateSmart(due)}';
}

String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

bool _isUnknownType(Document d) {
  final code = d.category?.toUpperCase();
  return code == null || code.isEmpty || code == 'OTHER' || docTypeOf(code) == null;
}

String? _issuer(Document d) {
  final i = d.card?.issuer?.trim();
  return i == null || i.isEmpty ? null : i;
}

/// One document in the Vault list (.fd-listrow with well, title, meta, status badge).
class VaultDocumentRow extends StatelessWidget {
  const VaultDocumentRow({super.key, required this.doc, required this.deadline, required this.onTap});

  final Document doc;
  final Deadline? deadline;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    FdIcons icon = groupOf(doc.category).icon;
    String meta;
    Widget? badge;

    if (doc.isWorking) {
      icon = FdIcons.file;
      meta = uploadedAgo(doc.createdAt);
      badge = const FdBadge('Reading', spinning: true);
    } else {
      switch (doc.reviewStatus) {
        case ReviewStatus.failed:
          icon = FdIcons.file;
          meta = uploadedAgo(doc.createdAt);
          badge = const FdBadge('Couldn’t read', kind: FdBadgeKind.failed, icon: FdIcons.xCircle);
        case ReviewStatus.blocked:
          icon = FdIcons.file;
          meta = blockedShort(doc.policyReason);
          badge = const FdBadge('Not stored', icon: FdIcons.lock);
        case ReviewStatus.reviewRequired when _isUnknownType(doc):
          meta = 'We couldn’t tell what this is';
          badge = const FdBadge('Needs a look', kind: FdBadgeKind.soon, icon: FdIcons.search);
        case ReviewStatus.reviewRequired:
          meta = uploadedAgo(doc.createdAt);
          badge = const FdBadge('Review', kind: FdBadgeKind.review, icon: FdIcons.sparkle);
        default:
          final issuer = _issuer(doc);
          final d = deadline;
          if (d != null) {
            final phrase = _deadlinePhrase(d);
            meta = issuer == null ? _capitalize(phrase) : '$issuer · $phrase';
            final n = daysUntil(d.dueOn!);
            if (n <= _badgeWindowDays) {
              final overdue = d.kind == 'PAYMENT_DUE' || d.kind == 'CANCELLATION' ? 'Overdue' : 'Expired';
              badge = FdBadge.days(n, overdueLabel: overdue);
            }
          } else {
            meta = issuer ?? docTypeOf(doc.category)?.label ?? uploadedAgo(doc.createdAt);
          }
      }
    }

    return FdListRow(
      title: doc.displayName,
      meta: meta,
      leading: FdWell(icon, background: c.brandSoft, foreground: c.brand),
      trailing: badge,
      onTap: onTap,
    );
  }
}
