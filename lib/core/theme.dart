import 'package:flutter/material.dart';

abstract final class WrytteColors {
  static const Color background = Color(0xFF08090B);
  static const Color surfaceRaised = Color(0xFF23262C);
  static const Color primary = Color(0xFF4DA3FF);
  static const Color onPrimary = Color(0xFFFFFFFF);
  static const Color iconPrimary = Color(0xFFF7F8FA);
  static const Color textPrimary = Color(0xFFF2F2F2);
  static const Color textSecondary = Color(0xFFC6C6C6);
  static const Color textMuted = Color(0xFF9A9DA4);
}

abstract final class WrytteTypography {
  static const String primaryFontFamily = 'Inter';

  static const TextStyle authPageTitle = TextStyle(
    fontFamily: primaryFontFamily,
    fontSize: 25,
    fontWeight: FontWeight.w600,
    height: 1.2,
    letterSpacing: 0,
    color: WrytteColors.textPrimary,
  );

  static const TextStyle authSubtitle = TextStyle(
    fontFamily: primaryFontFamily,
    fontSize: 14,
    fontWeight: FontWeight.normal,
    height: 1.4,
    letterSpacing: 0,
    color: WrytteColors.textSecondary,
  );

  static const TextStyle authBody = TextStyle(
    fontFamily: primaryFontFamily,
    fontSize: 14,
    fontWeight: FontWeight.normal,
    height: 1.4,
    letterSpacing: 0,
    color: WrytteColors.textPrimary,
  );

  static const TextStyle authSectionTitleLarge = TextStyle(
    fontFamily: primaryFontFamily,
    fontSize: 20,
    fontWeight: FontWeight.w500,
    height: 1.3,
    letterSpacing: 0,
    color: WrytteColors.textPrimary,
  );

  static const TextStyle authButtonLabel = TextStyle(
    fontFamily: primaryFontFamily,
    fontSize: 18,
    fontWeight: FontWeight.w500,
    height: 1.2,
    letterSpacing: 0,
    color: WrytteColors.onPrimary,
  );

  static const TextStyle authInput = TextStyle(
    fontFamily: primaryFontFamily,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.3,
    letterSpacing: 0,
    color: WrytteColors.textPrimary,
  );
}

class WrytteTheme {
  static const Color background = WrytteColors.background;

  static ThemeData lightTheme = ThemeData(
    scaffoldBackgroundColor: Colors.transparent,
    brightness: Brightness.dark,
    fontFamily: 'Roboto', // Roboto as global font
    textTheme: const TextTheme(
      bodyLarge: TextStyle(color: Colors.white),
      bodyMedium: TextStyle(color: Colors.white),
      bodySmall: TextStyle(color: Colors.white),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
    ),
  );
}
