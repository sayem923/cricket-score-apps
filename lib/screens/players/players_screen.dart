import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../services/storage_service.dart';
import '../../l10n/app_strings.dart';
import 'player_detail_screen.dart';
import 'merge_players_screen.dart';
import 'leaderboard_screen.dart';
import 'compare_players_screen.dart';
import 'milestones_screen.dart';

/// Entry point for the global player registry - search any player added
/// from any account, add a new one, or resolve duplicates via merge.
/// Hook this in from home_screen.dart's card grid alongside Teams/Photos.
class PlayersScreen extends StatefulWidget {
  const PlayersScreen({super.key});

  @override
  State<PlayersScreen> createState() => _PlayersScreenState();
}

class _PlayersScreenState extends State<PlayersScreen> {
  final _searchController = TextEditingController();
  List<GlobalPlayer> _results = [];
  bool _loading = true;
  bool _isAdmin = false;
  int _unseenMilestones = 0;

  @override
  void initState() {
    super.initState();
    _search('');
    StorageService.isCurrentUserAdmin().then((isAdmin) {
      if (mounted) setState(() => _isAdmin = isAdmin);
    });
    _refreshUnseenMilestones();
  }

  Future<void> _refreshUnseenMilestones() async {
    final count = await StorageService.countUnseenMilestones();
    if (mounted) setState(() => _unseenMilestones = count);
  }

  Future<void> _search(String query) async {
    setState(() => _loading = true);
    final results = await StorageService.searchGlobalPlayers(query);
    if (!mounted) return;
    setState(() {
      _results = results;
      _loading = false;
    });
  }

  Future<void> _promptAddPlayer() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('add_player_title')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: tr('player_name_label')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('cancel_word'))),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(tr('add')),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final id = await StorageService.findOrCreateGlobalPlayer(name);
    if (id == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('sign_in_required_registry'))),
      );
      return;
    }
    _search(_searchController.text);
  }

  Future<void> _confirmDelete(GlobalPlayer player) async {
    final typedController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final matches = typedController.text.trim() == player.name;
          return AlertDialog(
            title: Text(tr('delete_player_title')),
            // Wrapped in SingleChildScrollView - same fix as the merge
            // confirmation dialog: autofocus:true opens the keyboard
            // immediately, which needs room to shrink into.
            content: SingleChildScrollView(
              child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '"${player.name}" and all of their career stats and match history will be '
                  "permanently removed from the shared registry. This can't be undone.",
                ),
                const SizedBox(height: 16),
                Text(tr('type_name_to_confirm').replaceFirst('%s', player.name), style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                TextField(
                  controller: typedController,
                  autofocus: true,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                  onChanged: (_) => setDialogState(() {}),
                ),
              ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('cancel_word'))),
              TextButton(
                onPressed: matches ? () => Navigator.pop(context, true) : null,
                child: Text(tr('delete'), style: const TextStyle(color: Colors.red)),
              ),
            ],
          );
        },
      ),
    );
    if (confirmed != true) return;

    try {
      await StorageService.deletePlayer(player.id);
      _search(_searchController.text);
    } catch (e) {
      if (!mounted) return;
      // Surfaced as-is - e.g. a non-admin who somehow got here sees
      // exactly "Only admins can delete players" from the RPC, and a
      // deletion blocked by dependents sees exactly why.
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr('delete_failed')),
          content: SingleChildScrollView(child: Text('$e')),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('ok')))],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('players_title')),
        actions: [
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.notifications_outlined),
                tooltip: 'Milestones',
                visualDensity: VisualDensity.compact,
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const MilestonesScreen()),
                  );
                  _refreshUnseenMilestones();
                },
              ),
              if (_unseenMilestones > 0)
                Positioned(
                  top: 8,
                  right: 8,
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      constraints: const BoxConstraints(minWidth: 15, minHeight: 15),
                      decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(8)),
                      child: Text(
                        _unseenMilestones > 9 ? '9+' : '$_unseenMilestones',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.compare_arrows),
            tooltip: 'Compare players',
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ComparePlayersScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.leaderboard),
            tooltip: 'Leaderboard',
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LeaderboardScreen()),
            ),
          ),
          // Merging permanently combines two players' career stats and
          // can't be undone from the app - only shown to registry admins.
          // Even if a non-admin somehow reaches MergePlayersScreen, the
          // actual merge call is still rejected server-side.
          if (_isAdmin)
            IconButton(
              icon: const Icon(Icons.merge_type),
              tooltip: 'Merge duplicate players',
              visualDensity: VisualDensity.compact,
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const MergePlayersScreen()),
                );
                _search(_searchController.text);
              },
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText: tr('search_player'),
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
              ),
              onChanged: _search,
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          Expanded(
            child: _results.isEmpty && !_loading
                ? Center(child: Text(tr('no_players_found')))
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final player = _results[index];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFFE0F2F1),
                          backgroundImage: player.photoUrl != null ? NetworkImage(player.photoUrl!) : null,
                          child: player.photoUrl == null ? const Icon(Icons.person, color: Color(0xFF00695C)) : null,
                        ),
                        title: Text(player.name),
                        trailing: _isAdmin
                            ? IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.red),
                                tooltip: 'Delete player',
                                onPressed: () => _confirmDelete(player),
                              )
                            : const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => PlayerDetailScreen(player: player)),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _promptAddPlayer,
        child: const Icon(Icons.add),
      ),
    );
  }
}
