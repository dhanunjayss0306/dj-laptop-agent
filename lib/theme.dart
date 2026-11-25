// DJ theme. Flat design law: white #FFFFFF, ink #1D1D1F, blue #0071E3,
// Inter only. No gradients, no glow, no shadows, no pill buttons.
import 'package:flutter/material.dart';

class DjColors {
  static const Color white = Color(0xFFFFFFFF);
  static const Color ink = Color(0xFF1D1D1F);
  static const Color blue = Color(0xFF0071E3);
  static const Color border = Color(0xFFE5E5E5);
  static const Color surfaceMuted = Color(0xFFF5F5F7);
  static const Color green = Color(0xFF1E7E34);
  static const Color amber = Color(0xFF9A6A00);
  static const Color red = Color(0xFFC81E1E);
}

const double _radius = 4.0;

ThemeData djTheme() {
  const textTheme = TextTheme(
    bodyLarge: TextStyle(
        color: DjColors.ink, fontSize: 15, fontFamily: 'Inter'),
    bodyMedium: TextStyle(
        color: DjColors.ink, fontSize: 14, fontFamily: 'Inter'),
    bodySmall: TextStyle(
        color: DjColors.ink, fontSize: 12, fontFamily: 'Inter'),
    titleLarge: TextStyle(
        color: DjColors.ink,
        fontSize: 20,
        fontWeight: FontWeight.w700,
        fontFamily: 'Inter'),
    titleMedium: TextStyle(
        color: DjColors.ink,
        fontSize: 16,
        fontWeight: FontWeight.w600,
        fontFamily: 'Inter'),
    titleSmall: TextStyle(
        color: DjColors.ink,
        fontSize: 14,
        fontWeight: FontWeight.w600,
        fontFamily: 'Inter'),
    labelLarge: TextStyle(
        color: DjColors.ink,
        fontSize: 14,
        fontWeight: FontWeight.w600,
        fontFamily: 'Inter'),
  );

  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(_radius),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: DjColors.white,
    primaryColor: DjColors.blue,
    colorScheme: const ColorScheme.light(
      primary: DjColors.blue,
      onPrimary: DjColors.white,
      secondary: DjColors.blue,
      surface: DjColors.white,
      onSurface: DjColors.ink,
      error: DjColors.red,
    ),
    textTheme: textTheme,
    appBarTheme: const AppBarThemeData(
      backgroundColor: DjColors.white,
      foregroundColor: DjColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: DjColors.white,
      titleTextStyle: TextStyle(
        color: DjColors.ink,
        fontSize: 20,
        fontWeight: FontWeight.w700,
        fontFamily: 'Inter',
      ),
    ),
    cardTheme: CardThemeData(
      color: DjColors.white,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_radius),
        side: const BorderSide(color: DjColors.border),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: DjColors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(_radius)),
        side: BorderSide(color: DjColors.border),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: DjColors.blue,
        foregroundColor: DjColors.white,
        elevation: 0,
        shape: buttonShape,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        textStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          fontFamily: 'Inter',
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: DjColors.blue,
        shape: buttonShape,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        textStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          fontFamily: 'Inter',
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: DjColors.ink,
        side: const BorderSide(color: DjColors.border),
        shape: buttonShape,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        textStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          fontFamily: 'Inter',
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: DjColors.white,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_radius),
        borderSide: const BorderSide(color: DjColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_radius),
        borderSide: const BorderSide(color: DjColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(_radius),
        borderSide: const BorderSide(color: DjColors.blue, width: 1),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return DjColors.blue;
        return DjColors.white;
      }),
      checkColor: WidgetStateProperty.all(DjColors.white),
      side: const BorderSide(color: DjColors.border, width: 1),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(2),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return DjColors.white;
        return DjColors.white;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return DjColors.blue;
        return DjColors.border;
      }),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: DjColors.white,
      selectedItemColor: DjColors.blue,
      unselectedItemColor: DjColors.ink,
      type: BottomNavigationBarType.fixed,
      elevation: 0,
    ),
    dividerTheme: const DividerThemeData(color: DjColors.border, space: 1),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: DjColors.ink,
      contentTextStyle: TextStyle(color: DjColors.white, fontFamily: 'Inter'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(_radius)),
      ),
    ),
  );
}
