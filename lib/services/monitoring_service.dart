import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Single entry point for crash reporting + basic product analytics via
/// Sentry - so screens never talk to the Sentry SDK directly.
///
/// Why Sentry instead of Firebase: this app's backend is Supabase, not
/// Firebase, so Sentry avoids standing up a whole separate Firebase
/// project just to get crash reports. Setup is one DSN string, no
/// google-services.json / gradle plugins / flutterfire configure.
///
/// Setup (do this once):
///  1. Add `sentry_flutter` to pubspec.yaml.
///  2. Create a free project at https://sentry.io (Platform: Flutter) and
///     copy its DSN.
///  3. In main(), BEFORE runApp, wrap startup like this:
///       await SentryFlutter.init(
///         (options) => options.dsn = 'YOUR_DSN_HERE',
///         appRunner: () => runApp(CricketScorerApp(...)),
///       );
///     SentryFlutter.init already sets up its own zone + FlutterError.onError
///     hooks internally, so you do NOT need a separate runZonedGuarded -
///     see main.dart, which now uses SentryFlutter.init's appRunner instead.
///
/// Design notes:
///  - Every method is a no-op (never throws) when no DSN has been
///    configured, so local development without a Sentry account doesn't
///    error out - it just silently doesn't report anything.
///  - User id is set (never email/name - PII) so crash reports can be
///    correlated per-account without storing anything identifying in
///    Sentry itself.
///  - "Analytics" here is intentionally minimal (breadcrumbs + a handful
///    of named events as Sentry messages) - Sentry is a crash/error tool
///    first, not a full analytics platform. If proper product analytics
///    (funnels, retention, dashboards) is ever needed, that's a separate,
///    later decision - this keeps today's ask (crash visibility) simple.
class MonitoringService {
  MonitoringService._();

  static bool get _enabled => Sentry.isEnabled;

  /// Tags every subsequent crash report / event with the logged-in
  /// account (or clears it back to anonymous on sign-out / guest mode).
  /// Pass Supabase's `auth.uid()`, never email or full name.
  static Future<void> setUserId(String? userId) async {
    if (!_enabled) return;
    await Sentry.configureScope((scope) {
      scope.setUser(userId == null ? null : SentryUser(id: userId));
    });
  }

  /// Records a non-fatal exception (e.g. inside a try/catch that already
  /// recovered) so it still shows up in Sentry for triage, without
  /// crashing the app.
  static Future<void> recordError(
    Object error,
    StackTrace? stack, {
    String? reason,
  }) async {
    debugPrint('[MonitoringService] error: $error\n$stack');
    if (!_enabled) return;
    await Sentry.captureException(
      error,
      stackTrace: stack,
      hint: reason == null ? null : Hint.withMap({'reason': reason}),
    );
  }

  /// Breadcrumb log - shows up alongside the next crash report so you can
  /// see what the person was doing right before it happened (e.g. "opened
  /// match scorer", "tapped save"). Cheap enough to sprinkle liberally.
  static void log(String message, {String category = 'app'}) {
    if (!_enabled) return;
    Sentry.addBreadcrumb(Breadcrumb(message: message, category: category));
  }

  static void setScreen(String screenName) => log('screen: $screenName', category: 'navigation');

  /// Named product event - logged as a breadcrumb (visible in the next
  /// crash's context) rather than a separate analytics pipeline, per the
  /// class doc above.
  static void logEvent(String name, {Map<String, Object>? params}) {
    if (!_enabled) return;
    Sentry.addBreadcrumb(Breadcrumb(
      message: name,
      category: 'event',
      data: params,
    ));
  }

  static void logMatchStarted({required String format}) =>
      logEvent('match_started', params: {'format': format});

  static void logMatchCompleted({required String format, required int overs}) =>
      logEvent('match_completed', params: {'format': format, 'overs': overs});

  static void logTournamentCreated() => logEvent('tournament_created');

  static void logScorecardShared({required String method}) =>
      logEvent('scorecard_shared', params: {'method': method});

  static void logLogin({required String method}) =>
      logEvent('login', params: {'method': method});

  static void logSignUp({required String method}) =>
      logEvent('sign_up', params: {'method': method});
}
