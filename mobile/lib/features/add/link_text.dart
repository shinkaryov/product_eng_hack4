import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../ui/fd.dart';

/// Sentence followed by an inline brand link ("… What we store").
class InlineLinkText extends StatefulWidget {
  const InlineLinkText({super.key, required this.text, required this.link, required this.onTap, this.style});
  final String text;
  final String link;
  final VoidCallback onTap;
  final TextStyle? style;

  @override
  State<InlineLinkText> createState() => _InlineLinkTextState();
}

class _InlineLinkTextState extends State<InlineLinkText> {
  late final _tap = TapGestureRecognizer()..onTap = () => widget.onTap();

  @override
  void dispose() {
    _tap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final base = widget.style ?? DefaultTextStyle.of(context).style;
    return Semantics(
      link: true,
      onTap: widget.onTap,
      child: Text.rich(
        TextSpan(style: base, children: [
          TextSpan(text: '${widget.text} '),
          TextSpan(
            text: widget.link,
            recognizer: _tap,
            style: base.copyWith(color: c.brand, decoration: TextDecoration.underline, decorationColor: c.brand),
          ),
        ]),
      ),
    );
  }
}
