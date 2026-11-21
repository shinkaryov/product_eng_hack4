import 'package:flutter/material.dart';

import '../../core/icons.dart';
import '../../core/theme/fd_colors.dart';
import '../../core/theme/fd_tokens.dart';
import '../../core/theme/fd_typography.dart';

/// Column with a fixed gap between children (CSS flex + gap).
class FdGapColumn extends StatelessWidget {
  const FdGapColumn({
    super.key,
    required this.children,
    this.gap = FdSpace.s4,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
  });

  final List<Widget> children;
  final double gap;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    final out = <Widget>[];
    for (final c in children) {
      if (out.isNotEmpty) out.add(SizedBox(height: gap));
      out.add(c);
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: crossAxisAlignment, children: out);
  }
}

/// Wrap row with a gap (CSS .fd-row).
class FdRowWrap extends StatelessWidget {
  const FdRowWrap({super.key, required this.children, this.gap = FdSpace.s3, this.alignment = WrapAlignment.start});
  final List<Widget> children;
  final double gap;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: gap,
        runSpacing: gap,
        alignment: alignment,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: children,
      );
}

/// Pressable surface with the design's pressed state (fill one step darker, no ripple).
class FdPressable extends StatefulWidget {
  const FdPressable({
    super.key,
    required this.child,
    this.onTap,
    this.color,
    this.pressedColor,
    this.borderRadius,
    this.semanticLabel,
    this.button = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final Color? color;
  final Color? pressedColor;
  final BorderRadius? borderRadius;
  final String? semanticLabel;
  final bool button;

  @override
  State<FdPressable> createState() => _FdPressableState();
}

class _FdPressableState extends State<FdPressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final enabled = widget.onTap != null;
    final bg = enabled && _down ? (widget.pressedColor ?? c.surfaceSunken) : widget.color;
    return Semantics(
      button: widget.button && enabled,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: enabled ? (_) => setState(() => _down = false) : null,
        onTapCancel: enabled ? () => setState(() => _down = false) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: const Cubic(.2, 0, 0, 1),
          decoration: BoxDecoration(color: bg, borderRadius: widget.borderRadius),
          child: widget.child,
        ),
      ),
    );
  }
}

/// .fd-card
class FdCard extends StatelessWidget {
  const FdCard({super.key, required this.child, this.padding, this.color, this.borderColor, this.onTap, this.shadow = true});

  /// Use [FdCard.pad] for the standard 16 px padding.
  const FdCard.pad({super.key, required this.child, this.color, this.borderColor, this.onTap, this.shadow = true})
      : padding = const EdgeInsets.all(FdSpace.s4);

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final Color? color;
  final Color? borderColor;
  final VoidCallback? onTap;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final radius = BorderRadius.circular(FdRadius.lg);
    Widget inner = Padding(padding: padding ?? EdgeInsets.zero, child: child);
    if (onTap != null) {
      inner = FdPressable(
        onTap: onTap,
        borderRadius: radius,
        pressedColor: c.source,
        child: inner,
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: color ?? c.surface,
        borderRadius: radius,
        border: Border.all(color: borderColor ?? c.lineSoft),
        boxShadow: shadow ? c.shadowCard : null,
      ),
      child: ClipRRect(borderRadius: radius, child: inner),
    );
  }
}

/// .fd-well — 40×40 tinted icon box.
class FdWell extends StatelessWidget {
  const FdWell(this.icon, {super.key, this.size = 40, this.radius = FdRadius.md, this.background, this.foreground, this.iconSize = 20});
  final FdIcons icon;
  final double size;
  final double radius;
  final Color? background;
  final Color? foreground;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: background ?? c.brandSoft, borderRadius: BorderRadius.circular(radius)),
      child: FdIcon(icon, size: iconSize, color: foreground ?? c.brand),
    );
  }
}

/// .fd-avatar
class FdAvatar extends StatelessWidget {
  const FdAvatar(this.initials, {super.key, this.size = 40, this.neutral = false, this.dot = false, this.onTap, this.semanticLabel});
  final String initials;
  final double size;
  final bool neutral;
  final bool dot;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final fontSize = size >= 72 ? 24.0 : size >= 56 ? 18.0 : 15.0;
    Widget w = Stack(clipBehavior: Clip.none, children: [
      Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(shape: BoxShape.circle, color: neutral ? c.surfaceSunken : c.brandSoft),
        child: Text(initials,
            style: FdType.label.copyWith(fontSize: fontSize, color: neutral ? c.inkSecondary : c.brand)),
      ),
      if (dot)
        Positioned(
          right: -3,
          bottom: -3,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(shape: BoxShape.circle, color: c.warningMark, border: Border.all(color: c.surface, width: 2)),
          ),
        ),
    ]);
    if (onTap != null) {
      w = Semantics(
        button: true,
        label: semanticLabel,
        child: GestureDetector(onTap: onTap, behavior: HitTestBehavior.opaque, child: SizedBox(width: 44, height: 44, child: Center(child: w))),
      );
    }
    return w;
  }
}

/// Section heading (h2.section).
class FdSectionTitle extends StatelessWidget {
  const FdSectionTitle(this.text, {super.key, this.topGap = 0});
  final String text;
  final double topGap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(top: topGap),
        child: Semantics(header: true, child: Text(text, style: FdType.section)),
      );
}

/// Small grey group label (h2.meta, weight 600) used on Household.
class FdGroupLabel extends StatelessWidget {
  const FdGroupLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
        header: true,
        child: Text(text, style: FdType.overline.copyWith(color: context.fd.inkSecondary)),
      );
}

/// .fd-divider
class FdDivider extends StatelessWidget {
  const FdDivider({super.key});
  @override
  Widget build(BuildContext context) => Container(height: 1, color: context.fd.line);
}

/// .fd-progress
class FdProgress extends StatelessWidget {
  const FdProgress({super.key, required this.value});
  final double value;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Semantics(
      value: '${(value * 100).round()}%',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(FdRadius.full),
        child: SizedBox(
          height: 6,
          child: Stack(children: [
            Positioned.fill(child: ColoredBox(color: c.surfacePressed)),
            FractionallySizedBox(
              widthFactor: value.clamp(0, 1),
              child: DecoratedBox(
                decoration: BoxDecoration(color: c.brand, borderRadius: BorderRadius.circular(FdRadius.full)),
                child: const SizedBox.expand(),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Rotating spinner glyph (.fd-spin).
class FdSpinner extends StatefulWidget {
  const FdSpinner({super.key, this.size = 16, this.color});
  final double size;
  final Color? color;

  @override
  State<FdSpinner> createState() => _FdSpinnerState();
}

class _FdSpinnerState extends State<FdSpinner> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) {
      return FdIcon(FdIcons.spinner, size: widget.size, color: widget.color);
    }
    return RotationTransition(turns: _c, child: FdIcon(FdIcons.spinner, size: widget.size, color: widget.color));
  }
}
