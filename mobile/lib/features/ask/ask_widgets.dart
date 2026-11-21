import 'package:flutter/material.dart';

import '../../ui/fd.dart';

/// .fd-bubble-user — the question, right-aligned on a sunken bubble.
class AskUserBubble extends StatelessWidget {
  const AskUserBubble(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Align(
      alignment: Alignment.centerRight,
      child: FractionallySizedBox(
        widthFactor: .8,
        alignment: Alignment.centerRight,
        child: Align(
          alignment: Alignment.centerRight,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: FdSpace.s4, vertical: FdSpace.s3),
            decoration: BoxDecoration(
              color: c.surfaceSunken,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(FdRadius.lg),
                topRight: Radius.circular(FdRadius.lg),
                bottomRight: Radius.circular(FdRadius.sm),
                bottomLeft: Radius.circular(FdRadius.lg),
              ),
            ),
            child: Text(text, style: FdType.body.copyWith(color: c.ink)),
          ),
        ),
      ),
    );
  }
}

/// .fd-answer — "FamilyDoc" header and the answer content, up to 92% wide.
class AskAnswer extends StatelessWidget {
  const AskAnswer({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Align(
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: .92,
        alignment: Alignment.centerLeft,
        child: Semantics(
          liveRegion: true,
          child: FdGapColumn(
            gap: FdSpace.s3,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                FdIcon.sm(FdIcons.sparkle, color: c.brand),
                const SizedBox(width: FdSpace.s1),
                Text('FamilyDoc', style: FdType.overline.copyWith(color: c.brand)),
              ]),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// Spinner + "Looking through …".
class AskThinking extends StatelessWidget {
  const AskThinking(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 4), child: FdSpinner(size: 16, color: c.inkSecondary)),
      const SizedBox(width: FdSpace.s2),
      Flexible(child: Text(text, style: FdType.body.copyWith(color: c.inkSecondary))),
    ]);
  }
}

/// .fd-source — file icon, document name and a short quote. Tap opens the document.
class AskSourceChip extends StatelessWidget {
  const AskSourceChip({super.key, required this.name, this.quote, this.onTap});
  final String name;
  final String? quote;
  final VoidCallback? onTap;

  static String _snippet(String q) {
    final s = q.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.length <= 36 ? '“$s”' : '“${s.substring(0, 35).trimRight()}…”';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final q = quote?.trim();
    return Semantics(
      button: onTap != null,
      label: 'Source: $name',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: FdSpace.s3, vertical: FdSpace.s2),
          decoration: BoxDecoration(
            color: c.source,
            borderRadius: BorderRadius.circular(FdRadius.sm),
            border: Border.all(color: c.line),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            FdIcon.sm(FdIcons.file, color: c.ink),
            const SizedBox(width: FdSpace.s2),
            Flexible(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: name),
                  if (q != null && q.isNotEmpty)
                    TextSpan(text: ' ${_snippet(q)}', style: TextStyle(color: c.inkSecondary, fontWeight: FontWeight.w400)),
                ]),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: FdType.meta.copyWith(color: c.ink, fontWeight: FontWeight.w500),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
