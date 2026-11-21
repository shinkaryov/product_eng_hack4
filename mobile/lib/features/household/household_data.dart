import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/providers.dart';

/// Owner-only list of invitations (GET /families/invitations).
final householdInvitationsProvider = FutureProvider.autoDispose<List<Invitation>>(
    (ref) => ref.read(repositoryProvider).invitations());

/// Invitations still waiting for an answer.
List<Invitation> pendingInvitations(List<Invitation> all) {
  final now = DateTime.now();
  return all
      .where((i) => i.state == 'PENDING' && (i.expiresAt == null || i.expiresAt!.isAfter(now)))
      .toList()
    ..sort((a, b) => (a.expiresAt ?? now).compareTo(b.expiresAt ?? now));
}

/// The link we ask owners to send: `familydoc://join?invitation=<id>&secret=<secret>`.
String inviteLink(String id, String secret) =>
    Uri(scheme: 'familydoc', host: 'join', queryParameters: {'invitation': id, 'secret': secret}).toString();

/// Reads an invitation id (and code, when present) from a pasted link or plain id.
({String id, String? secret}) parseInvite(String input) {
  final text = input.trim();
  if (text.contains('invitation=')) {
    final uri = Uri.tryParse(text);
    final q = uri?.queryParameters ?? const {};
    final id = q['invitation'];
    if (id != null && id.isNotEmpty) return (id: id, secret: q['secret']);
  }
  return (id: text, secret: null);
}

/// "Reynolds household" from "Laura Reynolds".
String defaultHouseholdName(String displayName) {
  final parts = displayName.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return 'My household';
  return '${parts.last} household';
}
