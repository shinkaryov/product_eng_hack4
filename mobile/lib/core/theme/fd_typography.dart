import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Type scale from familydoc-theme.css. One family: IBM Plex Sans.
/// Styles carry no color: they inherit `ink` unless overridden.
abstract final class FdType {
  static const tnum = [FontFeature.tabularFigures()];

  static TextStyle _s(double size, double lineHeight, FontWeight weight) =>
      GoogleFonts.ibmPlexSans(
        fontSize: size,
        height: lineHeight / size,
        fontWeight: weight,
      );

  static final displayLg = _s(32, 40, FontWeight.w700);
  static final display = _s(28, 35, FontWeight.w700);
  static final title = _s(24, 30, FontWeight.w600);
  static final lead = _s(22, 28, FontWeight.w600);
  static final headline = _s(20, 25, FontWeight.w600);
  static final section = _s(20, 25, FontWeight.w600);
  static final body = _s(16, 24, FontWeight.w400);
  static final bodyStrong = _s(16, 24, FontWeight.w600);
  static final callout = _s(14, 21, FontWeight.w400);
  static final label = _s(16, 20, FontWeight.w600);
  static final meta = _s(14, 20, FontWeight.w400);
  static final overline = _s(14, 20, FontWeight.w600);
  static final figure = _s(24, 28, FontWeight.w600).copyWith(fontFeatures: tnum);

  // Component-specific sizes from bundle.css.
  static final appbarTitle = _s(17, 24, FontWeight.w600);
  static final listTitle = _s(16, 22, FontWeight.w600);
  static final fieldLabel = _s(15, 20, FontWeight.w500);
  static final chip = _s(15, 20, FontWeight.w500);
  static final badge = _s(14, 18, FontWeight.w600).copyWith(fontFeatures: tnum);
  static final nav = _s(13, 16, FontWeight.w500);
  static final toast = _s(15, 22, FontWeight.w400);
  static final household = _s(15, 20, FontWeight.w600);
  static final calc = _s(15, 22, FontWeight.w400).copyWith(fontFeatures: tnum);
}
