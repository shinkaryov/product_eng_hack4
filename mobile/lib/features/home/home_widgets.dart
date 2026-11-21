import 'package:flutter/material.dart';

import '../../ui/fd.dart';

/// .fd-topbar — household name with chevron on the left, avatar on the right.
class HomeTopBar extends StatelessWidget {
  const HomeTopBar({super.key, required this.title, required this.initials, required this.onTitle, required this.onAvatar, required this.avatarLabel});
  final String? title;
  final String initials;
  final VoidCallback onTitle;
  final VoidCallback onAvatar;
  final String avatarLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: FdSize.tapMin),
      child: Row(children: [
        Expanded(
          child: title == null
              ? const SizedBox()
              : Align(
                  alignment: Alignment.centerLeft,
                  child: Semantics(
                    button: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onTitle,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: FdSize.tapMin),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Flexible(
                            child: Text(title!, style: FdType.household.copyWith(color: c.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                          const SizedBox(width: FdSpace.s2),
                          FdIcon.sm(FdIcons.chevronRight, color: c.ink),
                        ]),
                      ),
                    ),
                  ),
                ),
        ),
        const SizedBox(width: FdSpace.s3),
        FdAvatar(initials, onTap: onAvatar, semanticLabel: avatarLabel),
      ]),
    );
  }
}

/// .fd-hero — the most urgent deadline: date tile, eyebrow + days badge, title, meta, actions.
class HomeHero extends StatelessWidget {
  const HomeHero({
    super.key,
    required this.date,
    required this.days,
    required this.eyebrow,
    required this.title,
    required this.meta,
    required this.onDone,
    required this.onView,
  });

  final DateTime date;
  final int days;
  final String eyebrow;
  final String title;
  final String meta;
  final VoidCallback onDone;
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Semantics(
      container: true,
      label: 'Most urgent deadline',
      child: Container(
        padding: const EdgeInsets.all(FdSpace.s4),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(FdRadius.lg),
          border: Border.all(color: c.lineSoft),
          boxShadow: c.shadowRaised,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            FdDateTile.forDays(date, days),
            const SizedBox(width: FdSpace.s3),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(children: [
                    Expanded(child: Text(eyebrow, style: FdType.meta.copyWith(color: c.inkSecondary))),
                    const SizedBox(width: FdSpace.s2),
                    FdBadge.days(days),
                  ]),
                ),
                const SizedBox(height: 2),
                Text(title, style: FdType.headline.copyWith(color: c.ink)),
                const SizedBox(height: 2),
                Text(meta, style: FdType.meta.copyWith(color: c.inkSecondary)),
              ]),
            ),
          ]),
          const SizedBox(height: FdSpace.s4),
          Wrap(spacing: FdSpace.s2, runSpacing: FdSpace.s2, children: [
            FdButton('Mark as done', onPressed: onDone),
            FdButton.secondary('View document', onPressed: onView),
          ]),
        ]),
      ),
    );
  }
}

/// Brand-soft (or plain) card row: well + title/meta + chevron. Ask card and Invite card.
class HomeCardLink extends StatelessWidget {
  const HomeCardLink({super.key, required this.icon, required this.title, required this.meta, required this.onTap, this.brand = false});
  final FdIcons icon;
  final String title;
  final String meta;
  final VoidCallback onTap;
  final bool brand;

  @override
  Widget build(BuildContext context) {
    final c = context.fd;
    return Semantics(
      button: true,
      label: '$title. $meta',
      excludeSemantics: true,
      child: FdCard.pad(
        color: brand ? c.brandSoft : null,
        borderColor: brand ? Colors.transparent : null,
        onTap: onTap,
        child: Row(children: [
          FdWell(icon, background: brand ? c.surface : null),
          const SizedBox(width: FdSpace.s3),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: FdType.bodyStrong.copyWith(color: c.ink)),
              Text(meta, style: FdType.meta.copyWith(color: c.inkSecondary)),
            ]),
          ),
          const SizedBox(width: FdSpace.s3),
          FdIcon(FdIcons.chevronRight, color: c.ink),
        ]),
      ),
    );
  }
}
