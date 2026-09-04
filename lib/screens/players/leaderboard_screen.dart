import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../services/storage_service.dart';
import '../../l10n/app_strings.dart';
import '../../utils/extensions.dart';
import '../../widgets/skeleton_loader.dart';
import 'player_detail_screen.dart';

/// Cross-account rankings from the same `player_career_stats` table that
/// powers PlayerDetailScreen - "Most Runs" and "Most Wickets", the two
/// categories every grassroots scoring app (CricHeroes etc.) leads with.
class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> with SingleTickerProviderStateMixin {
  static const _teal = Color(0xFF00695C);

  late final TabController _tabController;
  Future<List<({GlobalPlayer player, PlayerStat stat})>>? _battingFuture;
  Future<List<({GlobalPlayer player, PlayerStat stat})>>? _bowlingFuture;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _battingFuture = StorageService.loadLeaderboard(metric: 'runs');
    _bowlingFuture = StorageService.loadLeaderboard(metric: 'wickets');
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F5),
      appBar: AppBar(
        title: Text(tr('leaderboard_title')),
        backgroundColor: _teal,
        foregroundColor: Colors.white,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          tabs: const [
            Tab(text: 'Most Runs', icon: Icon(Icons.sports_cricket, size: 18)),
            Tab(text: 'Most Wickets', icon: Icon(Icons.sports_baseball, size: 18)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _LeaderboardList(future: _battingFuture!, mode: _LeaderboardMode.batting),
          _LeaderboardList(future: _bowlingFuture!, mode: _LeaderboardMode.bowling),
        ],
      ),
    );
  }
}

enum _LeaderboardMode { batting, bowling }

class _LeaderboardList extends StatelessWidget {
  final Future<List<({GlobalPlayer player, PlayerStat stat})>> future;
  final _LeaderboardMode mode;

  const _LeaderboardList({required this.future, required this.mode});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<({GlobalPlayer player, PlayerStat stat})>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const MatchListSkeleton();
        }
        final entries = snapshot.data ?? [];
        if (entries.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.leaderboard_outlined, size: 48, color: Colors.grey.shade400),
                  const SizedBox(height: 12),
                  Text(
                    'No stats yet. Play and sync a few matches to see rankings here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: entries.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) => _LeaderboardTile(
            rank: index + 1,
            player: entries[index].player,
            stat: entries[index].stat,
            mode: mode,
          ),
        );
      },
    );
  }
}

class _LeaderboardTile extends StatelessWidget {
  final int rank;
  final GlobalPlayer player;
  final PlayerStat stat;
  final _LeaderboardMode mode;

  const _LeaderboardTile({required this.rank, required this.player, required this.stat, required this.mode});

  Color get _rankColor {
    switch (rank) {
      case 1:
        return const Color(0xFFD4AF37); // gold
      case 2:
        return const Color(0xFF9AA5AE); // silver
      case 3:
        return const Color(0xFFB8752D); // bronze
      default:
        return Colors.grey.shade400;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isBatting = mode == _LeaderboardMode.batting;
    final primaryValue = isBatting ? '${stat.runs}' : '${stat.wickets}';
    final primaryLabel = isBatting ? 'runs' : 'wkts';
    final secondary = isBatting
        ? '${stat.matches} matches  •  Avg ${stat.avg < 0 ? '-' : stat.avg.toStringAsFixed(1)}  •  HS ${stat.highestScore}'
        : '${stat.matches} matches  •  Econ ${stat.oversBowled > 0 ? stat.econ.toStringAsFixed(1) : '-'}  •  BB ${stat.wickets > 0 ? stat.bestBowling : '-'}';

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerDetailScreen(player: player))),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              SizedBox(
                width: 28,
                child: rank <= 3
                    ? Icon(Icons.emoji_events, color: _rankColor, size: 24)
                    : Text('$rank', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey.shade600)),
              ),
              const SizedBox(width: 8),
              CircleAvatar(
                radius: 20,
                backgroundColor: const Color(0xFFE0F2F1),
                backgroundImage: player.photoUrl != null ? NetworkImage(player.photoUrl!) : null,
                child: player.photoUrl == null ? const Icon(Icons.person, color: Color(0xFF00695C)) : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(player.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(secondary, style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(primaryValue, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: Color(0xFF00695C))),
                  Text(primaryLabel, style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
