import 'package:flutter/material.dart';

import '../../core/icons.dart';
import '../../core/theme/fd_colors.dart';
import '../../core/theme/fd_tokens.dart';
import '../../core/theme/fd_typography.dart';
import 'basics.dart';

enum FdButtonKind { primary, secondary, quiet, danger }

/// .fd-btn. One primary per screen. Labels start with a verb.
class FdButton extends StatefulWidget {
  const FdButton(
    this.label, {
    super.key,
    this.onPressed,
    this.kind = FdButtonKind.primary,
    this.icon,
    this.block = false,
    this.loading = false,
    this.foreground,
    this.compact = false,
  });

  const FdButton.secondary(this.label, {super.key, this.onPressed, this.icon, this.block = false, this.loading = false, this.foreground, this.compact = false})
      : kind = FdButtonKind.secondary;

  const FdButton.quiet(this.label, {super.key, this.onPressed, this.icon, this.block = false, this.loading = false, this.foreground, this.compact = false})
      : kind = FdButtonKind.quiet;

  const FdButton.danger(this.label, {super.key, this.onPressed, this.icon, this.block = false, this.loading = false, this.foreground, this.compact = false})
      : kind = FdButtonKind.danger;

  final String label;
  final VoidCallback? onPressed;
  final FdButtonKind kind;
  final FdIcons? icon;

  /// Full width, 56 px tall, radius 16 (.fd-btn--block).
  final bool block;
  final bool loading;

  /// Override text color (e.g. danger-colored quiet/secondary buttons).
  final Color? foreground;

  /// 44 px min height instead of 48 (quiet buttons inside rows).
  final bool compact;

  @override
  State<FdButton> createState() => _FdButtonState();
}

class _FdButtonState extends State<FdButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final disabled = widget.onPressed == null && !widget.loading;
    final active = widget.onPressed != null && !widget.loading;

    Color bg;
    Color fg;
    Border? border;
    List<BoxShadow>? shadow;
    switch (widget.kind) {
      case FdButtonKind.primary:
        bg = _down ? c.brandPressed : c.brand;
        fg = c.onBrand;
        shadow = c.shadowButton;
      case FdButtonKind.secondary:
        bg = _down ? c.surfaceSunken : c.surface;
        fg = c.ink;
        border = Border.all(color: c.lineSoft);
        shadow = c.shadowCard;
      case FdButtonKind.quiet:
        bg = _down ? c.brandSoft : Colors.transparent;
        fg = c.brand;
      case FdButtonKind.danger:
        bg = _down ? c.surfaceSunken : c.surface;
        fg = c.danger;
        border = Border.all(color: c.lineSoft);
        shadow = c.shadowCard;
    }
    if (widget.foreground != null) fg = widget.foreground!;
    if (disabled) {
      bg = widget.kind == FdButtonKind.quiet ? Colors.transparent : c.surfacePressed;
      fg = c.inkTertiary;
      border = null;
      shadow = null;
    }

    final radius = BorderRadius.circular(widget.block ? FdRadius.lg : FdRadius.md);
    final height = widget.block ? FdSize.controlLg : (widget.compact ? FdSize.tapMin : FdSize.control);
    final hPad = widget.kind == FdButtonKind.quiet ? FdSpace.s3 : FdSpace.s5;

    final content = Row(
      mainAxisSize: widget.block ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.loading)
          Padding(padding: const EdgeInsets.only(right: FdSpace.s2), child: FdSpinner(size: 18, color: fg))
        else if (widget.icon != null)
          Padding(padding: const EdgeInsets.only(right: FdSpace.s2), child: FdIcon(widget.icon!, color: fg)),
        Flexible(
          child: Text(widget.label,
              style: FdType.label.copyWith(color: fg), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
        ),
      ],
    );

    return Semantics(
      button: true,
      enabled: active,
      child: GestureDetector(
        onTap: active ? widget.onPressed : null,
        onTapDown: active ? (_) => setState(() => _down = true) : null,
        onTapUp: active ? (_) => setState(() => _down = false) : null,
        onTapCancel: active ? () => setState(() => _down = false) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: BoxConstraints(minHeight: height),
          padding: EdgeInsets.symmetric(horizontal: hPad),
          decoration: BoxDecoration(color: bg, borderRadius: radius, border: border, boxShadow: shadow),
          child: content,
        ),
      ),
    );
  }
}

/// .fd-iconbtn — 44×44 round icon button. Always give a [semanticLabel].
class FdIconButton extends StatelessWidget {
  const FdIconButton(this.icon, {super.key, required this.semanticLabel, this.onPressed, this.brand = false, this.color, this.size = 20, this.bordered = false});
  final FdIcons icon;
  final String semanticLabel;
  final VoidCallback? onPressed;
  final bool brand;
  final Color? color;
  final double size;

  /// Outlined round check button on the Deadlines list.
  final bool bordered;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final fg = color ?? (brand ? c.onBrand : (bordered ? c.brand : c.ink));
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Tooltip(
        message: semanticLabel,
        excludeFromSemantics: true,
        child: FdPressable(
          onTap: onPressed,
          button: false,
          borderRadius: BorderRadius.circular(FdRadius.full),
          color: brand ? c.brand : Colors.transparent,
          pressedColor: brand ? c.brandPressed : c.surfaceSunken,
          child: Container(
            width: FdSize.tapMin,
            height: FdSize.tapMin,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: bordered ? Border.all(color: c.lineStrong, width: 1.5) : null,
              boxShadow: brand ? c.shadowButton : null,
            ),
            child: FdIcon(icon, size: size, color: fg),
          ),
        ),
      ),
    );
  }
}

/// .fd-chip (toggle).
class FdChip extends StatelessWidget {
  const FdChip(this.label, {super.key, this.selected = false, this.onTap, this.icon, this.multiline = false});
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final FdIcons? icon;

  /// Wraps text (suggestion chips in Ask).
  final bool multiline;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final fg = selected ? c.brand : c.ink;
    return Semantics(
      button: true,
      toggled: onTap == null ? null : selected,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: EdgeInsets.symmetric(horizontal: multiline ? FdSpace.s3 : FdSpace.s4, vertical: multiline ? FdSpace.s2 : 0),
          decoration: BoxDecoration(
            color: selected ? c.brandSoft : c.surface,
            borderRadius: BorderRadius.circular(multiline ? FdRadius.lg : FdRadius.full),
            border: Border.all(color: selected ? c.brand : c.lineStrong),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[FdIcon.sm(icon!, color: fg), const SizedBox(width: FdSpace.s1)],
            Flexible(
              child: Text(label,
                  softWrap: multiline,
                  style: FdType.chip.copyWith(color: fg, fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
            ),
          ]),
        ),
      ),
    );
  }
}

/// .fd-tab inside a horizontal .fd-tabs strip.
class FdTabs extends StatelessWidget {
  const FdTabs({super.key, required this.labels, required this.selected, required this.onSelect, this.counts = const {}});
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelect;
  final Map<int, int> counts;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(vertical: FdSpace.s1),
      child: Row(children: [
        for (var i = 0; i < labels.length; i++) ...[
          if (i > 0) const SizedBox(width: FdSpace.s1),
          Semantics(
            selected: i == selected,
            button: true,
            child: GestureDetector(
              onTap: () => onSelect(i),
              child: Container(
                height: FdSize.tapMin,
                padding: const EdgeInsets.symmetric(horizontal: FdSpace.s4),
                decoration: BoxDecoration(
                  color: i == selected ? c.brandSoft : Colors.transparent,
                  borderRadius: BorderRadius.circular(FdRadius.full),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(labels[i], style: FdType.chip.copyWith(fontWeight: FontWeight.w600, color: i == selected ? c.brand : c.inkSecondary)),
                  if (counts[i] != null) ...[const SizedBox(width: FdSpace.s2), FdCount(counts[i]!)],
                ]),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

/// .fd-count
class FdCount extends StatelessWidget {
  const FdCount(this.n, {super.key, this.alert = false});
  final int n;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: alert ? c.danger : c.surfacePressed, borderRadius: BorderRadius.circular(FdRadius.full)),
      child: Text('$n', style: FdType.badge.copyWith(fontSize: 12, height: 20 / 12, color: alert ? c.onDanger : c.ink)),
    );
  }
}
