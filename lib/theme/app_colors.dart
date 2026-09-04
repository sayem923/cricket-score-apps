import 'package:flutter/material.dart';

/// Single source of truth for every color used in the app.
///
/// Before this file existed, screens hardcoded their own hex values
/// (e.g. `Color(0xFF0F172A)` repeated across many files), which is why
/// the app looked inconsistent - some screens used a dark slate theme,
/// others fell back to the default light Material teal theme.
///
/// Migration plan: refactor screens one at a time to reference these
/// constants instead of hardcoded `Color(0xFF...)` literals. Do NOT
/// delete this comment until every screen under lib/screens has been
/// migrated - it's the checklist.
class AppColors {
  AppColors._();

  // --- Base surfaces (Deep Professional Dark Slate) ---
  static const Color background = Color(0xFF0F172A);
  static const Color surface = Color(0xFF1E293B);
  static const Color surfaceAlt = Color(0xFF162032);
  static const Color border = Color(0xFF334155);

  // --- Brand / primary (Emerald) ---
  static const Color primary = Color(0xFF10B981);
  static const Color primaryDark = Color(0xFF047857);
  static const Color primaryDarker = Color(0xFF022C22);
  static const Color primaryLight = Color(0xFF6EE7B7);
  static const Color primaryGradientStart = Color(0xFF064E3B);
  static const Color primaryGradientEnd = Color(0xFF022C22);

  // --- Text ---
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color(0xFF94A3B8);
  static const Color textMuted = Color(0xFF64748B);

  // --- Status ---
  static const Color success = Color(0xFF22C55E);
  static const Color warning = Color(0xFFF59E0B);
  static const Color warningLight = Color(0xFFFBBF24);
  static const Color error = Color(0xFFEF4444);
  static const Color errorLight = Color(0xFFF87171);
  static const Color info = Color(0xFF38BDF8);
  static const Color infoDark = Color(0xFF0284C7);

  // --- Feature accent colors (used for the home-screen action cards,
  // and reusable anywhere a screen needs a distinct accent per section) ---
  static const Color accentAmber = Color(0xFFF59E0B);
  static const Color accentAmberBg = Color(0xFF2E1A05);

  static const Color accentEmerald = Color(0xFF10B981);
  static const Color accentEmeraldBg = Color(0xFF062A19);

  static const Color accentSapphire = Color(0xFF38BDF8);
  static const Color accentSapphireBg = Color(0xFF072746);

  static const Color accentIndigo = Color(0xFF818CF8);
  static const Color accentIndigoBg = Color(0xFF1A133D);

  static const Color accentViolet = Color(0xFFC084FC);
  static const Color accentVioletBg = Color(0xFF1D1033);

  static const Color accentRose = Color(0xFFF472B6);
  static const Color accentRoseBg = Color(0xFF2D1220);

  static const Color accentRed = Color(0xFFF87171);
  static const Color accentRedBg = Color(0xFF450A0A);

  // --- Guest / warning banner ---
  static const Color guestBannerBg = Color(0xFF291E16);
  static const Color guestBannerBorder = Color(0xFFD97706);
  static const Color guestBannerText = Color(0xFFFDE68A);
}
