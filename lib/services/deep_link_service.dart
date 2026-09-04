import 'package:flutter/material.dart';
import 'package:app_links/app_links.dart';
import '../screens/live/live_viewer_screen.dart';
import 'monitoring_service.dart';

/// Handles incoming deep links of the form:
///   cricketscorer://live/ABC123
///
/// Uses a custom URL *scheme* (cricketscorer://...) rather than branded
/// HTTPS App Links (https://yourapp.com/...) because that path needs a
/// domain you own plus a hosted verification file
/// (assetlinks.json / apple-app-site-association) - see the "no domain
/// yet" note in SETUP_NOTES_deep_linking.md. A custom scheme needs no
/// domain or hosting at all, at the cost of: (a) it won't preview nicely
/// as a tappable link inside some chat apps the way a real https:// link
/// does, and (b) there's no web fallback for someone without the app
/// installed - tapping it just does nothing on their device. Worth
/// upgrading to real App Links later once a domain exists; nothing here
/// needs to change on the app side to do that migration, only the
/// platform config (see setup notes).
///
/// Add more paths here as more shareable resources need direct links -
/// e.g. cricketscorer://match/<id> or cricketscorer://tournament/<id> -
/// following the same pattern as the 'live' case below.
class DeepLinkService {
  DeepLinkService._();

  static final _appLinks = AppLinks();

  /// Call once from main(), after runApp - needs a live [navigatorKey]
  /// (attached to MaterialApp) so it can push a screen without every
  /// screen having to thread a BuildContext down to this service.
  static Future<void> init(GlobalKey<NavigatorState> navigatorKey) async {
    // Handles the case where the app was NOT running and got launched
    // directly by tapping a link (cold start).
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) _handle(initialUri, navigatorKey);
    } catch (e, st) {
      // Never let a malformed initial link crash app startup.
      MonitoringService.recordError(e, st, reason: 'DeepLinkService.init getInitialLink');
    }

    // Handles the case where the app WAS already running (foreground or
    // background) and a link is tapped while it's alive.
    _appLinks.uriLinkStream.listen(
      (uri) => _handle(uri, navigatorKey),
      onError: (e, st) => MonitoringService.recordError(e, st, reason: 'DeepLinkService.uriLinkStream'),
    );
  }

  static void _handle(Uri uri, GlobalKey<NavigatorState> navigatorKey) {
    MonitoringService.log('deep link received: $uri');

    // Expect cricketscorer://live/ABC123 - uri.host is 'live', the code is
    // the first path segment. Guards against a link with no code
    // (cricketscorer://live) or an unrecognized host by simply doing
    // nothing rather than crashing/navigating somewhere wrong.
    if (uri.host == 'live' && uri.pathSegments.isNotEmpty) {
      final code = uri.pathSegments.first.toUpperCase();
      if (code.isEmpty) return;
      navigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => LiveViewerScreen(broadcastId: code)),
      );
    }
    // Add more `else if (uri.host == '...')` branches here as more
    // deep-linkable screens are added (match/tournament - see class doc).
  }

  /// Builds the shareable link for a live broadcast code, so every share
  /// call site constructs the same URL format instead of each hand-rolling
  /// its own string.
  static String liveLink(String broadcastCode) => 'cricketscorer://live/$broadcastCode';
}