import 'dart:async';
import 'package:flutter/material.dart';
import '../services/storage_service.dart';
import '../l10n/app_strings.dart';

/// Slim, dismiss-free banner - same shape and behavior as SyncStatusBanner,
/// but for TOURNAMENT data instead of quick matches. Shows up only when a
/// saveTournaments() call had to fall back to local-only because the cloud
/// push failed (see StorageService.hasPendingTournamentSync); renders
/// nothing once everything's synced.
///
/// Normally this resolves itself automatically - ConnectivityService
/// retries the moment the device comes back online - so in practice this
/// banner is mostly a visible confirmation that "yes, it's handled", plus
/// a manual fallback button in case the automatic retry didn't fire (e.g.
/// connectivity flapped in a way the plugin didn't catch).
class TournamentSyncStatusBanner extends StatefulWidget {
  const TournamentSyncStatusBanner({super.key});

  @override
  State<TournamentSyncStatusBanner> createState() => _TournamentSyncStatusBannerState();
}

class _TournamentSyncStatusBannerState extends State<TournamentSyncStatusBanner> {
  bool _pending = false;
  bool _syncing = false;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _refresh();
    // Re-checks periodically so this reflects ConnectivityService's
    // automatic retries too, not just this banner's own manual button.
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final pending = await StorageService.hasPendingTournamentSync();
    if (!mounted) return;
    setState(() => _pending = pending);
  }

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    try {
      await StorageService.syncPendingTournaments();
    } catch (_) {
      // Swallow here - _refresh() below reflects whatever state resulted,
      // and this banner's job is just to reflect status, not surface a
      // separate error UI for what's already a background best-effort sync.
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    if (!_pending) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: Colors.orange.shade800,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.cloud_off, color: Colors.white, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              tr('tournament_not_synced'),
              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          _syncing
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : TextButton(
                  onPressed: _syncNow,
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10), minimumSize: Size.zero, foregroundColor: Colors.white),
                  child: Text(tr('sync_now'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                ),
        ],
      ),
    );
  }
}