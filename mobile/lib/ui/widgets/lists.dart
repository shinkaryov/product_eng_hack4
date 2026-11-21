import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/icons.dart';
import '../../core/theme/fd_colors.dart';
import '../../core/theme/fd_tokens.dart';
import '../../core/theme/fd_typography.dart';
import 'basics.dart';

/// .fd-list — white rounded container; rows separated by 1 px lines.
class FdList extends StatelessWidget {
  const FdList({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final rows = <Widget>[];
    for (final r in children) {
      if (rows.isNotEmpty) rows.add(Container(height: 1, color: c.line));
      rows.add(r);
    }
    final radius = BorderRadius.circular(FdRadius.lg);
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: radius,
        border: Border.all(color: c.lineSoft),
        boxShadow: c.shadowCard,
      ),
      child: ClipRRect(borderRadius: radius, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: rows)),
    );
  }
}

/// .fd-listrow — leading (well, avatar, date tile), title + meta, trailing.
class FdListRow extends StatelessWidget {
  const FdListRow({
    super.key,
    required this.title,
    this.meta,
    this.leading,
    this.trailing,
    this.onTap,
    this.titleColor,
    this.metaWraps = false,
    this.background,
    this.chevron = false,
  });

  final String title;
  final String? meta;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? titleColor;
  final bool metaWraps;
  final Color? background;

  /// Adds a trailing chevron after [trailing].
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final row = Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(horizontal: FdSpace.s4, vertical: FdSpace.s3),
      child: Row(children: [
        if (leading != null) ...[leading!, const SizedBox(width: FdSpace.s3)],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: FdType.listTitle.copyWith(color: titleColor ?? c.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
            if (meta != null && meta!.isNotEmpty)
              Text(meta!,
                  style: FdType.meta.copyWith(color: c.inkSecondary),
                  maxLines: metaWraps ? null : 1,
                  overflow: metaWraps ? null : TextOverflow.ellipsis),
          ]),
        ),
        if (trailing != null) ...[const SizedBox(width: FdSpace.s3), trailing!],
        if (chevron) ...[const SizedBox(width: FdSpace.s2), FdIcon(FdIcons.chevronRight, color: c.inkTertiary)],
      ]),
    );
    return FdPressable(onTap: onTap, color: background ?? c.surface, child: row);
  }
}

enum FdBadgeKind { overdue, soon, upcoming, ok, neutral, review, failed }

/// .fd-badge — status is always icon + word.
class FdBadge extends StatelessWidget {
  const FdBadge(this.label, {super.key, this.kind = FdBadgeKind.neutral, this.icon, this.spinning = false});
  final String label;
  final FdBadgeKind kind;
  final FdIcons? icon;

  /// Spinner instead of [icon] ("Reading").
  final bool spinning;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final (bg, fg) = switch (kind) {
      FdBadgeKind.overdue || FdBadgeKind.failed => (c.dangerSoft, c.danger),
      FdBadgeKind.soon => (c.warningSoft, c.warning),
      FdBadgeKind.upcoming => (c.infoSoft, c.info),
      FdBadgeKind.ok => (c.successSoft, c.success),
      FdBadgeKind.neutral => (c.surfaceSunken, c.inkSecondary),
      FdBadgeKind.review => (c.brand, c.onBrand),
    };
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(FdRadius.full)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (spinning)
          Padding(padding: const EdgeInsets.only(right: FdSpace.s1), child: FdSpinner(size: 16, color: fg))
        else if (icon != null)
          Padding(padding: const EdgeInsets.only(right: FdSpace.s1), child: FdIcon.sm(icon!, color: fg)),
        Text(label, style: FdType.badge.copyWith(color: fg)),
      ]),
    );
  }

  /// Badge for a deadline N days away: overdue <0, soon ≤30, upcoming otherwise.
  factory FdBadge.days(int n, {String? overdueLabel}) {
    if (n < 0) return FdBadge(overdueLabel ?? 'Expired', kind: FdBadgeKind.overdue, icon: FdIcons.xCircle);
    if (n <= 30) return FdBadge(daysLabel(n), kind: FdBadgeKind.soon, icon: FdIcons.alert);
    return FdBadge(daysLabel(n), kind: FdBadgeKind.upcoming, icon: FdIcons.clock);
  }
}

enum FdDateTone { normal, soon, overdue }

/// .fd-datetile — big day number + month.
class FdDateTile extends StatelessWidget {
  const FdDateTile(this.date, {super.key, this.tone = FdDateTone.normal});
  final DateTime date;
  final FdDateTone tone;

  factory FdDateTile.forDays(DateTime date, int days) =>
      FdDateTile(date, tone: days < 0 ? FdDateTone.overdue : days <= 30 ? FdDateTone.soon : FdDateTone.normal);

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final (border, bg, dayColor, monthColor) = switch (tone) {
      FdDateTone.overdue => (c.danger, c.dangerSoft, c.danger, c.danger),
      FdDateTone.soon => (c.warning, c.warningSoft, c.warning, c.inkSecondary),
      FdDateTone.normal => (c.line, c.surface, c.ink, c.inkSecondary),
    };
    return Container(
      width: 52,
      constraints: const BoxConstraints(minHeight: 58),
      decoration: BoxDecoration(color: bg, border: Border.all(color: border), borderRadius: BorderRadius.circular(FdRadius.md)),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
        Text('${date.day}', style: FdType.figure.copyWith(color: dayColor)),
        Text(formatMonth(date), style: FdType.meta.copyWith(fontSize: 14, height: 18 / 14, color: monthColor)),
      ]),
    );
  }
}

enum FdNoticeKind { info, danger, neutral }

/// .fd-notice
class FdNotice extends StatelessWidget {
  const FdNotice({super.key, required this.child, this.kind = FdNoticeKind.neutral, this.icon});

  FdNotice.text(String text, {super.key, this.kind = FdNoticeKind.neutral, this.icon}) : child = Text(text);

  final Widget child;
  final FdNoticeKind kind;
  final FdIcons? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final (bg, iconColor) = switch (kind) {
      FdNoticeKind.info => (c.infoSoft, c.info),
      FdNoticeKind.danger => (c.dangerSoft, c.danger),
      FdNoticeKind.neutral => (c.surfaceSunken, c.ink),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: FdSpace.s4, vertical: FdSpace.s3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(FdRadius.md)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (icon != null) ...[
          Padding(padding: const EdgeInsets.only(top: 2), child: FdIcon(icon!, color: iconColor)),
          const SizedBox(width: FdSpace.s3),
        ],
        Expanded(child: DefaultTextStyle.merge(style: FdType.body.copyWith(color: c.ink), child: child)),
      ]),
    );
  }
}

enum FdStatusKind { ok, attention, overdue }

/// .fd-status — the one-sentence Home status (compact row) or a big centered status.
class FdStatus extends StatelessWidget {
  const FdStatus({super.key, required this.kind, required this.title, this.subtitle, this.compact = true, this.icon, this.titleStyle});
  final FdStatusKind kind;
  final String title;
  final String? subtitle;
  final bool compact;
  final FdIcons? icon;
  final TextStyle? titleStyle;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final (bg, fg, defIcon) = switch (kind) {
      FdStatusKind.ok => (c.successSoft, c.success, FdIcons.checkCircle),
      FdStatusKind.attention => (c.warningSoft, c.warningMark, FdIcons.alert),
      FdStatusKind.overdue => (c.dangerSoft, c.danger, FdIcons.xCircle),
    };
    final size = compact ? 40.0 : 44.0;
    final circle = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
      child: FdIcon(icon ?? defIcon, size: compact ? 20 : 24, color: fg),
    );
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Semantics(header: true, child: Text(title, style: titleStyle ?? (compact ? FdType.lead : FdType.display))),
      if (subtitle != null) ...[
        SizedBox(height: compact ? 2 : FdSpace.s3),
        Text(subtitle!, style: (compact ? FdType.meta : FdType.callout).copyWith(color: c.inkSecondary)),
      ],
    ]);
    if (compact) {
      return Row(children: [circle, const SizedBox(width: FdSpace.s3), Expanded(child: text)]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [circle, const SizedBox(height: FdSpace.s3), text]);
  }
}

/// .fd-suggest — brand-soft strip with sparkle.
class FdSuggest extends StatelessWidget {
  const FdSuggest({super.key, required this.label, required this.value, this.trailing, this.onTap, this.chevron = false});
  final String label;
  final String value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return FdPressable(
      onTap: onTap,
      color: c.brandSoft,
      pressedColor: c.brandSoft.withValues(alpha: .7),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: FdSpace.s4, vertical: FdSpace.s3),
        child: Row(children: [
          FdIcon(FdIcons.sparkle, color: c.brand),
          const SizedBox(width: FdSpace.s3),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: FdType.meta.copyWith(color: c.inkSecondary)),
              Text(value, style: FdType.bodyStrong),
            ]),
          ),
          if (trailing != null) trailing!,
          if (chevron) FdIcon(FdIcons.chevronRight, color: c.brand),
        ]),
      ),
    );
  }
}

/// .fd-tile — category tile. [compact] = the 3-column Home grid.
class FdTile extends StatelessWidget {
  const FdTile({
    super.key,
    required this.icon,
    required this.name,
    this.count,
    this.flag,
    this.flagOverdue = false,
    this.flagIcon,
    this.empty = false,
    this.onTap,
  });

  final FdIcons icon;
  final String name;
  final int? count;
  final String? flag;
  final bool flagOverdue;
  final FdIcons? flagIcon;
  final bool empty;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    final radius = BorderRadius.circular(FdRadius.lg);
    final flagColor = flagOverdue ? c.danger : c.warning;
    final content = Padding(
      padding: const EdgeInsets.all(FdSpace.s3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(color: empty ? c.surface : c.brandSoft, borderRadius: BorderRadius.circular(FdRadius.md)),
            child: FdIcon.lg(icon, color: c.brand),
          ),
          const Spacer(),
          if (count != null) Text('$count', style: FdType.meta.copyWith(color: c.inkSecondary, fontFeatures: FdType.tnum)),
        ]),
        const SizedBox(height: FdSpace.s3),
        Text(name, style: FdType.listTitle.copyWith(fontSize: 15, height: 20 / 15), maxLines: 2, overflow: TextOverflow.ellipsis),
        if (flag != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              FdIcon(flagIcon ?? (flagOverdue ? FdIcons.xCircle : FdIcons.alert), size: 14, color: flagColor),
              const SizedBox(width: FdSpace.s1),
              Flexible(child: Text(flag!, style: FdType.overline.copyWith(fontSize: 13, height: 18 / 13, color: flagColor), maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),
          ),
      ]),
    );
    return Container(
      decoration: BoxDecoration(
        color: empty ? Colors.transparent : c.surface,
        borderRadius: radius,
        border: empty ? Border.all(color: c.line, width: 1.5) : Border.all(color: c.lineSoft),
        boxShadow: empty ? null : c.shadowCard,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: FdPressable(onTap: onTap, pressedColor: c.source, child: content),
      ),
    );
  }
}

/// 3-column tile grid (.fd-tiles--3) with rows of equal height.
class FdTileGrid extends StatelessWidget {
  const FdTileGrid({super.key, required this.children, this.columns = 3, this.gap = 10});
  final List<Widget> children;
  final int columns;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += columns) {
      final cells = <Widget>[];
      for (var j = 0; j < columns; j++) {
        if (j > 0) cells.add(SizedBox(width: gap));
        cells.add(Expanded(child: i + j < children.length ? children[i + j] : const SizedBox()));
      }
      if (rows.isNotEmpty) rows.add(SizedBox(height: gap));
      rows.add(IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: cells)));
    }
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }
}
