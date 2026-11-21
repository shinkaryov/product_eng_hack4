import 'package:flutter/material.dart';

/// Color tokens from the FamilyDoc AI design system, "Clear index" direction
/// (familydoc-theme.css in the design canvas). Light + dark.
/// Color means state, not category: categories stay monochrome.
@immutable
class FdColors extends ThemeExtension<FdColors> {
  const FdColors({
    required this.canvas,
    required this.surface,
    required this.source,
    required this.surfaceSunken,
    required this.surfacePressed,
    required this.ink,
    required this.inkSecondary,
    required this.line,
    required this.lineStrong,
    required this.lineSoft,
    required this.brand,
    required this.brandPressed,
    required this.brandSoft,
    required this.onBrand,
    required this.success,
    required this.successSoft,
    required this.danger,
    required this.dangerSoft,
    required this.onDanger,
    required this.warning,
    required this.warningSoft,
    required this.info,
    required this.infoSoft,
    required this.glass,
    required this.glassStrong,
    required this.glassBorder,
    required this.glassInk,
    required this.scrim,
    required this.camera,
    required this.onCamera,
    required this.cameraChip,
    required this.shadowCard,
    required this.shadowRaised,
    required this.shadowButton,
    required this.shadowNav,
    required this.shadowSheet,
  });

  final Color canvas;
  final Color surface;

  /// Slightly tinted surface for quoted source text and table heads.
  final Color source;
  final Color surfaceSunken;
  final Color surfacePressed;
  final Color ink;
  final Color inkSecondary;
  Color get inkTertiary => inkSecondary;
  final Color line;
  final Color lineStrong;
  final Color lineSoft;
  final Color brand;
  final Color brandPressed;
  final Color brandSoft;
  final Color onBrand;
  Color get focus => brand;
  final Color success;
  final Color successSoft;
  final Color danger;
  final Color dangerSoft;
  final Color onDanger;
  final Color warning;
  final Color warningSoft;

  /// Icons and bars only.
  Color get warningMark => warning;
  final Color info;
  final Color infoSoft;
  final Color glass;
  final Color glassStrong;
  final Color glassBorder;

  /// Toast background (dark glass in light theme).
  final Color glassInk;
  final Color scrim;
  final Color camera;
  final Color onCamera;
  final Color cameraChip;
  Color get redact => ink;

  final List<BoxShadow> shadowCard;
  final List<BoxShadow> shadowRaised;
  final List<BoxShadow> shadowButton;
  final List<BoxShadow> shadowNav;
  final List<BoxShadow> shadowSheet;

  static const _ink = Color(0xFF182C48);

  static const light = FdColors(
    canvas: Color(0xFFF1F5FB),
    surface: Color(0xFFFFFFFF),
    source: Color(0xFFF8FAFD),
    surfaceSunken: Color(0xFFE7EDF5),
    surfacePressed: Color(0xFFDCE4EF),
    ink: _ink,
    inkSecondary: Color(0xFF53647A),
    line: Color(0xFFBAC8DC),
    lineStrong: Color(0xFF71839D),
    lineSoft: Color(0x8CBAC8DC),
    brand: Color(0xFF244DB0),
    brandPressed: Color(0xFF1D4095),
    brandSoft: Color(0xFFE0E9FB),
    onBrand: Color(0xFFFFFFFF),
    success: Color(0xFF276342),
    successSoft: Color(0xFFEAF4ED),
    danger: Color(0xFFA12E36),
    dangerSoft: Color(0xFFFCECED),
    onDanger: Color(0xFFFFFFFF),
    warning: Color(0xFF805000),
    warningSoft: Color(0xFFFFF2CF),
    info: Color(0xFF244DB0),
    infoSoft: Color(0xFFE0E9FB),
    glass: Color(0xB8FFFFFF),
    glassStrong: Color(0xE6FFFFFF),
    glassBorder: Color(0xD9FFFFFF),
    glassInk: Color(0xDB182C48),
    scrim: Color(0x7A182C48),
    camera: Color(0xFF0E0F11),
    onCamera: Color(0xFFFFFFFF),
    cameraChip: Color(0x29FFFFFF),
    shadowCard: [
      BoxShadow(color: Color(0x0F182C48), blurRadius: 2, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x0F182C48), blurRadius: 14, offset: Offset(0, 4)),
    ],
    shadowRaised: [
      BoxShadow(color: Color(0x0F182C48), blurRadius: 4, offset: Offset(0, 2)),
      BoxShadow(color: Color(0x1A182C48), blurRadius: 28, offset: Offset(0, 10)),
    ],
    shadowButton: [
      BoxShadow(color: Color(0x3D244DB0), blurRadius: 2, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x38244DB0), blurRadius: 14, offset: Offset(0, 6)),
    ],
    shadowNav: [
      BoxShadow(color: Color(0x24182C48), blurRadius: 32, offset: Offset(0, 8)),
    ],
    shadowSheet: [
      BoxShadow(color: Color(0x29182C48), blurRadius: 40, offset: Offset(0, -8)),
    ],
  );

  static const dark = FdColors(
    canvas: Color(0xFF0F1724),
    surface: Color(0xFF172131),
    source: Color(0xFF1B2638),
    surfaceSunken: Color(0xFF212D40),
    surfacePressed: Color(0xFF29374D),
    ink: Color(0xFFE6ECF5),
    inkSecondary: Color(0xFFA9B6C8),
    line: Color(0xFF2E3C53),
    lineStrong: Color(0xFF7286A2),
    lineSoft: Color(0xB32E3C53),
    brand: Color(0xFF8FB0FF),
    brandPressed: Color(0xFFABC4FF),
    brandSoft: Color(0xFF1C2D4D),
    onBrand: Color(0xFF0B1A3A),
    success: Color(0xFF86CFA3),
    successSoft: Color(0xFF14301F),
    danger: Color(0xFFF4949B),
    dangerSoft: Color(0xFF3A1C21),
    onDanger: Color(0xFF2A0D11),
    warning: Color(0xFFF2C063),
    warningSoft: Color(0xFF33270F),
    info: Color(0xFF8FB0FF),
    infoSoft: Color(0xFF1C2D4D),
    glass: Color(0xB8172131),
    glassStrong: Color(0xE6172131),
    glassBorder: Color(0x1AFFFFFF),
    glassInk: Color(0xEBE6ECF5),
    scrim: Color(0xA3000000),
    camera: Color(0xFF0E0F11),
    onCamera: Color(0xFFFFFFFF),
    cameraChip: Color(0x29FFFFFF),
    shadowCard: [
      BoxShadow(color: Color(0x66000000), blurRadius: 2, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x4D000000), blurRadius: 14, offset: Offset(0, 4)),
    ],
    shadowRaised: [
      BoxShadow(color: Color(0x66000000), blurRadius: 4, offset: Offset(0, 2)),
      BoxShadow(color: Color(0x73000000), blurRadius: 28, offset: Offset(0, 10)),
    ],
    shadowButton: [
      BoxShadow(color: Color(0x66000000), blurRadius: 2, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x59000000), blurRadius: 14, offset: Offset(0, 6)),
    ],
    shadowNav: [
      BoxShadow(color: Color(0x80000000), blurRadius: 32, offset: Offset(0, 8)),
    ],
    shadowSheet: [
      BoxShadow(color: Color(0x8C000000), blurRadius: 40, offset: Offset(0, -8)),
    ],
  );

  @override
  FdColors copyWith() => this;

  @override
  FdColors lerp(covariant ThemeExtension<FdColors>? other, double t) {
    if (other is! FdColors) return this;
    return t < 0.5 ? this : other;
  }
}

extension FdColorsX on BuildContext {
  FdColors get fd => Theme.of(this).extension<FdColors>()!;
}
