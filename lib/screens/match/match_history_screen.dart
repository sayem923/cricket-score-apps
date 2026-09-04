import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../services/storage_service.dart';
import '../../services/session_service.dart';
import '../../widgets/download_scorecard_button.dart';
import '../../widgets/skeleton_loader.dart';
import '../../l10n/app_strings.dart';
import 'match_result_screen.dart';
import 'match_scorer_screen.dart';

class MatchHistoryScreen extends StatefulWidget {
  const MatchHistoryScreen({super.key});

  @override
  State<MatchHistoryScreen> createState() => _MatchHistoryScreenState();
}

class _MatchHistoryScreenState extends State<MatchHistoryScreen> {
  List<MatchResultData> _history = [];
  Set<String> _pendingIds = {};
  Set<String> _retrying = {};
  bool _loading = true;
  bool _syncingAll = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final history = await StorageService.loadQuickMatchHistory();
    final pendingIds = await StorageService.pendingQuickMatchIds();
    if (!mounted) return;
    setState(() {
      _history = history;
      _pendingIds = pendingIds;
      _loading = false;
    });
  }

  Future<void> _syncAll() async {
    if (SessionService.isGuest.value) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('sign_in_to_sync_cloud'))));
      return;
    }
    setState(() => _syncingAll = true);
    final count = await StorageService.syncPendingQuickMatches();
    if (!mounted) return;
    setState(() => _syncingAll = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(count > 0 ? tr('synced_count_matches').replaceFirst('%s', '$count') : tr('nothing_to_sync'))));
    _load();
  }

  Future<bool> _confirmDelete(MatchResultData m) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('delete_match_title')),
        content: Text(tr('delete_match_body').replaceFirst('%s', '${m.teamName1} vs ${m.teamName2}')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('cancel').toUpperCase())),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('delete').toUpperCase(), style: const TextStyle(color: Colors.red))),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _deleteMatch(MatchResultData m) async {
    await StorageService.deleteQuickMatch(m.id);
    if (!mounted) return;
    setState(() {
      _history.removeWhere((x) => x.id == m.id);
      _pendingIds.remove(m.id);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('match_deleted'))),
    );
  }

  Future<void> _retrySingle(MatchResultData m) async {
    setState(() => _retrying.add(m.id));
    final error = await StorageService.retryQuickMatchSync(m);
    if (!mounted) return;
    setState(() => _retrying.remove(m.id));

    if (error == null) {
      setState(() => _pendingIds.remove(m.id));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('synced_to_cloud')), backgroundColor: Colors.green),
      );
    } else {
      // Show the ACTUAL error (not just "failed") so it can be diagnosed
      // without needing to check the terminal/console.
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr('sync_failed')),
          content: SingleChildScrollView(child: Text(error)),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('ok')))],
        ),
      );
    }
  }

  void _continueMatch(MatchResultData m) {
    if (m.draft == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => MatchScorerScreen(draft: m.draft)),
    ).then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    final isGuest = SessionService.isGuest.value;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('match_history_title')),
        backgroundColor: const Color(0xFF00695C),
        foregroundColor: Colors.white,
        actions: [
          if (!isGuest && _pendingIds.isNotEmpty)
            _syncingAll
                ? const Padding(padding: EdgeInsets.all(16), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)))
                : IconButton(icon: const Icon(Icons.cloud_sync), tooltip: tr('sync_all_tooltip'), onPressed: _syncAll),
        ],
      ),
      body: _loading
          ? const MatchListSkeleton()
          : RefreshIndicator(
              onRefresh: _load,
              child: _history.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.all(24),
                      children: [
                        SizedBox(height: MediaQuery.of(context).size.height * 0.3),
                        Center(child: Text(tr('no_saved_matches_yet'), style: TextStyle(color: Colors.grey[600]))),
                        const SizedBox(height: 8),
                        Center(child: Text(tr('pull_down_to_refresh'), style: TextStyle(color: Colors.grey[400], fontSize: 12))),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _history.length,
                      itemBuilder: (context, index) {
                        final m = _history[index];
                        final isPending = _pendingIds.contains(m.id);
                        final isRetrying = _retrying.contains(m.id);
                        final subtitleText = isPending
                            ? (isGuest ? "${m.margin}  •  ${tr('saved_on_device_guest')}" : "${m.margin}  •  ${tr('not_synced_to_cloud')}")
                            : m.margin;
                        return Dismissible(
                          key: ValueKey(m.id),
                          direction: DismissDirection.endToStart,
                          confirmDismiss: (_) => _confirmDelete(m),
                          onDismissed: (_) => _deleteMatch(m),
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            margin: const EdgeInsets.only(bottom: 12),
                            decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(8)),
                            child: const Icon(Icons.delete, color: Colors.white),
                          ),
                          child: Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: InkWell(
                              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => MatchResultScreen(data: m))),
                              // Replaces ListTile here on purpose: ListTile's
                              // `trailing` slot has a fixed intrinsic width
                              // that can't grow past a certain point, so once
                              // this row could have 4 icons at once (continue/
                              // sync/download/delete) it started overflowing
                              // on narrower phones. A plain Row with the
                              // title+subtitle in Expanded (so THEY shrink
                              // first, not the icons) and compact/dense icon
                              // buttons fixes it for any screen width.
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      backgroundColor: m.isComplete ? const Color(0xFFE0F2F1) : Colors.orange.shade100,
                                      child: Icon(Icons.sports_cricket, color: m.isComplete ? const Color(0xFF00695C) : Colors.orange.shade800),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            "${m.teamName1} vs ${m.teamName2}",
                                            style: const TextStyle(fontWeight: FontWeight.bold),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            !m.isComplete ? "${tr('incomplete_label')}  •  $subtitleText" : subtitleText,
                                            style: TextStyle(color: !m.isComplete ? Colors.orange.shade800 : (isPending && !isGuest ? Colors.orange.shade800 : null)),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (!m.isComplete && m.draft != null)
                                          IconButton(
                                            icon: const Icon(Icons.play_circle_fill, color: Color(0xFF00695C)),
                                            tooltip: tr('continue_match_tooltip'),
                                            visualDensity: VisualDensity.compact,
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(),
                                            onPressed: () => _continueMatch(m),
                                          ),
                                        if (isPending && !isGuest) ...[
                                          const SizedBox(width: 6),
                                          isRetrying
                                              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                              : IconButton(
                                                  icon: const Icon(Icons.cloud_upload_outlined, color: Colors.orange),
                                                  tooltip: tr('save_to_cloud_tooltip'),
                                                  visualDensity: VisualDensity.compact,
                                                  padding: EdgeInsets.zero,
                                                  constraints: const BoxConstraints(),
                                                  onPressed: () => _retrySingle(m),
                                                ),
                                        ],
                                        const SizedBox(width: 6),
                                        DownloadScorecardButton(result: m, compact: true),
                                        const SizedBox(width: 6),
                                        IconButton(
                                          icon: const Icon(Icons.delete_outline, color: Colors.grey),
                                          tooltip: tr('delete_tooltip'),
                                          visualDensity: VisualDensity.compact,
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                          onPressed: () async {
                                            if (await _confirmDelete(m)) _deleteMatch(m);
                                          },
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
