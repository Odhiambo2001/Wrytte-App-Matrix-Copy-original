import 'package:flutter/cupertino.dart'
    show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:wrytte/ui/core/routing/wrytte_page_transitions.dart';

abstract final class WrytteColors {
  static const Color background = Color(0xFF08090B);

  static const Color surface = Color(0xFF111318);

  static const Color surfaceRaised = Color(0xFF23262C);

  static const Color primary = Color(0xFF4DA3FF);

  static const Color brandCoral = Color(0xFFFF5E5E);

  static const Color onPrimary = Color(0xFFFFFFFF);

  static const Color iconPrimary = Color(0xFFF7F8FA);

  static const Color textPrimary = Color(0xFFF2F2F2);

  static const Color textSecondary = Color(0xFFC6C6C6);

  static const Color textMuted = Color(0xFF9A9DA4);

  static const Color destructive = Color(0xFFFF5E5E);

  static const Color success = Color(0xFF20C768);

  static const Color warning = Color(0xFFFFA21A);

  static const Color transparent = Color(0x00000000);
}

abstract final class WrytteSpacing {
  static const double pageHorizontal = 18;

  static const double contentMaxWidth = 430;

  static const double controlHeight = 54;

  static const double actionHeight = 48;
}

abstract final class WrytteTypography {
  static const String primaryFontFamily = 'Inter';

  static const String serifFontFamily = 'NotoSerif';

  static const String condensedFontFamily = 'RobotoCondensed';

  static const TextStyle authPageTitle = TextStyle(
    fontFamily: primaryFontFamily,
    fontSize: 25,
    fontWeight: FontWeight.w600,
    height: 1.2,
    letterSpacing: 0,
    color: WrytteColors.textPrimary,
  );

  static const TextStyle authWelcomeTitle = TextStyle(
    fontFamily: primaryFontFamily,
    fontSize: 26,
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

  // Exact old Welcome description style.
  static const TextStyle authWelcomeSubtitle = TextStyle(
    inherit: false,
    fontFamily: primaryFontFamily,
    fontSize: 14,
    fontWeight: FontWeight.normal,
    height: 1.4,
    letterSpacing: 0,
    color: Colors.white,
  );

  static const TextStyle authBody = TextStyle(
    fontFamily: primaryFontFamily,
    fontSize: 14,
    fontWeight: FontWeight.normal,
    height: 1.4,
    letterSpacing: 0,
    color: WrytteColors.textPrimary,
  );

  static const TextStyle authSectionTitle = TextStyle(
    fontFamily: primaryFontFamily,
    fontSize: 20,
    fontWeight: FontWeight.w500,
    height: 1.3,
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

  static const TextStyle authLegal = TextStyle(
    fontFamily: primaryFontFamily,
    fontSize: 12,
    fontWeight: FontWeight.normal,
    height: 1.4,
    letterSpacing: 0,
    color: Colors.white,
  );

  static const TextStyle authChoiceLabel = TextStyle(
    fontFamily: primaryFontFamily,
    fontSize: 18,
    fontWeight: FontWeight.w500,
    height: 1.2,
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

  static const TextStyle authCompactButtonLabel = TextStyle(
    fontFamily: primaryFontFamily,
    fontSize: 16,
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

  static const TextStyle authFooter = TextStyle(
    fontFamily: primaryFontFamily,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.3,
    letterSpacing: 0,
    color: WrytteColors.onPrimary,
  );

  static const TextStyle authFooterAction = TextStyle(
    fontFamily: primaryFontFamily,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.3,
    letterSpacing: 0,
    color: WrytteColors.primary,
  );
}

abstract final class WrytteTheme {
  static ThemeData get dark {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: WrytteColors.primary,
      brightness: Brightness.dark,
      surface: WrytteColors.background,
    );

    return ThemeData(
      brightness: Brightness.dark,

      colorScheme: colorScheme,

      scaffoldBackgroundColor: WrytteColors.background,

      fontFamily: WrytteTypography.primaryFontFamily,

      useMaterial3: true,

      // ============================================================
      // PAGE NAVIGATION
      // ============================================================
      //
      // Android:
      //
      // Uses Wrytte's custom horizontal page transition.
      //
      // - next screen enters from the right
      // - previous screen moves slightly left underneath
      // - back reverses the movement
      // - no shadow
      // - no fade
      // - no scaling
      // - no dark overlay
      // - no Cupertino interactive swipe gesture
      //
      //
      // iOS:
      //
      // Keep Flutter's proper Cupertino page transition, including
      // native iOS navigation behavior.
      //
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android:
              WryttePageTransitionsBuilder(),

          TargetPlatform.iOS:
              CupertinoPageTransitionsBuilder(),

          TargetPlatform.macOS:
              CupertinoPageTransitionsBuilder(),

          TargetPlatform.fuchsia:
              FadeForwardsPageTransitionsBuilder(),

          TargetPlatform.linux:
              FadeForwardsPageTransitionsBuilder(),

          TargetPlatform.windows:
              FadeForwardsPageTransitionsBuilder(),
        },
      ),

      splashFactory: InkSparkle.splashFactory,

      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: WrytteColors.primary,

        selectionColor: Color(0x664DA3FF),

        selectionHandleColor: WrytteColors.primary,
      ),

      inputDecorationTheme: const InputDecorationTheme(
        border: InputBorder.none,

        enabledBorder: InputBorder.none,

        focusedBorder: InputBorder.none,

        errorBorder: InputBorder.none,

        focusedErrorBorder: InputBorder.none,
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(
            48,
            WrytteSpacing.actionHeight,
          ),

          backgroundColor: WrytteColors.primary,

          foregroundColor: WrytteColors.onPrimary,

          disabledBackgroundColor:
              WrytteColors.surfaceRaised,

          disabledForegroundColor:
              WrytteColors.textMuted,

          elevation: 0,

          shape: const StadiumBorder(),

          textStyle: const TextStyle(
            fontFamily:
                WrytteTypography.primaryFontFamily,

            fontSize: 17,

            fontWeight: FontWeight.w500,
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: WrytteColors.primary,

          disabledForegroundColor:
              WrytteColors.textMuted,
        ),
      ),
    );
  }
}