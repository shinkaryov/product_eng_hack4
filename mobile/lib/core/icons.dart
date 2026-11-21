import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Stroke icons copied 1:1 from the design canvas (24-unit glyphs,
/// `stroke-width` 1.75, round caps). Render with [FdIcon].
enum FdIcons {
  scan('<path d="M4 8V5h3M17 5h3v3M20 16v3h-3M7 19H4v-3"/><path d="M4 12h16"/>'),
  upload('<path d="M12 15V4M7 9l5-5 5 5"/><path d="M5 15v4h14v-4"/>'),
  lock('<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>'),
  back('<path d="m15 6-6 6 6 6"/>'),
  chevronRight('<path d="m9 6 6 6-6 6"/>'),
  sparkle('<path d="M12 3c.6 4.4 1.6 5.4 6 6-4.4.6-5.4 1.6-6 6-.6-4.4-1.6-5.4-6-6 4.4-.6 5.4-1.6 6-6z"/><path d="M19 15c.3 1.8.7 2.2 2.5 2.5-1.8.3-2.2.7-2.5 2.5-.3-1.8-.7-2.2-2.5-2.5 1.8-.3 2.2-.7 2.5-2.5z"/>'),
  file('<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/>'),
  search('<circle cx="11" cy="11" r="6"/><path d="m20 20-4.5-4.5"/>'),
  send('<path d="M5 12h13M13 6l6 6-6 6"/>'),
  shieldCheck('<path d="M12 3 5 6v5c0 4.5 3 8 7 10 4-2 7-5.5 7-10V6z"/><path d="m9 12 2 2 4-4"/>'),
  checkCircle('<circle cx="12" cy="12" r="9"/><path d="m8 12 3 3 5-6"/>'),
  check('<path d="m5 12 5 5 9-10"/>'),
  bell('<path d="M6 16v-5a6 6 0 0 1 12 0v5l2 2H4z"/><path d="M10 20a2 2 0 0 0 4 0"/>'),
  home('<path d="M4 11 12 4l8 7"/><path d="M6 10v10h12V10"/><path d="M10 20v-5h4v5"/>'),
  grid('<rect x="4" y="4" width="7" height="7" rx="1.5"/><rect x="13" y="4" width="7" height="7" rx="1.5"/><rect x="4" y="13" width="7" height="7" rx="1.5"/><rect x="13" y="13" width="7" height="7" rx="1.5"/>'),
  plus('<path d="M12 5v14M5 12h14"/>'),
  calendar('<rect x="4" y="5" width="16" height="15" rx="2"/><path d="M4 10h16M9 3v4M15 3v4"/>'),
  chat('<path d="M4 5h16v11H9l-5 4z"/>'),
  link('<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>'),
  clock('<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>'),
  copy('<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V5a1 1 0 0 0-1-1H5a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h3"/>'),
  umbrella('<path d="M3 12a9 9 0 0 1 18 0z"/><path d="M12 12v6a2 2 0 0 1-4 0"/>'),
  xCircle('<circle cx="12" cy="12" r="9"/><path d="m9 9 6 6M15 9l-6 6"/>'),
  alert('<path d="M12 4 2.5 20h19z"/><path d="M12 10v4M12 17h.01"/>'),
  retry('<path d="M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7"/>'),
  pencil('<path d="M4 20h4L19 9l-4-4L4 16z"/>'),
  idCard('<rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="9" cy="11" r="2"/><path d="M6 16c.6-1.4 1.7-2 3-2s2.4.6 3 2M14 10h4M14 13h3"/>'),
  car('<path d="M5 16v-4l2-5h10l2 5v4"/><path d="M3 12h18v5H3z"/><path d="M6 17v2M18 17v2"/>'),
  receipt('<path d="M6 3h12v18l-3-2-3 2-3-2-3 2z"/><path d="M9 8h6M9 12h6"/>'),
  people('<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20c1.2-3.3 3.6-4.8 6.5-4.8s5.3 1.5 6.5 4.8"/><path d="M16 4.6a3.5 3.5 0 0 1 0 6.8M18 15.5c1.6.6 2.8 2 3.5 4.5"/>'),
  more('<path d="M5 12h.01M12 12h.01M19 12h.01"/>'),
  eyeOff('<path d="m3 3 18 18"/><path d="M10.6 6.1A9.7 9.7 0 0 1 12 6c5 0 8.5 4 9.5 6a13 13 0 0 1-2.6 3.3M6.6 7.6C4.6 8.9 3.2 10.6 2.5 12c1 2 4.5 6 9.5 6 1.6 0 3-.4 4.3-1"/>'),
  spinner('<path d="M12 3a9 9 0 1 0 9 9"/>'),
  close('<path d="M6 6l12 12M18 6 6 18"/>'),
  mail('<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 7 9 6 9-6"/>'),
  logo('<rect x="3" y="2" width="8" height="12" rx="1"/><path d="M11 4h3v3h-3m0 3h3v3h-3"/>'),
  plane('<path d="M10.5 13.5 4 12l-1 1.5 6 3 3 6 1.5-1-1.5-6.5 4-4c1.5-1.5 2.5-3.5 2-4.5-1-.5-3 .5-4.5 2z"/>'),
  ban('<circle cx="12" cy="12" r="9"/><path d="m5.6 5.6 12.8 12.8"/>'),
  bolt('<path d="M13 3 5 14h6l-1 7 8-11h-6z"/>'),
  trash('<path d="M4 7h16M10 11v6M14 11v6"/><path d="M6 7l1 13h10l1-13M9 7V4h6v3"/>'),
  logout('<path d="M15 4h4v16h-4"/><path d="M10 8l-4 4 4 4M6 12h10"/>'),
  key('<circle cx="8" cy="15" r="4"/><path d="m11 12 9-9M16 7l3 3"/>');

  const FdIcons(this.paths);
  final String paths;
}

/// Renders an [FdIcons] glyph. Sizes: sm 16 (stroke 2), md 20, lg 24.
class FdIcon extends StatelessWidget {
  const FdIcon(this.icon, {super.key, this.size = 20, this.color, this.semanticLabel});

  const FdIcon.sm(this.icon, {super.key, this.color, this.semanticLabel}) : size = 16;
  const FdIcon.lg(this.icon, {super.key, this.color, this.semanticLabel}) : size = 24;

  final FdIcons icon;
  final double size;
  final Color? color;
  final String? semanticLabel;

  static final _cache = <String, String>{};

  @override
  Widget build(BuildContext context) {
    final c = color ?? IconTheme.of(context).color ?? DefaultTextStyle.of(context).style.color ?? Colors.black;
    final stroke = size <= 16 ? 2 : 1.75;
    final key = '${icon.name}|$stroke';
    final svg = _cache.putIfAbsent(
      key,
      () => '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" '
          'stroke="currentColor" stroke-width="$stroke" stroke-linecap="round" '
          'stroke-linejoin="round">${icon.paths}</svg>',
    );
    return SvgPicture.string(
      svg,
      width: size,
      height: size,
      theme: SvgTheme(currentColor: c),
      semanticsLabel: semanticLabel,
      excludeFromSemantics: semanticLabel == null,
    );
  }
}
