import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'models.dart';

ThemeMode materialThemeMode(AppThemeMode mode) => switch (mode) {
  AppThemeMode.system => ThemeMode.system,
  AppThemeMode.light => ThemeMode.light,
  AppThemeMode.dark => ThemeMode.dark,
};

String themeModeLabel(AppThemeMode mode) => switch (mode) {
  AppThemeMode.system => '跟随系统',
  AppThemeMode.light => '浅色',
  AppThemeMode.dark => '深色',
};

ThemeData buildAppTheme(Brightness brightness) {
  final colors = ColorScheme.fromSeed(
    seedColor: const Color(0xff087f75),
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    scaffoldBackgroundColor: colors.surface,
    inputDecorationTheme: InputDecorationTheme(
      border: const OutlineInputBorder(),
      filled: true,
      fillColor: colors.surfaceContainerLowest,
    ),
    cardTheme: CardThemeData(
      color: colors.surfaceContainerLow,
      elevation: 0,
      margin: EdgeInsets.zero,
    ),
  );
}

extension StatusColors on ColorScheme {
  Color get warning => brightness == Brightness.dark
      ? const Color(0xffedc078)
      : const Color(0xff805500);
}

// The custom header has no AppBar to set Android's edge-to-edge system bars.
SystemUiOverlayStyle systemUiStyleFor(ThemeData theme) {
  final dark = theme.brightness == Brightness.dark;
  final icons = dark ? Brightness.light : Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarBrightness: theme.brightness,
    statusBarIconBrightness: icons,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: icons,
  );
}
