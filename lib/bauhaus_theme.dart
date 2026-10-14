import 'package:flutter/material.dart';

/// Visual-only test skin: never used to decide navigation or playback behavior.
/// All design roles are centralized so the old 141 styling can be restored
/// with one git revert/reset of the test commit.
abstract final class Bauhaus {
  static const paper = Color(0xFFF3E8D2);
  static const ink = Color(0xFF191919);
  static const red = Color(0xFFD9362B);
  static const blue = Color(0xFF145A92);
  static const yellow = Color(0xFFF2B927);
  static const green = Color(0xFF18734D);
  static const beige = Color(0xFFDED0B8);
  static const surface = Color(0xFFE9DCC4);
  static const secondaryText = Color(0xFF4D493F);
  static const divider = Color(0x4D191919);
  static const inactive = Color(0xFF817D74);
  static const inkSoft = Color(0xAA191919);
  static const paleRed = Color(0x23D9362B);
  static const mutedBlue = Color(0x22145A92);
  static const smallRadius = 6.0;
  static const mediumRadius = 10.0;
  static const largeRadius = 14.0;

  static ThemeData get theme => ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    fontFamily: 'Josefin',
    scaffoldBackgroundColor: paper,
    colorScheme: const ColorScheme.light(
      primary: red, onPrimary: paper,
      secondary: blue, onSecondary: paper,
      tertiary: yellow, onTertiary: ink,
      surface: paper, onSurface: ink,
      error: red, onError: paper,
    ),
    textTheme: const TextTheme(
      displayLarge: TextStyle(fontWeight: FontWeight.w900, letterSpacing: -1.1),
      displayMedium: TextStyle(fontWeight: FontWeight.w900, letterSpacing: -0.9),
      headlineLarge: TextStyle(fontWeight: FontWeight.w900, letterSpacing: -0.8),
      headlineMedium: TextStyle(fontWeight: FontWeight.w900, letterSpacing: -0.6),
      titleLarge: TextStyle(fontWeight: FontWeight.w900, letterSpacing: -0.5),
      titleMedium: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.3),
      titleSmall: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.2),
      bodyLarge: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.2),
      bodyMedium: TextStyle(fontWeight: FontWeight.w700),
      bodySmall: TextStyle(fontWeight: FontWeight.w600),
      labelLarge: TextStyle(fontWeight: FontWeight.w900),
      labelMedium: TextStyle(fontWeight: FontWeight.w700),
    ),
    appBarTheme: const AppBarTheme(backgroundColor: paper, foregroundColor: ink),
    iconTheme: const IconThemeData(color: ink, size: 24),
    listTileTheme: const ListTileThemeData(iconColor: ink, textColor: ink),
    dividerTheme: const DividerThemeData(color: divider, thickness: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: surface,
      hintStyle: const TextStyle(color: secondaryText, fontWeight: FontWeight.w600),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(mediumRadius),
        borderSide: BorderSide.none),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: red, inactiveTrackColor: beige,
      thumbColor: red, overlayColor: paleRed,
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(
      foregroundColor: ink, iconSize: 25)),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(
      foregroundColor: blue, textStyle: const TextStyle(fontWeight: FontWeight.w900))),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
      backgroundColor: red, foregroundColor: paper,
      textStyle: const TextStyle(fontWeight: FontWeight.w900))),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: paper,
      modalBackgroundColor: paper, shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(largeRadius)))),
    dialogTheme: const DialogThemeData(backgroundColor: paper,
      titleTextStyle: TextStyle(color: ink, fontSize: 22, fontWeight: FontWeight.w900)),
    popupMenuTheme: const PopupMenuThemeData(color: paper,
      textStyle: TextStyle(color: ink, fontWeight: FontWeight.w700)),
  );
}
