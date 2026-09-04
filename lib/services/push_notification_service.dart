import 'package:flutter/material.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import '../screens/live/live_viewer_screen.dart';
import 'monitoring_service.dart';

/// Wraps OneSignal so screens never talk to the SDK directly.
///
/// Why OneSignal instead of raw Firebase Cloud Messaging: this app's
/// backend is Supabase, not Firebase (same reasoning as choosing Sentry
/// over Firebase Crashlytics - see monitoring_service.dart). OneSignal
/// still uses FCM under the hood on Android, but manages that Firebase
/// project FOR you - the app only needs a OneSignal App ID, no
/// google-services.json, no gradle plugin.
///
/// Setup (do this once):
///  1. Add `onesignal_flutter` to pubspec.yaml.
///  2. Create a free app at https://onesignal.com -> New App -> pick
///     Google Android (and Apple iOS if needed) -> copy the OneSignal App ID.
///  3. Call `PushNotificationService.init('YOUR_ONESIGNAL_APP_ID')` from
///     main(), after runApp (see main.dart).
///
/// How sending actually works day-to-day:
///  - Manual: OneSignal dashboard -> Messages -> New Push -> write it,
///    send to "All Subscribed Users" (or a segment). No code needed at
///    all for an announcement like "app updated, please update".
///  - Targeted at one account: call [setExternalUserId] (already wired
///    to auth state - see main.dart) with the Supabase user id, then
///    from OneSignal's dashboard/API you can target that exact person.
///  - Automatic, triggered by an app event (e.g. "a tournament match just
///    went live"): needs a small server-side call to OneSignal's REST
///    API with your OneSignal REST API key - that key must NEVER ship
///    inside the Flutter app (anyone could decompile the app and spam
///    notifications with it). Do that call from a Supabase Edge Function
///    instead - see SETUP_NOTES_push_notifications.md for a ready-to-use
///    example function.
class PushNotificationService {
  PushNotificationService._();

  /// Call once from main(), after runApp. Needs [navigatorKey] (the same
  /// one DeepLinkService uses) so tapping a notification can navigate
  /// straight to the relevant screen without a BuildContext.
  static Future<void> init(String oneSignalAppId, GlobalKey<NavigatorState> navigatorKey) async {
    if (oneSignalAppId.isEmpty) return; // no-op until configured, same pattern as Sentry's empty-DSN check

    OneSignal.initialize(oneSignalAppId);

    // OneSignal's own in-app prompt, shown once. If the person taps "Don't
    // Allow" here that's a real choice to respect - don't re-prompt on
    // every launch (OneSignal itself won't, this is just documenting why
    // there's no retry loop here).
    OneSignal.Notifications.requestPermission(true);

    OneSignal.Notifications.addClickListener((event) {
      _handleNotificationClick(event, navigatorKey);
    });
  }

  static void _handleNotificationClick(OSNotificationClickEvent event, GlobalKey<NavigatorState> navigatorKey) {
    final data = event.notification.additionalData;
    MonitoringService.log('push notification tapped: ${event.notification.notificationId}');

    // Convention: a notification about a live match includes
    // {"broadcastId": "ABC123"} in its "Additional Data" (set this when
    // sending, either from the dashboard's Additional Data field or the
    // REST API payload's `data` key). Anything else is just opened to
    // the app's normal home screen (the default behavior of tapping a
    // notification with no custom data).
    final broadcastId = data?['broadcastId'] as String?;
    if (broadcastId != null && broadcastId.isNotEmpty) {
      navigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => LiveViewerScreen(broadcastId: broadcastId)),
      );
    }
  }

  /// Links the current OneSignal subscription to the logged-in Supabase
  /// account, so a notification can be targeted at "this specific
  /// person" (e.g. from a server-side call) rather than only broadcast
  /// to everyone. Pass null on sign-out / guest mode to unlink.
  static Future<void> setExternalUserId(String? userId) async {
    if (userId == null) {
      await OneSignal.logout();
    } else {
      await OneSignal.login(userId);
    }
  }
}