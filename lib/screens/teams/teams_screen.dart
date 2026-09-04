import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../utils/extensions.dart';
import '../../utils/globals.dart';
import '../../services/storage_service.dart';
import '../../widgets/skeleton_loader.dart';
import '../../l10n/app_strings.dart';
import '../match/match_result_screen.dart';

class TeamsScreen extends StatefulWidget {
  const TeamsScreen({super.key});

  @override
  State<TeamsScreen> createState() => _TeamsScreenState();
}

class _TeamsScreenState extends State<TeamsScreen> {
  List<String> _teams = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final teams = await StorageService.loadTeams();
    teams.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (!mounted) return;
    setState(() {
      _teams = teams;
      _loading = false;
    });
  }

  Future<void> _addTeam() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('add_team')),
        content: TextField(controller: controller, autofocus: true, decoration: InputDecoration(labelText: tr('team_name_label'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('cancel').toUpperCase())),
          ElevatedButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: Text(tr('add').toUpperCase())),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await StorageService.addTeamIfNew(name);
    _load();
  }

  Future<void> _deleteTeam(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('remove_team_title')),
        content: Text(tr('remove_team_body').replaceFirst('%s', name)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('cancel').toUpperCase())),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('remove').toUpperCase(), style: const TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed != true) return;
    await StorageService.deleteTeam(name);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('teams_title')), backgroundColor: const Color(0xFF00695C), foregroundColor: Colors.white),
      body: _loading
          ? const MatchListSkeleton()
          : _teams.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(tr('no_saved_teams'), style: TextStyle(color: Colors.grey[600])),
                        const SizedBox(height: 4),
                        Text(tr('no_saved_teams_hint'), style: TextStyle(color: Colors.grey[400], fontSize: 12), textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _teams.length,
                  itemBuilder: (context, index) {
                    final name = _teams[index];
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        leading: const CircleAvatar(backgroundColor: Color(0xFFE0F2F1), child: Icon(Icons.shield, color: Color(0xFF00695C))),
                        title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                        trailing: IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red), onPressed: () => _deleteTeam(name)),
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => TeamDetailScreen(teamName: name))),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(onPressed: _addTeam, backgroundColor: const Color(0xFF00695C), foregroundColor: Colors.white, child: const Icon(Icons.add)),
    );
  }
}

class _HeadToHead {
  final String opponent;
  int played = 0;
  int won = 0;
  int lost = 0;
  int tied = 0;
  // Individual matches against this opponent, newest first (see
  // _computeHeadToHead's sort) - lets the detail screen list them and open
  // any one of them in MatchResultScreen, not just show the W/L/T totals.
  final List<MatchResultData> matches = [];
  _HeadToHead(this.opponent);
}

class TeamDetailScreen extends StatefulWidget {
  final String teamName;
  const TeamDetailScreen({super.key, required this.teamName});

  @override
  State<TeamDetailScreen> createState() => _TeamDetailScreenState();
}

class _TeamDetailScreenState extends State<TeamDetailScreen> {
  List<_HeadToHead> _records = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _computeHeadToHead();
  }

  Future<void> _computeHeadToHead() async {
    final Map<String, _HeadToHead> tally = {};

    void tallyResult(String teamA, String teamB, bool isComplete, String? winner, MatchResultData match) {
      if (!isComplete) return;
      String? opponent;
      if (teamA == widget.teamName) opponent = teamB;
      if (teamB == widget.teamName) opponent = teamA;
      if (opponent == null || opponent == widget.teamName) return;

      final record = tally.putIfAbsent(opponent, () => _HeadToHead(opponent!));
      record.played++;
      record.matches.add(match);
      if (winner == null || winner.isEmpty) return;
      if (winner == "Tie") {
        record.tied++;
      } else if (winner == widget.teamName) {
        record.won++;
      } else if (winner == opponent) {
        record.lost++;
      }
    }

    // Quick Match history.
    final quickMatches = await StorageService.loadQuickMatchHistory();
    for (var m in quickMatches) {
      tallyResult(m.teamName1, m.teamName2, m.isComplete, m.winner, m);
    }

    // Tournament matches - loaded on demand, same lazy pattern as the
    // Tournament tab, so head-to-head is correct even if this page is
    // opened before ever visiting Tournament Mode this session.
    if (!globalTournamentsLoaded) {
      globalTournaments = await StorageService.loadTournaments();
      globalTournamentsLoaded = true;
    }
    for (var t in globalTournaments) {
      for (var m in t.matches) {
        if (m.isCompleted && m.matchData != null) {
          tallyResult(m.teamA, m.teamB, true, m.matchData!.winner, m.matchData!);
        }
      }
    }

    // Most recent match first within each opponent's list.
    for (final record in tally.values) {
      record.matches.sort((a, b) => (b.playedAt ?? DateTime(0)).compareTo(a.playedAt ?? DateTime(0)));
    }

    final list = tally.values.toList()..sort((a, b) => b.played.compareTo(a.played));
    if (!mounted) return;
    setState(() {
      _records = list;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.teamName), backgroundColor: const Color(0xFF00695C), foregroundColor: Colors.white),
      body: _loading
          ? const MatchListSkeleton()
          : _records.isEmpty
              ? Center(child: Text(tr('no_recorded_matches_for').replaceFirst('%s', widget.teamName), style: TextStyle(color: Colors.grey[600])))
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _records.length,
                  itemBuilder: (context, index) {
                    final r = _records[index];
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        title: Text("vs ${r.opponent}", style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text(tr('matches_played_count').replaceFirst('%s', '${r.played}')),
                        trailing: Text(
                          "${r.won}W - ${r.lost}L${r.tied > 0 ? ' - ${r.tied}T' : ''}",
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF00695C)),
                        ),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => _HeadToHeadMatchesScreen(teamName: widget.teamName, opponent: r.opponent, matches: r.matches),
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

/// Individual matches between [teamName] and [opponent] (newest first) -
/// opened by tapping a "vs X" row on TeamDetailScreen. Tapping a match
/// here opens the existing MatchResultScreen, same scorecard view used
/// from Match History - no new detail UI, just routing to it from here too.
class _HeadToHeadMatchesScreen extends StatelessWidget {
  final String teamName;
  final String opponent;
  final List<MatchResultData> matches;

  const _HeadToHeadMatchesScreen({required this.teamName, required this.opponent, required this.matches});

  String _resultLabel(MatchResultData m) {
    if (m.winner.isEmpty) return tr('no_result');
    if (m.winner == "Tie") return tr('tie');
    return m.winner == teamName ? tr('won') : tr('lost');
  }

  Color _resultColor(MatchResultData m) {
    if (m.winner.isEmpty) return Colors.grey;
    if (m.winner == "Tie") return Colors.orange[700]!;
    return m.winner == teamName ? Colors.green[700]! : Colors.red[700]!;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("$teamName vs $opponent"), backgroundColor: const Color(0xFF00695C), foregroundColor: Colors.white),
      body: matches.isEmpty
          ? Center(child: Text(tr('no_recorded_matches'), style: TextStyle(color: Colors.grey[600])))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: matches.length,
              itemBuilder: (context, index) {
                final m = matches[index];
                final dateStr = m.playedAt != null ? "${m.playedAt!.day}/${m.playedAt!.month}/${m.playedAt!.year}" : null;
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    title: Text("${m.teamName1} vs ${m.teamName2}", style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text([
                      if (m.innings1Score.isNotEmpty || m.innings2Score.isNotEmpty) "${m.innings1Score}  -  ${m.innings2Score}",
                      if (dateStr != null) dateStr,
                    ].join("\n")),
                    isThreeLine: dateStr != null,
                    trailing: Text(_resultLabel(m), style: TextStyle(fontWeight: FontWeight.bold, color: _resultColor(m))),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => MatchResultScreen(data: m))),
                  ),
                );
              },
            ),
    );
  }
}