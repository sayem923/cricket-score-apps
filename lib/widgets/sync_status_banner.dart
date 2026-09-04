import 'dart:async';
import 'package:flutter/material.dart';
import '../services/storage_service.dart';

/// Slim, dismiss-free banner that shows up only when there's something
/// locally saved but not yet pushed to the cloud (see
/// StorageService.pendingQuickMatchIds/syncPendingQuickMatches) - the same
/// underlying data Match History's per-row cloud-upload icon already uses,
/// just surfaced app-wide instead of only after opening that screen.
/// Renders nothing at all once there's nothing pending, so it never adds
/// visual clutter for someone who's always online.
///
/// This checks the LOCAL pending queue, not actual network connectivity
/// (the app has no network-state package wired in) - "pending" already
/// implies "couldn't reach the cloud last time it tried", which is the
/// signal that actually matters here.
class SyncStatusBanner extends StatefulWidget {
  const SyncStatusBanner({super.key});

  @override
  State<SyncStatusBanner> createState() => _SyncStatusBannerState();
}

class _SyncStatusBannerState extends State<SyncStatusBanner> {
  int _pendingCount = 0;
  bool _syncing = false;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _refreshCount();
    // Re-checks periodically (e.g. after a match finishes elsewhere in the
    // app, or a background retry succeeds) without needing every screen
    // that can change the pending queue to know about this banner and
    // notify it directly.
    _pollTimer = Timer.periodic(const Duration(seconds: 20), (_) => _refreshCount());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshCount() async {
    final ids = await StorageService.pendingQuickMatchIds();
    if (!mounted) return;
    setState(() => _pendingCount = ids.length);
  }

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    try {
      await StorageService.syncPendingQuickMatches();
    } catch (_) {
      // Sync failures already surface per-match in Match History (retry
      // icon) - this banner only needs to reflect the count, not duplicate
      // that error handling.
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
    await _refreshCount();
  }

  @override
  Widget build(BuildContext context) {
    if (_pendingCount == 0) return const SizedBox.shrink();
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
              _pendingCount == 1 ? "1 match not synced to cloud yet" : "$_pendingCount matches not synced to cloud yet",
              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          _syncing
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : TextButton(
                  onPressed: _syncNow,
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10), minimumSize: Size.zero, foregroundColor: Colors.white),
                  child: const Text("Sync Now", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                ),
        ],
      ),
    );
  }
}