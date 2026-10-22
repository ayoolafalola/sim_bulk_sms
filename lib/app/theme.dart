import 'package:flutter/material.dart';

/// Design tokens from the approved redesign: deep green brand, warm
/// off-white ground, white cards, Plus Jakarta Sans, generous radii and
/// 44–56 px touch targets. Dark mode mirrors every token.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.ground, required this.surface, required this.line, required this.muted,
    required this.successBg, required this.successFg, required this.warnBg, required this.warnFg,
    required this.dangerBg, required this.dangerFg, required this.infoBg, required this.infoFg,
    required this.neutralBg,
  });
  final Color ground, surface, line, muted;
  final Color successBg, successFg, warnBg, warnFg, dangerBg, dangerFg, infoBg, infoFg, neutralBg;

  static const light = AppColors(
    ground: Color(0xFFF7F5F0), surface: Color(0xFFFFFFFF), line: Color(0xFFE6E2DA), muted: Color(0xFF5B6763),
    successBg: Color(0xFFDDEFE9), successFg: Color(0xFF124C3F),
    warnBg: Color(0xFFFFF1C7), warnFg: Color(0xFF7A4B00),
    dangerBg: Color(0xFFFBE2E2), dangerFg: Color(0xFF8F1D1D),
    infoBg: Color(0xFFE3E8FA), infoFg: Color(0xFF2A3A8A),
    neutralBg: Color(0xFFEFEBE3),
  );
  static const dark = AppColors(
    ground: Color(0xFF101513), surface: Color(0xFF18201D), line: Color(0xFF2A332F), muted: Color(0xFFA7B1AD),
    successBg: Color(0xFF1F4A3F), successFg: Color(0xFFBFEBDD),
    warnBg: Color(0xFF4A3A10), warnFg: Color(0xFFFFE3A1),
    dangerBg: Color(0xFF4D1F1F), dangerFg: Color(0xFFFFCACA),
    infoBg: Color(0xFF26305A), infoFg: Color(0xFFCDD6FF),
    neutralBg: Color(0xFF232B28),
  );

  /// The app theme's colours; falls back to the defaults outside it (e.g. plain dialogs, tests).
  static AppColors of(BuildContext context) {
    final t = Theme.of(context);
    return t.extension<AppColors>() ?? (t.brightness == Brightness.dark ? dark : light);
  }

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) => t < 0.5 ? this : (other as AppColors? ?? this);
}

const brandGreen = Color(0xFF1B6B5A);
const _fontFamily = 'PlusJakartaSans';

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final c = dark ? AppColors.dark : AppColors.light;
  final text = dark ? const Color(0xFFE8ECEA) : const Color(0xFF16201C);
  final scheme = ColorScheme.fromSeed(seedColor: brandGreen, brightness: b).copyWith(
    primary: dark ? const Color(0xFF6FD1B5) : brandGreen,
    onPrimary: dark ? const Color(0xFF0B2A22) : Colors.white,
    primaryContainer: c.successBg,
    onPrimaryContainer: c.successFg,
    surface: c.surface,
    onSurface: text,
    onSurfaceVariant: c.muted,
    surfaceContainerHighest: c.neutralBg,
    surfaceContainerHigh: c.neutralBg,
    surfaceContainer: c.surface,
    surfaceContainerLow: c.surface,
    outline: c.line,
    outlineVariant: c.line,
    error: dark ? const Color(0xFFFF8A80) : const Color(0xFFB42318),
    errorContainer: c.dangerBg,
    onErrorContainer: c.dangerFg,
    tertiary: dark ? const Color(0xFFFFC857) : const Color(0xFF9A5B00),
  );
  final radius16 = BorderRadius.circular(16);
  final base = ThemeData(useMaterial3: true, brightness: b, colorScheme: scheme, fontFamily: _fontFamily);
  final tt = base.textTheme.apply(bodyColor: text, displayColor: text);

  return base.copyWith(
    scaffoldBackgroundColor: c.ground,
    extensions: [c],
    visualDensity: VisualDensity.standard,
    textTheme: tt.copyWith(
      headlineMedium: tt.headlineMedium?.copyWith(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -0.5),
      headlineSmall: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.3),
      titleLarge: tt.titleLarge?.copyWith(fontWeight: FontWeight.w800),
      titleMedium: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      titleSmall: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      labelLarge: tt.labelLarge?.copyWith(fontWeight: FontWeight.w700),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: c.ground,
      foregroundColor: text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(fontFamily: _fontFamily, fontSize: 20, fontWeight: FontWeight.w800, color: text),
    ),
    cardTheme: CardThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: c.line)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: radius16, borderSide: BorderSide(color: c.line)),
      enabledBorder: OutlineInputBorder(borderRadius: radius16, borderSide: BorderSide(color: c.line)),
      focusedBorder: OutlineInputBorder(borderRadius: radius16, borderSide: BorderSide(color: scheme.primary, width: 2)),
      labelStyle: TextStyle(color: c.muted, fontWeight: FontWeight.w600),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: RoundedRectangleBorder(borderRadius: radius16),
        textStyle: const TextStyle(fontFamily: _fontFamily, fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: RoundedRectangleBorder(borderRadius: radius16),
        side: BorderSide(color: c.line),
        foregroundColor: text,
        textStyle: const TextStyle(fontFamily: _fontFamily, fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 44),
        textStyle: const TextStyle(fontFamily: _fontFamily, fontWeight: FontWeight.w700),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: 4,
      extendedTextStyle: const TextStyle(fontFamily: _fontFamily, fontSize: 15, fontWeight: FontWeight.w700),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.surface,
      selectedColor: c.successBg,
      side: BorderSide(color: c.line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      labelStyle: TextStyle(fontFamily: _fontFamily, fontWeight: FontWeight.w600, color: text),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: c.successBg,
      height: 72,
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontFamily: _fontFamily,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: s.contains(WidgetState.selected) ? scheme.primary : c.muted,
          )),
      iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? scheme.primary : c.muted)),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: c.muted,
      minVerticalPadding: 10,
      titleTextStyle: TextStyle(fontFamily: _fontFamily, fontSize: 16, fontWeight: FontWeight.w600, color: text),
      subtitleTextStyle: TextStyle(fontFamily: _fontFamily, fontSize: 13, color: c.muted),
    ),
    dividerTheme: DividerThemeData(color: c.line, space: 1, thickness: 1),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        minimumSize: const Size(48, 48),
        selectedBackgroundColor: c.successBg,
        selectedForegroundColor: c.successFg,
        side: BorderSide(color: c.line),
        textStyle: const TextStyle(fontFamily: _fontFamily, fontWeight: FontWeight.w700),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.onPrimary : null),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.primary : null),
    ),
  );
}
