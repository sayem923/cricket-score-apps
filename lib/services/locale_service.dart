import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tracks the app's active language ('en' or 'bn') and persists the choice
/// to disk so it survives app restarts - same shared_preferences-backed
/// pattern as StorageService, but this one is intentionally NOT
/// user-scoped (language is a device preference, not account data, so it
/// applies the same way to guests and logged-in users alike).
///
/// Screens read strings through the `tr()` helper in
/// lib/l10n/app_strings.dart, which looks at [locale] under the hood.
/// [CricketScorerApp] (main.dart) wraps the whole app in a
/// ValueListenableBuilder on [locale], so calling [setLocale] rebuilds
/// every screen currently on the stack with the new language - no need to
/// pop back to a "settings applied" screen first.
class LocaleService {
  LocaleService._();

  static const _prefsKey = 'cricket_scorer_locale_v1';
  static const supportedLocales = ['en', 'bn'];

  /// Defaults to English until [load] resolves (called once from main(),
  /// before runApp) - avoids a flash of the wrong language on launch for
  /// anyone who has already picked Bangla.
  static final ValueNotifier<String> locale = ValueNotifier<String>('en');

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    if (saved != null && supportedLocales.contains(saved)) {
      locale.value = saved;
    }
  }

  static Future<void> setLocale(String code) async {
    if (!supportedLocales.contains(code) || code == locale.value) return;
    locale.value = code;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, code);
  }

  static Future<void> toggle() => setLocale(locale.value == 'en' ? 'bn' : 'en');
}
