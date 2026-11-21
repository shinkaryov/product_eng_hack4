import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../ui/fd.dart';
import '../document/types_sheet.dart';
import 'link_text.dart';
import 'scan_session.dart';
import 'upload.dart';

/// "Add a document" sheet (designs Add / UploadError): scan or upload a file.
Future<void> showAddSheet(BuildContext context) {
  final router = GoRouter.of(context);
  return showFdSheet<void>(context, builder: (_) => _AddSheet(router: router));
}

class _AddSheet extends ConsumerStatefulWidget {
  const _AddSheet({required this.router});
  final GoRouter router;

  @override
  ConsumerState<_AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends ConsumerState<_AddSheet> {
  UploadProblem? _problem;
  String? _uploading;

  void _scan() {
    ref.read(scanSessionProvider.notifier).clear();
    Navigator.of(context).pop();
    widget.router.push(Routes.scan);
  }

  Future<void> _upload() async {
    setState(() => _problem = null);
    try {
      final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: uploadExtensions);
      if (file == null || !mounted) return;
      validateUpload(file.name, file.lengthSync() ?? await file.length());
      setState(() => _uploading = file.name);
      final bytes = await file.readAsBytes();
      final doc = await uploadDocument(ref, bytes: bytes, filename: file.name);
      if (mounted) Navigator.of(context).pop();
      openProcessing(widget.router, doc);
    } on UploadProblem catch (p) {
      if (mounted) setState(() => _problem = p);
    } catch (_) {
      if (mounted) setState(() => _problem = const UploadProblem(null, 'Something went wrong. Try again.'));
    } finally {
      if (mounted) setState(() => _uploading = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final busy = _uploading != null;
    final problem = _problem;
    return FdGapColumn(children: [
      Semantics(header: true, child: Text('Add a document', style: FdType.headline.copyWith(color: c.ink))),
      if (problem != null)
        Semantics(
          liveRegion: true,
          child: FdNotice(
            kind: FdNoticeKind.danger,
            icon: FdIcons.alert,
            child: Text.rich(TextSpan(children: [
              if (problem.lead != null) TextSpan(text: '${problem.lead} ', style: const TextStyle(fontWeight: FontWeight.w700)),
              TextSpan(text: problem.message),
            ])),
          ),
        ),
      FdList(children: [
        FdListRow(
          leading: const FdWell(FdIcons.scan),
          title: 'Scan with camera',
          meta: 'Paper documents and receipts',
          onTap: busy ? null : _scan,
        ),
        FdListRow(
          leading: const FdWell(FdIcons.upload),
          title: 'Upload a file',
          meta: busy ? 'Uploading $_uploading' : 'PDF, JPG or PNG, up to 10 MB',
          trailing: busy ? FdSpinner(size: 20, color: c.brand) : null,
          onTap: busy ? null : _upload,
        ),
      ]),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: FdIcon.sm(FdIcons.lock, color: c.inkSecondary)),
        const SizedBox(width: FdSpace.s2),
        Expanded(
          child: InlineLinkText(
            text: 'We don’t store bank cards, passwords, biometric data, military IDs or citizenship certificates.',
            link: 'What we store',
            style: FdType.meta.copyWith(color: c.inkSecondary),
            onTap: () => showTypesSheet(context, pickable: false),
          ),
        ),
      ]),
    ]);
  }
}
