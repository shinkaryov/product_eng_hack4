import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/router.dart';
import '../../ui/fd.dart';
import 'scan_session.dart';
import 'upload.dart';

/// One PDF with a page per photo (A4, image fitted inside).
Future<Uint8List> buildScanPdf(List<Uint8List> pages) async {
  final doc = pw.Document(title: 'Scan', creator: 'FamilyDoc');
  for (final bytes in pages) {
    final image = pw.MemoryImage(bytes);
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(18),
      build: (_) => pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
    ));
  }
  return doc.save();
}

/// Builds the PDF off the UI thread. Top-level so the closure captures only [pages].
Future<Uint8List> buildScanPdfInBackground(List<Uint8List> pages) => Isolate.run(() => buildScanPdf(pages));

/// "scan-1121.pdf"
String scanFilename([DateTime? now]) {
  final d = now ?? DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return 'scan-${two(d.month)}${two(d.day)}.pdf';
}

/// "Check pages" (design ScanReview). Pops with the new document id after saving
/// so the scanner can replace itself with the processing screen.
class ScanReviewScreen extends ConsumerStatefulWidget {
  const ScanReviewScreen({super.key});

  @override
  ConsumerState<ScanReviewScreen> createState() => _ScanReviewScreenState();
}

class _ScanReviewScreenState extends ConsumerState<ScanReviewScreen> {
  int? _selected;
  bool _saving = false;
  bool _leaving = false;
  UploadProblem? _problem;

  void _backToScanner([String? savedId]) {
    if (_leaving) return;
    _leaving = true;
    if (context.canPop()) {
      context.pop(savedId);
    } else if (savedId != null) {
      context.pushReplacement(Routes.processing(savedId));
    } else {
      context.pushReplacement(Routes.scan);
    }
  }

  void _addPage() {
    ref.read(scanSessionProvider.notifier).addNext();
    _backToScanner();
  }

  void _retake(int index) {
    ref.read(scanSessionProvider.notifier).retake(index);
    _backToScanner();
  }

  Future<void> _save(List<Uint8List> pages) async {
    setState(() {
      _saving = true;
      _problem = null;
    });
    try {
      final pdf = await buildScanPdfInBackground(pages);
      if (!mounted) return;
      final doc = await uploadDocument(ref, bytes: pdf, filename: scanFilename());
      if (!mounted) return;
      _backToScanner(doc.id);
      ref.read(scanSessionProvider.notifier).clear();
    } on UploadProblem catch (p) {
      if (mounted) setState(() => _problem = p);
    } catch (_) {
      if (mounted) setState(() => _problem = const UploadProblem(null, 'We couldn’t put the pages together. Try again.'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final session = ref.watch(scanSessionProvider);
    final pages = session.pages;

    if (pages.isEmpty) {
      if (!_saving && !_leaving) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _backToScanner() : null);
      return Scaffold(backgroundColor: c.canvas, body: const Center(child: FdLoading()));
    }

    final selected = (_selected ?? pages.length - 1).clamp(0, pages.length - 1);
    final problem = _problem;

    return PopScope(
      canPop: !_saving,
      child: FdPage(
        appBar: FdAppBar(title: 'Check pages', onBack: _saving ? () {} : _addPage),
        footer: FdFooter(children: [
          FdButton(
            'Save ${plural(pages.length, 'page')}',
            block: true,
            loading: _saving,
            onPressed: _saving ? null : () => _save(List.of(pages)),
          ),
        ]),
        children: [
          Text('Make sure every page is sharp and nothing is cut off.', style: FdType.callout.copyWith(color: c.inkSecondary)),
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
          Padding(
            padding: const EdgeInsets.symmetric(vertical: FdSpace.s2),
            child: LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: box.maxWidth),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (var i = 0; i < pages.length; i++) ...[
                      if (i > 0) const SizedBox(width: FdSpace.s5 - 12),
                      _Thumb(
                        bytes: pages[i],
                        label: 'Page ${i + 1}',
                        selected: i == selected,
                        onTap: _saving ? null : () => setState(() => _selected = i),
                      ),
                    ],
                  ]),
                ),
              ),
            ),
          ),
          FdRowWrap(alignment: WrapAlignment.center, children: [
            FdButton.secondary('Add a page', icon: FdIcons.plus, onPressed: _saving ? null : _addPage),
            FdButton.quiet('Retake page ${selected + 1}', icon: FdIcons.retry, onPressed: _saving ? null : () => _retake(selected)),
          ]),
        ],
      ),
    );
  }
}

/// 140×186 page thumbnail; the selected one gets the 3 px brand focus ring (offset 3).
class _Thumb extends StatelessWidget {
  const _Thumb({required this.bytes, required this.label, required this.selected, this.onTap});
  final Uint8List bytes;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Semantics(
      button: onTap != null,
      selected: selected,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(FdRadius.sm + 6),
              border: Border.all(color: selected ? c.brand : Colors.transparent, width: 3),
            ),
            child: Container(
              width: 140,
              height: 186,
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(FdRadius.sm),
                border: Border.all(color: c.lineSoft),
                boxShadow: c.shadowCard,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(FdRadius.sm - 1),
                child: Image.memory(bytes, fit: BoxFit.contain, cacheWidth: 420, gaplessPlayback: true, excludeFromSemantics: true),
              ),
            ),
          ),
          const SizedBox(height: FdSpace.s2 - 6),
          ExcludeSemantics(child: Text(label, style: FdType.meta.copyWith(color: c.inkSecondary))),
        ]),
      ),
    );
  }
}
