import 'package:shared_preferences/shared_preferences.dart';

/// Tracks whether the person has already been shown the first-launch
/// onboarding walkthrough, persisting the flag with shared_preferences so
/// it survives app restarts - same storage approach as LocaleService,
/// and deliberately device-scoped (not per-account) so a guest who later
/// signs up doesn't see the walkthrough a second time.
class OnboardingService {
  OnboardingService._();

  static const _prefsKey = 'cricket_scorer_onboarding_seen_v1';

  /// Call once, early in main() before runApp - lets [OnboardingGate]
  /// decide synchronously (no loading flicker) whether to show the
  /// walkthrough or skip straight to [AuthGate].
  static Future<bool> hasSeenOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefsKey) ?? false;
  }

  static Future<void> markSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, true);
  }
}