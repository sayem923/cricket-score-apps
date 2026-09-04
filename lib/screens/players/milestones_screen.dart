import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../services/storage_service.dart';
import 'player_detail_screen.dart';
import '../../l10n/app_strings.dart';

/// Feed of every milestone (50/100/5-wicket-haul/etc) any player has newly
/// crossed, most recent first - see StorageService._detectNewMilestones for
/// how "newly crossed" is worked out. Read state is purely local per
/// device (StorageService.markMilestonesSeen), not synced across devices.
class MilestonesScreen extends StatefulWidget {
  const MilestonesScreen({super.key});

  @override
  State<MilestonesScreen> createState() => _MilestonesScreenState();
}

class _MilestonesScreenState extends State<MilestonesScreen> {
  static const _teal = Color(0xFF00695C);
  late Future<List<Milestone>> _future;

  @override
  void initState() {
    super.initState();
    _future = StorageService.loadRecentMilestones();
    // Marking seen using the latest milestone's own server timestamp
    // (not the device's clock - see StorageService.markMilestonesSeen for
    // why) as soon as the feed opens - matches how most notification-bell
    // UIs behave (opening the list clears the badge, regardless of
    // whether every item has actually been read).
    _future.then((milestones) {
      if (milestones.isNotEmpty) {
        StorageService.markMilestonesSeen(latestMilestoneAt: milestones.first.createdAt);
      }
    });
  }

  String _timeAgo(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${t.day}/${t.month}/${t.year}';
  }

  IconData _iconFor(String label) {
    if (label.contains('Century') || label.contains('Centuries')) return Icons.emoji_events;
    if (label.contains('Fifty') || label.contains('Fifties')) return Icons.star;
    if (label.contains('Wicket Haul')) return Icons.local_fire_department;
    if (label.contains('Wickets')) return Icons.sports_baseball;
    if (label.contains('Runs')) return Icons.sports_cricket;
    if (label.contains('Matches')) return Icons.event_available;
    return Icons.military_tech;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F5),
      appBar: AppBar(title: Text(tr('milestones_title')), backgroundColor: _teal, foregroundColor: Colors.white),
      body: FutureBuilder<List<Milestone>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: _teal));
          }
          final milestones = snapshot.data ?? [];
          if (milestones.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.notifications_none, size: 48, color: Colors.grey.shade400),
                    const SizedBox(height: 12),
                    Text(tr('no_milestones_yet'), style: TextStyle(color: Colors.grey.shade600)),
                    const SizedBox(height: 4),
                    Text(
                      "You'll see it here the moment a player crosses one (50, 100, 5-wicket haul, etc) in a synced match.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: milestones.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final m = milestones[index];
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: const Color(0xFFE0F2F1),
                  child: Icon(_iconFor(m.badgeLabel), color: _teal, size: 20),
                ),
                title: RichText(
                  text: TextSpan(
                    style: const TextStyle(color: Colors.black87, fontSize: 14),
                    children: [
                      TextSpan(text: m.playerName, style: const TextStyle(fontWeight: FontWeight.bold)),
                      const TextSpan(text: ' reached '),
                      TextSpan(text: m.badgeLabel, style: const TextStyle(fontWeight: FontWeight.bold, color: _teal)),
                    ],
                  ),
                ),
                subtitle: Text(_timeAgo(m.createdAt), style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PlayerDetailScreen(player: GlobalPlayer(id: m.playerId, name: m.playerName)),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}