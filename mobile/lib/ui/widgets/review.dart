import 'package:flutter/material.dart';

import '../../core/icons.dart';
import '../../core/theme/fd_colors.dart';
import '../../core/theme/fd_tokens.dart';
import '../../core/theme/fd_typography.dart';

/// .fd-fields — card of label/value rows, optional head note.
class FdFields extends StatelessWidget {
  const FdFields({super.key, required this.rows, this.head});
  final List<Widget> rows;
  final String? head;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final children = <Widget>[];
    if (head != null) {
      children.add(Container(
        padding: const EdgeInsets.symmetric(horizontal: FdSpace.s4, vertical: FdSpace.s3),
        decoration: BoxDecoration(color: c.source, border: Border(bottom: BorderSide(color: c.line))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: FdIcon(FdIcons.sparkle, color: c.brand)),
          const SizedBox(width: FdSpace.s2),
          Expanded(child: Text(head!, style: FdType.meta.copyWith(color: c.inkSecondary))),
        ]),
      ));
    }
    for (final r in rows) {
      if (children.isNotEmpty && !(head != null && children.length == 1)) {
        children.add(Container(height: 1, color: c.line));
      }
      children.add(r);
    }
    final radius = BorderRadius.circular(FdRadius.lg);
    return Container(
      decoration: BoxDecoration(color: c.surface, borderRadius: radius, border: Border.all(color: c.lineSoft), boxShadow: c.shadowCard),
      child: ClipRRect(borderRadius: radius, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)),
    );
  }
}

/// .fd-fieldrow — label over value, trailing actions.
class FdFieldRow extends StatelessWidget {
  const FdFieldRow({super.key, required this.label, required this.value, this.missing = false, this.trailing});
  final String label;
  final String value;
  final bool missing;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: FdSpace.s4, vertical: trailing == null ? FdSpace.s3 : FdSpace.s2),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: FdType.meta.copyWith(color: c.inkSecondary)),
            const SizedBox(height: 2),
            Text(
              value,
              style: missing
                  ? FdType.body.copyWith(color: c.inkTertiary, fontStyle: FontStyle.italic)
                  : FdType.body.copyWith(fontFeatures: FdType.tnum),
            ),
          ]),
        ),
        if (trailing != null) ...[const SizedBox(width: FdSpace.s3), trailing!],
      ]),
    );
  }
}

/// .fd-ai — "Filled in by AI" mark.
class FdAiMark extends StatelessWidget {
  const FdAiMark({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Tooltip(
      message: 'Filled in by AI',
      child: Semantics(
        label: 'Filled in by AI',
        child: Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: c.brandSoft, shape: BoxShape.circle),
          child: FdIcon.sm(FdIcons.sparkle, color: c.brand),
        ),
      ),
    );
  }
}

/// .fd-tag--edited
class FdEditedTag extends StatelessWidget {
  const FdEditedTag({super.key});
  @override
  Widget build(BuildContext context) => Text('Edited', style: FdType.overline.copyWith(color: context.fd.inkSecondary));
}

/// One numbered step of the deadline calculation (.fd-step).
class FdStep extends StatelessWidget {
  const FdStep({super.key, required this.marker, required this.child, this.last = false, this.result = false});
  final String marker;
  final Widget child;
  final bool last;
  final bool result;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 28,
          child: Column(children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(shape: BoxShape.circle, color: result ? c.brand : c.surfaceSunken),
              child: result
                  ? FdIcon.sm(FdIcons.check, color: c.onBrand)
                  : Text(marker, style: FdType.badge.copyWith(fontSize: 13, color: c.inkSecondary)),
            ),
            if (!last)
              Expanded(child: Container(width: 2, margin: const EdgeInsets.only(top: 0, bottom: 4), color: c.line)),
          ]),
        ),
        const SizedBox(width: FdSpace.s3),
        Expanded(child: Padding(padding: EdgeInsets.only(bottom: last ? 0 : FdSpace.s4, top: 2), child: child)),
      ]),
    );
  }
}

/// .fd-quote — source quote with left brand rule; [highlight] is marked.
class FdQuote extends StatelessWidget {
  const FdQuote({super.key, required this.text, this.highlight});
  final String text;
  final String? highlight;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final base = FdType.body.copyWith(color: c.ink);
    InlineSpan span;
    final h = highlight;
    final i = h == null || h.isEmpty ? -1 : text.toLowerCase().indexOf(h.toLowerCase());
    if (i < 0) {
      span = TextSpan(text: '“$text”', style: base);
    } else {
      span = TextSpan(style: base, children: [
        TextSpan(text: '“${text.substring(0, i)}'),
        TextSpan(text: text.substring(i, i + h!.length), style: TextStyle(backgroundColor: c.warningSoft)),
        TextSpan(text: '${text.substring(i + h.length)}”'),
      ]);
    }
    return Container(
      margin: const EdgeInsets.only(top: FdSpace.s2),
      padding: const EdgeInsets.symmetric(horizontal: FdSpace.s4, vertical: FdSpace.s3),
      decoration: BoxDecoration(
        color: c.source,
        border: Border(left: BorderSide(color: c.brand, width: 3)),
        borderRadius: const BorderRadius.only(topRight: Radius.circular(FdRadius.md), bottomRight: Radius.circular(FdRadius.md)),
      ),
      child: Text.rich(span),
    );
  }
}
