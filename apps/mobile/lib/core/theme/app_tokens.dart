import 'package:flutter/material.dart';

abstract final class AppColors {
  static const Color seed = Color(0xFF00696B);
  static const Color success = Color(0xFF2E7D32);
  static const Color onSuccess = Color(0xFFFFFFFF);
  static const Color successContainer = Color(0xFFB7F1C0);
  static const Color onSuccessContainer = Color(0xFF08210D);
  static const Color warning = Color(0xFF8A5000);
  static const Color onWarning = Color(0xFFFFFFFF);
  static const Color warningContainer = Color(0xFFFFDDB3);
  static const Color onWarningContainer = Color(0xFF2B1600);
  static const Color error = Color(0xFFBA1A1A);
  static const Color onError = Color(0xFFFFFFFF);
  static const Color errorContainer = Color(0xFFFFDAD6);
  static const Color onErrorContainer = Color(0xFF410002);
  static const Color info = Color(0xFF0061A4);
  static const Color onInfo = Color(0xFFFFFFFF);
  static const Color infoContainer = Color(0xFFD4E4FF);
  static const Color onInfoContainer = Color(0xFF001D36);
  static const Color neutral = Color(0xFF5F5E5E);
  static const Color onNeutral = Color(0xFFFFFFFF);
  static const Color neutralContainer = Color(0xFFE7E2E0);
  static const Color onNeutralContainer = Color(0xFF211A1A);
}

abstract final class AppSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

abstract final class AppRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double pill = 999;
}

abstract final class AppTypography {
  static const double display = 34;
  static const double headline = 26;
  static const double title = 20;
  static const double subtitle = 16;
  static const double body = 14;
  static const double label = 12;
  static const double caption = 11;
}
