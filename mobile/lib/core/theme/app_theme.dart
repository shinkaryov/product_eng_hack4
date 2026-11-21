import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'fd_colors.dart';
import 'fd_tokens.dart';
import 'fd_typography.dart';

ThemeData buildTheme(Brightness brightness) {
  final c = brightness == Brightness.light ? FdColors.light : FdColors.dark;

  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.brand,
    onPrimary: c.onBrand,
    primaryContainer: c.brandSoft,
    onPrimaryContainer: c.ink,
    secondary: c.brand,
    onSecondary: c.onBrand,
    error: c.danger,
    onError: c.onDanger,
    errorContainer: c.dangerSoft,
    onErrorContainer: c.ink,
    surface: c.surface,
    onSurface: c.ink,
    onSurfaceVariant: c.inkSecondary,
    surfaceContainerHighest: c.surfaceSunken,
    outline: c.lineStrong,
    outlineVariant: c.line,
    scrim: c.scrim,
  );

  final base = ThemeData(useMaterial3: true, brightness: brightness);
  final textTheme = GoogleFonts.ibmPlexSansTextTheme(base.textTheme)
      .apply(bodyColor: c.ink, displayColor: c.ink);

  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: c.canvas,
    canvasColor: c.canvas,
    textTheme: textTheme,
    dividerColor: c.line,
    splashFactory: NoSplash.splashFactory,
    highlightColor: c.surfaceSunken,
    hoverColor: c.surfaceSunken,
    extensions: [c],
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.brand,
      selectionColor: c.brandSoft,
      selectionHandleColor: c.brand,
    ),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: c.surface,
      headerHeadlineStyle: FdType.title,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(FdRadius.xl)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(FdRadius.xl)),
      titleTextStyle: FdType.headline.copyWith(color: c.ink),
      contentTextStyle: FdType.body.copyWith(color: c.ink),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.brand),
  );
}
