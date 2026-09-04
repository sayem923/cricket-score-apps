import 'package:flutter/material.dart';

/// Spacing, corner-radius and shadow tokens - keeps padding/margins/
/// rounded-corners consistent across every screen instead of each
/// screen picking its own numbers (8, 10, 12, 14, 16 were all used
/// interchangeably before this file existed).
class AppSpacing {
  AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
}

class AppRadius {
  AppRadius._();

  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double full = 999;
}

class AppShadows {
  AppShadows._();

  static List<BoxShadow> card = [
    BoxShadow(
      color: Colors.black.withOpacity(0.2),
      blurRadius: 10,
      offset: const Offset(0, 4),
    ),
  ];

  static List<BoxShadow> cardSmall = [
    BoxShadow(
      color: Colors.black.withOpacity(0.15),
      blurRadius: 6,
      offset: const Offset(0, 3),
    ),
  ];
}
