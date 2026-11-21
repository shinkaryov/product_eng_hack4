// Pure logic tests (no fonts or network needed).
import 'package:familydoc/core/format.dart';
import 'package:familydoc/data/categories.dart';
import 'package:familydoc/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dates and money use US format', () {
    expect(formatDate(DateTime(2027, 3, 12)), 'Mar 12, 2027');
    expect(formatMoney('1,240.00', currency: 'USD'), r'$1,240.00');
    expect(formatMoney(86.4), r'$86.40');
  });

  test('day labels', () {
    final now = DateTime(2026, 11, 21, 15);
    expect(daysUntil(DateTime(2026, 12, 1), now), 10);
    expect(daysLabel(10), '10 days');
    expect(daysLabel(1), 'Tomorrow');
    expect(inDays(41), 'in 41 days');
  });

  test('names and masks', () {
    expect(nameFromEmail('laura.reynolds@example.com'), 'Laura Reynolds');
    expect(initials('Laura Reynolds'), 'LR');
    expect(maskNumber('LP-4482-1190'), '•••• 1190');
    expect(joinAnd(['Laura', 'David', 'Noah']), 'Laura, David and Noah');
  });

  test('document types map to Home tiles', () {
    expect(groupOf('HOME_INSURANCE'), DocGroup.insurance);
    expect(groupOf('LEASE'), DocGroup.home);
    expect(groupOf('nonsense'), DocGroup.other);
    expect(categoryPath('HOME_INSURANCE'), 'Insurance › Home or renters insurance');
  });

  test('document JSON parses review status and summary card', () {
    final d = Document.fromJson({
      'id': 'd1',
      'owner_id': 'u1',
      'title': 'Renters insurance',
      'category': 'HOME_INSURANCE',
      'review_status': 'REVIEW_REQUIRED',
      'processing_stage': 'COMPLETED',
      'display_filename': 'renters-policy-2027.pdf',
      'summary_card': {'title': 'Renters', 'issuer': 'Lemonade', 'key_facts': ['a'], 'topics': ['renters insurance']},
      'created_at': '2026-11-21T13:40:00Z',
    });
    expect(d.reviewStatus, ReviewStatus.reviewRequired);
    expect(d.isWorking, isFalse);
    expect(d.displayName, 'renters-policy-2027.pdf');
    expect(d.card?.issuer, 'Lemonade');
  });

  test('extraction flattens identifiers, terms and financials', () {
    final e = Extraction.fromJson({
      'document_id': 'd1',
      'revision': 2,
      'pages': [{'page': 1, 'text': 'hello'}],
      'facts': {'expires_on': '2027-01-31', 'needs_review': false},
      'identifiers': [{'name': 'policy_number', 'value': 'LP-1', 'quote': 'No. LP-1'}],
      'terms': [{'name': 'notice_period', 'value': '30 days'}],
      'financials': [{'name': 'premium', 'amount': '1,240.00', 'currency': 'USD'}],
      'overrides': {},
    });
    expect(e.items.map((i) => i.name), ['policy_number', 'notice_period', 'premium']);
    expect(e.expiresOn, DateTime(2027, 1, 31));
  });
}
