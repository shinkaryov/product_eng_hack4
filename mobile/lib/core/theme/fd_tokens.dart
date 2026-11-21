/// Spacing, radius and size tokens (4pt grid) from the design system.
abstract final class FdSpace {
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 20; // mobile gutter
  static const double s6 = 24;
  static const double s8 = 32;
  static const double s10 = 40;
  static const double s12 = 48;
  static const double s16 = 64;
}

abstract final class FdRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double full = 999;
}

abstract final class FdSize {
  static const double tapMin = 44;
  static const double control = 48;
  static const double controlLg = 56;
  static const double iconSm = 16;
  static const double iconMd = 20;
  static const double iconLg = 24;
  static const double navBar = 64;
}

abstract final class FdBreakpoint {
  static const double tablet = 768;
  static const double desktop = 1024;
}
