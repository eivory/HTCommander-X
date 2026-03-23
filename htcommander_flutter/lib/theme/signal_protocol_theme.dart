import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class SignalProtocolTheme {
  SignalProtocolTheme._();

  // Dark palette
  static const _darkSurface = Color(0xFF080A12);
  static const _darkSurfaceContainerLow = Color(0xFF0E1019);
  static const _darkSurfaceContainer = Color(0xFF141828);
  static const _darkSurfaceContainerHigh = Color(0xFF1A2038);
  static const _darkSurfaceContainerHighest = Color(0xFF222844);
  static const _darkPrimary = Color(0xFF3CD7FF);
  static const _darkOnPrimary = Color(0xFF080A12);
  static const _darkPrimaryContainer = Color(0xFF004E5F);
  static const _darkTertiary = Color(0xFFB5FFC2);
  static const _darkTertiaryContainer = Color(0xFF3FFF8B);
  static const _darkError = Color(0xFFEE7D77);
  static const _darkOnSurface = Color(0xFFE0E4FF);
  static const _darkOnSurfaceVariant = Color(0xFFA4AAC9);
  static const _darkOutline = Color(0xFF6E7492);
  static const _darkOutlineVariant = Color(0xFF404762);

  // Light palette
  static const _lightSurface = Color(0xFFF8F9FF);
  static const _lightSurfaceContainerLow = Color(0xFFF0F1FA);
  static const _lightSurfaceContainer = Color(0xFFE8E9F4);
  static const _lightSurfaceContainerHigh = Color(0xFFDEDFEE);
  static const _lightSurfaceContainerHighest = Color(0xFFD4D5E6);
  static const _lightPrimary = Color(0xFF00687E);
  static const _lightOnPrimary = Color(0xFFFFFFFF);
  static const _lightPrimaryContainer = Color(0xFFB5EBFF);
  static const _lightTertiary = Color(0xFF006D3A);
  static const _lightTertiaryContainer = Color(0xFF7DFBA6);
  static const _lightError = Color(0xFFBA1A1A);
  static const _lightOnSurface = Color(0xFF1A1C2A);
  static const _lightOnSurfaceVariant = Color(0xFF44475E);
  static const _lightOutline = Color(0xFF747892);
  static const _lightOutlineVariant = Color(0xFFC4C6DC);

  static TextTheme _buildTextTheme(TextTheme base) {
    return GoogleFonts.interTextTheme(base);
  }

  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      colorScheme: ColorScheme.dark(
        surface: _darkSurface,
        surfaceContainerLowest: _darkSurface,
        surfaceContainerLow: _darkSurfaceContainerLow,
        surfaceContainer: _darkSurfaceContainer,
        surfaceContainerHigh: _darkSurfaceContainerHigh,
        surfaceContainerHighest: _darkSurfaceContainerHighest,
        primary: _darkPrimary,
        onPrimary: _darkOnPrimary,
        primaryContainer: _darkPrimaryContainer,
        tertiary: _darkTertiary,
        tertiaryContainer: _darkTertiaryContainer,
        error: _darkError,
        onSurface: _darkOnSurface,
        onSurfaceVariant: _darkOnSurfaceVariant,
        outline: _darkOutline,
        outlineVariant: _darkOutlineVariant,
      ),
      scaffoldBackgroundColor: _darkSurface,
      textTheme: _buildTextTheme(base.textTheme),
      appBarTheme: AppBarTheme(
        backgroundColor: _darkSurfaceContainerLow,
        foregroundColor: _darkOnSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: _darkSurfaceContainer,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: _darkSurfaceContainerLow,
        selectedIconTheme: IconThemeData(color: _darkPrimary),
        unselectedIconTheme: IconThemeData(color: _darkOnSurfaceVariant),
        selectedLabelTextStyle: TextStyle(
          color: _darkPrimary,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: _darkOnSurfaceVariant,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: _darkSurfaceContainerLow,
        indicatorColor: _darkPrimaryContainer,
      ),
    );
  }

  static ThemeData light() {
    final base = ThemeData.light(useMaterial3: true);
    return base.copyWith(
      colorScheme: ColorScheme.light(
        surface: _lightSurface,
        surfaceContainerLowest: _lightSurface,
        surfaceContainerLow: _lightSurfaceContainerLow,
        surfaceContainer: _lightSurfaceContainer,
        surfaceContainerHigh: _lightSurfaceContainerHigh,
        surfaceContainerHighest: _lightSurfaceContainerHighest,
        primary: _lightPrimary,
        onPrimary: _lightOnPrimary,
        primaryContainer: _lightPrimaryContainer,
        tertiary: _lightTertiary,
        tertiaryContainer: _lightTertiaryContainer,
        error: _lightError,
        onSurface: _lightOnSurface,
        onSurfaceVariant: _lightOnSurfaceVariant,
        outline: _lightOutline,
        outlineVariant: _lightOutlineVariant,
      ),
      scaffoldBackgroundColor: _lightSurface,
      textTheme: _buildTextTheme(base.textTheme),
      appBarTheme: AppBarTheme(
        backgroundColor: _lightSurfaceContainerLow,
        foregroundColor: _lightOnSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: _lightSurfaceContainer,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: _lightSurfaceContainerLow,
        selectedIconTheme: IconThemeData(color: _lightPrimary),
        unselectedIconTheme: IconThemeData(color: _lightOnSurfaceVariant),
        selectedLabelTextStyle: TextStyle(
          color: _lightPrimary,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: _lightOnSurfaceVariant,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: _lightSurfaceContainerLow,
        indicatorColor: _lightPrimaryContainer,
      ),
    );
  }
}
