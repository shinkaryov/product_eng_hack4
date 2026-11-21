import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../data/api_client.dart';
import '../../data/categories.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../ui/fd.dart';
import '../add/add_sheet.dart';
import '../add/link_text.dart';
import 'types_sheet.dart';

/// "We didn’t keep this file" (design Blocked). The backend already deleted the
/// file; the user can remove the row from the list.
class BlockedScreen extends ConsumerStatefulWidget {
  const BlockedScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<BlockedScreen> createState() => _BlockedScreenState();
}

class _BlockedScreenState extends ConsumerState<BlockedScreen> {
  bool _removing = false;

  /// Filename once removed (the document is gone from the backend then).
  String? _removed;

  Future<void> _remove(Document d) async {
    setState(() => _removing = true);
    try {
      await ref.read(repositoryProvider).deleteDocument(d.id);
    } on ApiException catch (e) {
      // Already gone counts as removed.
      if (!e.isNotFound) {
        if (mounted) {
          setState(() => _removing = false);
          FdToast.error(context, e);
        }
        return;
      }
    } catch (e) {
      if (mounted) {
        setState(() => _removing = false);
        FdToast.error(context, e);
      }
      return;
    }
    ref.read(documentsProvider.notifier).remove(d.id);
    if (mounted) {
      setState(() {
        _removing = false;
        _removed = _name(d);
      });
    }
  }

  /// "We also don’t store passwords, …" without the kind this file was.
  static String _alsoNotStored(String reason) {
    const kinds = {
      'Bank card photo': 'bank cards',
      'Passwords or secrets': 'passwords',
      'Biometric data': 'biometric data',
      'Military or federal ID': 'military IDs',
      'Citizenship certificate': 'citizenship certificates',
    };
    final matched = kinds[blockedShort(reason)];
    final rest = kinds.values.where((k) => k != matched).toList();
    return matched == null ? 'We don’t store ${_joinOr(rest)}.' : 'We also don’t store ${_joinOr(rest)}.';
  }

  static String _joinOr(List<String> items) =>
      items.length < 2 ? items.join() : '${items.sublist(0, items.length - 1).join(', ')} or ${items.last}';

  static String _name(Document d) => d.displayFilename ?? d.title ?? 'This file';

  @override
  Widget build(BuildContext context) {
    final removed = _removed;
    if (removed != null) {
      return FdPage(
        appBar: const FdAppBar(),
        children: [
          Padding(
            padding: const EdgeInsets.only(top: FdSpace.s6),
            child: FdGapColumn(gap: FdSpace.s3, crossAxisAlignment: CrossAxisAlignment.start, children: [
              FdStatus(
                kind: FdStatusKind.ok,
                compact: false,
                title: 'Removed',
                subtitle: 'Nothing from $removed is left in your vault.',
              ),
              FdButton.secondary('Back to Home', onPressed: () => context.go(Routes.home)),
            ]),
          ),
        ],
      );
    }

    final async = ref.watch(documentProvider(widget.id));
    final notFound = async.error is ApiException && (async.error as ApiException).isNotFound;
    return FdPage(
      appBar: const FdAppBar(),
      onRefresh: () async => ref.invalidate(documentProvider(widget.id)),
      children: [
        if (async.hasValue)
          ..._content(context, async.requireValue)
        else if (notFound) ...[
          FdNotice.text('This file isn’t in your list anymore.', icon: FdIcons.file),
          FdButton.secondary('Back to Home', onPressed: () => context.go(Routes.home)),
        ] else if (async.hasError)
          FdErrorState(error: async.error!, onRetry: () => ref.invalidate(documentProvider(widget.id)))
        else
          const FdLoading(),
      ],
    );
  }

  List<Widget> _content(BuildContext context, Document d) {
    final c = context.fd;
    final name = _name(d);
    final reason = [d.policyReason, d.category].whereType<String>().join(' ');
    return [
      FdCard.pad(
        child: FdGapColumn(gap: FdSpace.s3, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, color: c.surfaceSunken),
            child: FdIcon.lg(FdIcons.lock, color: c.ink),
          ),
          Semantics(header: true, child: Text('We didn’t keep this file', style: FdType.display.copyWith(color: c.ink))),
          Text(blockedDescription(reason),
              style: FdType.body.copyWith(color: c.ink)),
          Text('$name was not saved and won’t be used in chat.', style: FdType.meta.copyWith(color: c.inkSecondary)),
          FdRowWrap(children: [
            FdButton('Remove from list', loading: _removing, onPressed: _removing ? null : () => _remove(d)),
            FdButton.quiet('Upload a different file', onPressed: _removing ? null : () => showAddSheet(context)),
          ]),
        ]),
      ),
      FdNotice(
        kind: FdNoticeKind.neutral,
        icon: FdIcons.shieldCheck,
        child: InlineLinkText(
          text: _alsoNotStored(reason),
          link: 'What we store',
          onTap: () => showTypesSheet(context, pickable: false),
        ),
      ),
    ];
  }
}
