import '../core/icons.dart';

/// Tiles on Home and chips in Vault. Backend `category` is an AI document type;
/// the app groups types into these (docs/api_contracts.md, "Категорії").
enum DocGroup {
  ids('IDs', FdIcons.idCard),
  insurance('Insurance', FdIcons.umbrella),
  home('Home & bills', FdIcons.home),
  vehicle('Vehicle', FdIcons.car),
  warranties('Warranties', FdIcons.receipt),
  other('Other', FdIcons.file);

  const DocGroup(this.label, this.icon);
  final String label;
  final FdIcons icon;
}

class DocType {
  const DocType(this.code, this.label, this.group);
  final String code;
  final String label;
  final DocGroup group;
}

/// Order and labels follow the Types sheet in the design.
const docTypes = <DocType>[
  DocType('PASSPORT', 'Passport', DocGroup.ids),
  DocType('DRIVERS_LICENSE', 'Driver’s license', DocGroup.ids),
  DocType('ID_CARD', 'ID card', DocGroup.ids),
  DocType('GREEN_CARD', 'Green card', DocGroup.ids),
  DocType('VISA', 'Visa', DocGroup.ids),
  DocType('BIRTH_CERTIFICATE', 'Birth certificate', DocGroup.ids),
  DocType('HOME_INSURANCE', 'Home or renters insurance', DocGroup.insurance),
  DocType('AUTO_INSURANCE', 'Auto insurance', DocGroup.insurance),
  DocType('HEALTH_INSURANCE', 'Health insurance', DocGroup.insurance),
  DocType('TRAVEL_INSURANCE', 'Travel insurance', DocGroup.insurance),
  DocType('LIFE_INSURANCE', 'Life insurance', DocGroup.insurance),
  DocType('LEASE', 'Lease', DocGroup.home),
  DocType('UTILITY_CONTRACT', 'Utility contract', DocGroup.home),
  DocType('UTILITY_BILL', 'Utility bill', DocGroup.home),
  DocType('SUBSCRIPTION', 'Subscription', DocGroup.home),
  DocType('VEHICLE_REGISTRATION', 'Vehicle registration', DocGroup.vehicle),
  DocType('VEHICLE_INSPECTION', 'Vehicle inspection', DocGroup.vehicle),
  DocType('WARRANTY', 'Warranty', DocGroup.warranties),
  DocType('RECEIPT', 'Receipt or invoice', DocGroup.warranties),
  DocType('OTHER', 'Something else', DocGroup.other),
];

/// Group name in the Types sheet ("Warranties & receipts" there).
String groupSheetLabel(DocGroup g) => g == DocGroup.warranties ? 'Warranties & receipts' : g.label;

DocType? docTypeOf(String? code) {
  if (code == null) return null;
  final c = code.toUpperCase();
  for (final t in docTypes) {
    if (t.code == c) return t;
  }
  return null;
}

DocGroup groupOf(String? code) => docTypeOf(code)?.group ?? DocGroup.other;

/// "Insurance › Home or renters insurance"
String categoryPath(String? code) {
  final t = docTypeOf(code);
  if (t == null) return 'Other';
  if (t.group == DocGroup.other) return 'Other';
  return '${t.group.label} › ${t.label}';
}

/// Kinds of documents the backend refuses to keep (BLOCKED).
const blockedTypes = <(String, String, String)>[
  ('BANK_CARD_OR_CHECK', 'Bank cards and checks', 'We don’t store photos of payment cards or blank checks.'),
  ('CREDENTIALS_OR_SECRETS', 'Passwords and secrets', 'We don’t store passwords, PINs, 2FA codes or recovery phrases.'),
  ('BIOMETRIC_OR_GENETIC', 'Biometric and genetic data', 'We don’t store fingerprints or DNA results.'),
  ('MILITARY_OR_FEDERAL_ID', 'Military and federal IDs', 'US law restricts copying these.'),
  ('NATURALIZATION_CERTIFICATE', 'Naturalization and citizenship certificates', 'US law restricts copying these.'),
];

/// Human sentence for a blocked document's policy reason / type.
String blockedDescription(String? reason) {
  final r = (reason ?? '').toUpperCase();
  if (r.contains('BANK') || r.contains('CARD') || r.contains('CHECK')) {
    return 'It looks like a photo of a bank card. We don’t store payment cards or blank checks, so we deleted the file.';
  }
  if (r.contains('CREDENTIAL') || r.contains('SECRET') || r.contains('PASSWORD')) {
    return 'It looks like it contains passwords or secrets. We don’t store those, so we deleted the file.';
  }
  if (r.contains('BIOMETRIC') || r.contains('GENETIC')) {
    return 'It looks like biometric or genetic data. We don’t store that, so we deleted the file.';
  }
  if (r.contains('MILITARY') || r.contains('FEDERAL')) {
    return 'It looks like a military or federal ID. US law restricts copying these, so we deleted the file.';
  }
  if (r.contains('NATURALIZATION') || r.contains('CITIZEN')) {
    return 'It looks like a naturalization or citizenship certificate. US law restricts copying these, so we deleted the file.';
  }
  return 'This kind of document isn’t something we store, so we deleted the file.';
}

/// Short label of what the blocked file looked like ("Bank card photo").
String blockedShort(String? reason) {
  final r = (reason ?? '').toUpperCase();
  if (r.contains('BANK') || r.contains('CARD') || r.contains('CHECK')) return 'Bank card photo';
  if (r.contains('CREDENTIAL') || r.contains('SECRET')) return 'Passwords or secrets';
  if (r.contains('BIOMETRIC') || r.contains('GENETIC')) return 'Biometric data';
  if (r.contains('MILITARY') || r.contains('FEDERAL')) return 'Military or federal ID';
  if (r.contains('NATURALIZATION')) return 'Citizenship certificate';
  return 'Not a supported document';
}

/// Deadline kind → human title ("Policy ends").
String deadlineKindTitle(String kind) => switch (kind) {
      'INSURANCE_EXPIRATION' => 'Policy ends',
      'CONTRACT_EXPIRATION' => 'Contract ends',
      'CANCELLATION' => 'Last day to cancel or renew',
      'WARRANTY_EXPIRATION' => 'Warranty ends',
      'PAYMENT_DUE' => 'Payment due',
      'DOCUMENT_EXPIRATION' => 'Expires',
      _ => 'Deadline',
    };

/// Eyebrow on the Home hero card.
String deadlineKindEyebrow(String kind) => switch (kind) {
      'CANCELLATION' => 'Notice deadline',
      'PAYMENT_DUE' => 'Payment due',
      'INSURANCE_EXPIRATION' => 'Policy ends',
      'WARRANTY_EXPIRATION' => 'Warranty ends',
      'CONTRACT_EXPIRATION' => 'Contract ends',
      'DOCUMENT_EXPIRATION' => 'Expires',
      _ => 'Deadline',
    };
