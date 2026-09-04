import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'screens/auth/auth_gate.dart';
import 'screens/onboarding/onboarding_screen.dart';
import 'theme/app_theme.dart';
import 'services/locale_service.dart';
import 'services/onboarding_service.dart';
import 'services/connectivity_service.dart';
import 'services/monitoring_service.dart';
import 'services/deep_link_service.dart';
import 'services/push_notification_service.dart';
import 'widgets/error_boundary.dart';

/// Environment-specific config, supplied at build/run time instead of
/// hardcoded, so the same code can point at a dev/staging/prod Supabase
/// project without editing source:
///   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
/// Falls back to the original project so existing local `flutter run`
/// commands (with no --dart-define flags) keep working unchanged.
const _supabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'https://qtmcbhlsysdugsmhuozj.supabase.co',
);
const _supabaseAnonKey = String.fromEnvironment(
  'SUPABASE_ANON_KEY',
  defaultValue: 'sb_publishable_Ai0YgSatLP-tYNAnpIjBKg_79j5xgaz',
);

/// Sentry DSN - paste the value from your Sentry project's Settings ->
/// Client Keys (DSN) page. Left blank by default: Sentry's own SDK treats
/// an empty DSN as "disabled", so the app runs completely normally (crash
/// reporting simply does nothing) until this is filled in - no separate
/// on/off flag needed.
const _sentryDsn = String.fromEnvironment('SENTRY_DSN', defaultValue: '');

/// OneSignal App ID - from your app's Settings -> Keys & IDs page at
/// onesignal.com. Left blank by default: PushNotificationService.init
/// treats an empty id as "disabled", same no-op-until-configured pattern
/// as the Sentry DSN above.
const _oneSignalAppId = String.fromEnvironment('ONESIGNAL_APP_ID', defaultValue: '');

Future<void> main() async {
  // SentryFlutter.init wraps `appRunner` in its own error zone and already
  // installs FlutterError.onError + a zone error handler internally, so
  // there's no need for a separate runZonedGuarded here - one source of
  // truth for "what counts as a crash" instead of two overlapping ones.
  await SentryFlutter.init((options) {
    options.dsn = _sentryDsn;
    // Keep console logging in debug too, so nothing regresses locally
    // just because Sentry is (or isn't) configured.
    options.debug = kDebugMode;
  }, appRunner: () async {
    WidgetsFlutterBinding.ensureInitialized();

    // Show the on-brand fallback screen instead of Flutter's default red
    // screen-of-death for widget build/layout/paint errors. Sentry's own
    // FlutterError.onError hook (installed above) still reports the error;
    // this only controls what the person on-screen sees.
    kReleaseModeSafe = kReleaseMode;
    ErrorWidget.builder = (details) => AppErrorScreen(details: details);

    await Supabase.initialize(url: _supabaseUrl, publishableKey: _supabaseAnonKey);

    // Restore the person's last-chosen language before the first frame, so
    // there's no flash of English for someone who picked Bangla last time.
    await LocaleService.load();
    // Resolved once here (rather than inside a FutureBuilder) so there's no
    // loading flicker before the very first frame - same reasoning as the
    // locale load above.
    final seenOnboarding = await OnboardingService.hasSeenOnboarding();
    // #7 - offline mode + auto-sync: starts watching connectivity so any
    // tournament change that couldn't reach the cloud (see
    // StorageService.saveTournaments) gets retried automatically the moment
    // the device is back online, without the person needing to do anything.
    await ConnectivityService.start();

    // Keep crash reports tagged with the current account so any report
    // can be traced back to a user id (never email/name - see
    // MonitoringService doc comment) across login/logout/guest toggles.
    await MonitoringService.setUserId(Supabase.instance.client.auth.currentUser?.id);
    unawaited(PushNotificationService.setExternalUserId(Supabase.instance.client.auth.currentUser?.id));
    Supabase.instance.client.auth.onAuthStateChange.listen((state) {
      MonitoringService.setUserId(state.session?.user.id);
      unawaited(PushNotificationService.setExternalUserId(state.session?.user.id));
    });

    runApp(CricketScorerApp(seenOnboarding: seenOnboarding));

    // Must run AFTER runApp - it needs `navigatorKey` attached to a live
    // MaterialApp so it can push a screen when a link arrives.
    unawaited(DeepLinkService.init(navigatorKey));
    unawaited(PushNotificationService.init(_oneSignalAppId, navigatorKey));
  });
}

/// Global navigator key so DeepLinkService can push a screen from outside
/// the widget tree (it has no BuildContext of its own) - see
/// services/deep_link_service.dart.
final navigatorKey = GlobalKey<NavigatorState>();

class CricketScorerApp extends StatelessWidget {
  final bool seenOnboarding;
  const CricketScorerApp({super.key, required this.seenOnboarding});

  @override
  Widget build(BuildContext context) {
    // Strings are read via the plain tr() helper (lib/l10n/app_strings.dart)
    // rather than Flutter's Locale-based localization, so nothing below
    // rebuilds on its own when the language changes - wrapping the whole
    // MaterialApp in this ValueListenableBuilder is what makes every
    // on-screen tr() call refresh the moment LocaleService.setLocale runs.
    return ValueListenableBuilder<String>(
      valueListenable: LocaleService.locale,
      builder: (context, _, __) {
        return MaterialApp(
          navigatorKey: navigatorKey,
          title: 'Pro Cricket Scorer',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.themeData,
          home: _RootGate(seenOnboarding: seenOnboarding),
        );
      },
    );
  }
}

/// Shows the onboarding walkthrough at most once (first launch only), then
/// hands off to [AuthGate] for the normal login/guest/home flow. Kept as
/// its own tiny widget (rather than baking the branch into
/// [CricketScorerApp]) so "onboarding just finished" is local state here,
/// not something that has to round-trip through MaterialApp.home again.
class _RootGate extends StatefulWidget {
  final bool seenOnboarding;
  const _RootGate({required this.seenOnboarding});

  @override
  State<_RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<_RootGate> {
  late bool _seenOnboarding = widget.seenOnboarding;

  @override
  Widget build(BuildContext context) {
    if (!_seenOnboarding) {
      return OnboardingScreen(onDone: () => setState(() => _seenOnboarding = true));
    }
    return const AuthGate();
  }
}