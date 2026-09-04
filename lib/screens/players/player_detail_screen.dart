import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../models/models.dart';
import '../../services/storage_service.dart';
import '../../l10n/app_strings.dart';
import '../../utils/extensions.dart';
import '../../widgets/form_graph.dart';

/// Shows a player's full career stats, aggregated across every match from
/// every account (the `player_career_stats` global table) - not just the
/// matches recorded from this device/account. Cricbuzz-style profile
/// header (photo + name over a gradient banner) with tappable stat
/// highlight chips and sectioned batting/bowling scorecards below.
class PlayerDetailScreen extends StatefulWidget {
  final GlobalPlayer player;

  const PlayerDetailScreen({super.key, required this.player});

  @override
  State<PlayerDetailScreen> createState() => _PlayerDetailScreenState();
}

class _PlayerDetailScreenState extends State<PlayerDetailScreen> {
  static const _teal = Color(0xFF00695C);
  static const _tealDark = Color(0xFF00251A);

  late GlobalPlayer _player;
  Future<PlayerStat?>? _statsFuture;
  Future<List<MatchPerformance>>? _recentMatchesFuture;
  bool _uploadingPhoto = false;

  @override
  void initState() {
    super.initState();
    _player = widget.player;
    _statsFuture = StorageService.loadCareerStats(_player.id, _player.name);
    _recentMatchesFuture = StorageService.loadRecentPerformances(_player.id);
  }

  Future<void> _pickPhoto(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source, imageQuality: 85, maxWidth: 800);
    if (picked == null) return;
    setState(() => _uploadingPhoto = true);
    final bytes = await picked.readAsBytes();
    final ext = picked.name.contains('.') ? picked.name.split('.').last : 'jpg';
    final result = await StorageService.uploadPlayerPhoto(_player.id, bytes, ext);
    if (!mounted) return;
    setState(() {
      _uploadingPhoto = false;
      if (result.url != null) _player = _player.copyWith(photoUrl: result.url);
    });
    if (result.url == null) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr('couldnt_upload_photo')),
          content: SingleChildScrollView(child: Text(result.error ?? "Unknown error")),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('ok')))],
        ),
      );
    }
  }

  void _showPhotoOptions() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(tr('player_photo'), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt, color: _teal),
              title: Text(tr('take_photo')),
              onTap: () {
                Navigator.pop(context);
                _pickPhoto(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: _teal),
              title: Text(tr('choose_from_gallery')),
              onTap: () {
                Navigator.pop(context);
                _pickPhoto(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F5),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 240,
            backgroundColor: _teal,
            foregroundColor: Colors.white,
            elevation: 0,
            flexibleSpace: FlexibleSpaceBar(
              background: _ProfileHeader(
                player: _player,
                uploading: _uploadingPhoto,
                onEditPhoto: _showPhotoOptions,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: FutureBuilder<PlayerStat?>(
              future: _statsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.only(top: 80),
                    child: Center(child: CircularProgressIndicator(color: _teal)),
                  );
                }
                final stat = snapshot.data;
                if (stat == null || stat.matches == 0) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 80, horizontal: 24),
                    child: Column(
                      children: [
                        Icon(Icons.sports_cricket, size: 48, color: Colors.grey.shade400),
                        const SizedBox(height: 12),
                        Text(tr('no_matches_recorded_yet'), style: TextStyle(color: Colors.grey.shade600, fontSize: 15)),
                      ],
                    ),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _HighlightRow(stat: stat),
                      if (stat.earnedBadges.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _BadgeRow(badges: stat.earnedBadges),
                      ],
                      const SizedBox(height: 20),
                      _StatCard(
                        title: 'Batting',
                        icon: Icons.sports_cricket,
                        color: const Color(0xFF0284C7),
                        rows: [
                          _row3('Matches', '${stat.matches}', 'Innings', '${stat.innings}', 'Not Outs', '${stat.notOuts}'),
                          _row3('Runs', '${stat.runs}', 'Balls', '${stat.balls}', 'Highest', '${stat.highestScore}'),
                          _row3('Average', stat.avg < 0 ? '-' : stat.avg.toStringAsFixed(2), 'Strike Rate', stat.sr.toStringAsFixed(2), '4s / 6s', '${stat.fours}/${stat.sixes}'),
                          _row3('100s', '${stat.hundreds}', '50s', '${stat.fifties}', '90s', '${stat.nineties}'),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _StatCard(
                        title: 'Bowling',
                        icon: Icons.sports_baseball,
                        color: const Color(0xFFD97706),
                        rows: [
                          _row3('Wickets', '${stat.wickets}', 'Overs', stat.oversBowled.toStringAsFixed(1), 'Runs', '${stat.runsConceded}'),
                          _row3('Economy', stat.oversBowled > 0 ? stat.econ.toStringAsFixed(2) : '-', 'Average', stat.wickets > 0 ? stat.bowlAvg.toStringAsFixed(2) : '-', 'Strike Rate', stat.wickets > 0 ? stat.bowlSr.toStringAsFixed(2) : '-'),
                          _row3('Best Bowling', stat.wickets > 0 ? stat.bestBowling : '-', '4-Wkt Hauls', '${stat.fourWickets}', '', ''),
                        ],
                      ),
                      const SizedBox(height: 16),
                      FutureBuilder<List<MatchPerformance>>(
                        future: _recentMatchesFuture,
                        builder: (context, matchSnapshot) {
                          final performances = matchSnapshot.data ?? [];
                          if (matchSnapshot.connectionState == ConnectionState.waiting || performances.isEmpty) {
                            return const SizedBox.shrink();
                          }
                          return _RecentMatchesCard(performances: performances);
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  List<_StatCell> _row3(String l1, String v1, String l2, String v2, String l3, String v3) {
    return [
      _StatCell(l1, v1),
      _StatCell(l2, v2),
      _StatCell(l3, v3),
    ];
  }
}

class _ProfileHeader extends StatelessWidget {
  final GlobalPlayer player;
  final bool uploading;
  final VoidCallback onEditPhoto;

  const _ProfileHeader({required this.player, required this.uploading, required this.onEditPhoto});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF00897B), Color(0xFF00251A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              const Spacer(),
              GestureDetector(
                onTap: onEditPhoto,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.25), blurRadius: 10, offset: const Offset(0, 4))],
                      ),
                      child: CircleAvatar(
                        radius: 44,
                        backgroundColor: Colors.white.withOpacity(0.15),
                        backgroundImage: player.photoUrl != null ? NetworkImage(player.photoUrl!) : null,
                        child: uploading
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : (player.photoUrl == null ? const Icon(Icons.person, size: 44, color: Colors.white) : null),
                      ),
                    ),
                    Positioned(
                      bottom: -2,
                      right: -2,
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: const BoxDecoration(
                          color: Color(0xFFF59E0B),
                          shape: BoxShape.circle,
                          border: Border.fromBorderSide(BorderSide(color: Colors.white, width: 1.5)),
                        ),
                        child: const Icon(Icons.camera_alt, size: 14, color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                player.name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 0.3),
              ),
              const SizedBox(height: 2),
              Text(
                "Player Profile",
                style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 12, letterSpacing: 0.6, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HighlightRow extends StatelessWidget {
  final PlayerStat stat;
  const _HighlightRow({required this.stat});

  @override
  Widget build(BuildContext context) {
    final items = [
      _Highlight('Matches', '${stat.matches}', Icons.event),
      _Highlight('Runs', '${stat.runs}', Icons.sports_cricket),
      _Highlight('Wickets', '${stat.wickets}', Icons.sports_baseball),
      _Highlight('Avg', stat.avg < 0 ? '-' : stat.avg.toStringAsFixed(1), Icons.bar_chart),
    ];
    return Row(
      children: [
        for (int i = 0; i < items.length; i++)
          Expanded(
            child: Container(
              margin: EdgeInsets.only(
                left: i == 0 ? 0 : 4,
                right: i == items.length - 1 ? 0 : 4,
              ),
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 6, offset: const Offset(0, 2))],
              ),
              child: Column(
                children: [
                  Icon(items[i].icon, size: 18, color: const Color(0xFF00695C)),
                  const SizedBox(height: 6),
                  Text(items[i].value, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF102A22))),
                  const SizedBox(height: 2),
                  Text(items[i].label, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Highlight {
  final String label;
  final String value;
  final IconData icon;
  _Highlight(this.label, this.value, this.icon);
}

class _BadgeRow extends StatelessWidget {
  final List<PlayerBadge> badges;
  const _BadgeRow({required this.badges});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.military_tech, size: 16, color: Color(0xFF00695C)),
              const SizedBox(width: 6),
              Text(tr('achievements'), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey.shade700)),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: badges
                .map((b) => Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: b.color.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: b.color.withOpacity(0.3)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(b.icon, size: 14, color: b.color),
                          const SizedBox(width: 5),
                          Text(b.label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: b.color)),
                        ],
                      ),
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _StatCell {
  final String label;
  final String value;
  _StatCell(this.label, this.value);
}

class _StatCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final List<List<_StatCell>> rows;

  const _StatCard({required this.title, required this.icon, required this.color, required this.rows});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: color.withOpacity(0.08),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 8),
                Text(title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: color)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(
              children: rows
                  .map((cells) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: cells
                              .map((c) => Expanded(
                                    child: c.label.isEmpty
                                        ? const SizedBox()
                                        : Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(c.label, style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
                                              const SizedBox(height: 3),
                                              Text(c.value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF102A22))),
                                            ],
                                          ),
                                  ))
                              .toList(),
                        ),
                      ))
                  .toList(),
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _RecentMatchesCard extends StatelessWidget {
  final List<MatchPerformance> performances; // newest-first, as loaded
  const _RecentMatchesCard({required this.performances});

  @override
  Widget build(BuildContext context) {
    // Graph reads left-to-right oldest-to-newest, which is the opposite
    // order from the list below it (which reads newest-first, like any
    // activity feed) - each ordering matches how people actually read it.
    final chronological = performances.reversed.toList();

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF00695C).withOpacity(0.08),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                const Icon(Icons.show_chart, size: 18, color: Color(0xFF00695C)),
                const SizedBox(width: 8),
                Text(tr('recent_matches_form'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF00695C))),
              ],
            ),
          ),
          if (chronological.length >= 2)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 14, 16, 4),
              child: FormGraph(performances: chronological),
            ),
          const Divider(height: 20),
          ...performances.map((p) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 42,
                      child: Text(
                        '${p.playedAt.day}/${p.playedAt.month}',
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.opponentTeam != null ? 'vs ${p.opponentTeam}' : 'Match',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (p.dismissal != null && p.dismissal != 'not out')
                            Text(p.dismissal!, style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500)),
                        ],
                      ),
                    ),
                    if (p.balls > 0)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text('${p.runs} (${p.balls})', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF16A34A))),
                      ),
                    if (p.wickets > 0 || p.oversBowled > 0)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text('${p.wickets}/${p.runsConceded}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFFD97706))),
                      ),
                  ],
                ),
              )),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}
