import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'storage_service.dart';

/// Watches device connectivity and automatically retries pushing any
/// locally-saved-but-not-yet-cloud-synced TOURNAMENT data the instant the
/// device comes back online - see StorageService.syncPendingTournaments.
///
/// Deliberately scoped to tournaments only. Quick matches intentionally
/// stay manual-sync-only (see StorageService's class doc comment) - they're
/// often casual/throwaway games the person may not want auto-uploaded, so
/// this service never touches StorageService.syncPendingQuickMatches.
class ConnectivityService {
  ConnectivityService._();

  static StreamSubscription<List<ConnectivityResult>>? _sub;
  static bool _wasOffline = false;

  /// Call once from main(), after Supabase.initialize and after
  /// SessionService/auth are ready - starts listening for the
  /// offline -> online transition and fires a sync attempt right when it
  /// happens, instead of waiting for the person to happen to open a
  /// tournament screen (or tap "Sync Now") after reconnecting.
  static Future<void> start() async {
    await _sub?.cancel();
    final initial = await Connectivity().checkConnectivity();
    _wasOffline = initial.every((r) => r == ConnectivityResult.none);
    _sub = Connectivity().onConnectivityChanged.listen((results) {
      final isOffline = results.every((r) => r == ConnectivityResult.none);
      if (_wasOffline && !isOffline) {
        // Just came back online - fire and forget. syncPendingTournaments
        // is itself a no-op for guests and whenever nothing is pending, so
        // this is safe to call speculatively on every reconnect.
        StorageService.syncPendingTournaments().catchError((e) {
          debugPrint('[ConnectivityService] auto-sync failed: $e');
          return false;
        });
      }
      _wasOffline = isOffline;
    });
  }

  static Future<bool> isOnline() async {
    final results = await Connectivity().checkConnectivity();
    return results.any((r) => r != ConnectivityResult.none);
  }

  static void stop() {
    _sub?.cancel();
    _sub = null;
  }
}