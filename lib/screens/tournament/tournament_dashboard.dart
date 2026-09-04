import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../l10n/app_strings.dart';
import '../../utils/extensions.dart';
import '../../utils/globals.dart';
import '../../services/storage_service.dart';
import '../../services/auth_service.dart';
import '../match/match_detail_screen.dart';
import '../match/match_scorer_screen.dart';
import '../match/start_match_screen.dart';
import 'tournament_stats_screen.dart';

class TournamentDashboard extends StatefulWidget {
  final Tournament tournament;
  const TournamentDashboard({super.key, required this.tournament});

  @override
  State<TournamentDashboard> createState() => _TournamentDashboardState();
}

class _TournamentDashboardState extends State<TournamentDashboard> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  // Persists the whole tournaments list to disk. Called after every mutation
  // so a tournament's schedule/points table/player stats survive an app
  // restart (previously nothing here was ever saved).
  void _persist() {
    StorageService.saveTournaments(globalTournaments);
  }

  static const List<String> _presetStages = ["League", "Quarterfinal", "Semifinal", "Final"];

  // initialTeamA pre-fills Team A (used by "Advance Winner" on a completed
  // match) and initialStage suggests the next stage after the given one.
  void _scheduleMatchDialog({String? initialTeamA, String? initialStage}) {
    String? teamA = initialTeamA;
    String? teamB;
    DateTime selectedDate = DateTime.now();
    TimeOfDay selectedTime = TimeOfDay.now();
    final stageCtrl = TextEditingController(text: initialStage ?? "");

    // Suggestions = the presets plus any custom stage names already used in
    // this tournament, so a person's own labels get remembered too.
    final usedStages = widget.tournament.matches.map((m) => (m.stage == null || m.stage!.isEmpty) ? "League" : m.stage!).toSet();
    final stageSuggestions = {..._presetStages, ...usedStages}.toList();

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, setStateDialog) {
        return AlertDialog(
          title: Text(tr('schedule_match')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(decoration: InputDecoration(labelText: tr('team_a_label')), value: teamA, items: widget.tournament.teams.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(), onChanged: (val) => setStateDialog(() => teamA = val)),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(decoration: InputDecoration(labelText: tr('team_b_label')), value: teamB, items: widget.tournament.teams.where((t) => t != teamA).map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(), onChanged: (val) => setStateDialog(() => teamB = val)),
            const SizedBox(height: 10),
            Autocomplete<String>(
              initialValue: TextEditingValue(text: stageCtrl.text),
              optionsBuilder: (value) => value.text.isEmpty ? stageSuggestions : stageSuggestions.where((s) => s.toLowerCase().contains(value.text.toLowerCase())),
              onSelected: (sel) => stageCtrl.text = sel,
              fieldViewBuilder: (context, fieldController, focusNode, onSubmitted) {
                fieldController.text = stageCtrl.text;
                fieldController.addListener(() => stageCtrl.text = fieldController.text);
                return TextField(controller: fieldController, focusNode: focusNode, decoration: InputDecoration(labelText: tr('round_stage_label'), hintText: tr('round_stage_hint'), prefixIcon: const Icon(Icons.flag_outlined)));
              },
            ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: TextButton.icon(icon: const Icon(Icons.calendar_today), label: Text("${selectedDate.day}/${selectedDate.month}"), onPressed: () async { final picked = await showDatePicker(context: context, initialDate: selectedDate, firstDate: DateTime(2020), lastDate: DateTime(2030)); if (picked != null) setStateDialog(() => selectedDate = picked); })),
              Expanded(child: TextButton.icon(icon: const Icon(Icons.access_time), label: Text(selectedTime.format(context)), onPressed: () async { final picked = await showTimePicker(context: context, initialTime: selectedTime); if (picked != null) setStateDialog(() => selectedTime = picked); })),
            ])
          ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('cancel').toUpperCase())),
            ElevatedButton(
              onPressed: () {
                if (teamA != null && teamB != null) {
                  setState(() {
                    widget.tournament.matches.add(TournamentMatch(id: DateTime.now().millisecondsSinceEpoch.toString(), teamA: teamA!, teamB: teamB!, dateTime: selectedDate, time: selectedTime, stage: stageCtrl.text.trim().isEmpty ? null : stageCtrl.text.trim()));
                  });
                  _persist();
                  Navigator.pop(context);
                }
              },
              child: Text(tr('schedule').toUpperCase()),
            )
          ],
        );
      }),
    );
  }

  // Applies one completed match's contribution to the points table and
  // player stats. Pulled out on its own so both a single freshly-completed
  // match (_onMatchCompleted) and a full rebuild after a delete
  // (_recomputeAllStats) share the exact same math - there's no separate
  // "reverse a match's stats" code path to keep in sync and risk drifting.
  void _applyMatchStatsToTournament(TournamentMatch match, MatchResultData result) {
    widget.tournament.teamStats[match.teamA]?.played++;
    widget.tournament.teamStats[match.teamB]?.played++;

    if (result.winner == "Tie") {
      widget.tournament.teamStats[match.teamA]?.tied++;
      widget.tournament.teamStats[match.teamB]?.tied++;
      widget.tournament.teamStats[match.teamA]?.points++;
      widget.tournament.teamStats[match.teamB]?.points++;
    } else {
      String winnerKey = result.winner;
      String loserKey = (winnerKey == match.teamA) ? match.teamB : match.teamA;
      if (widget.tournament.teamStats.containsKey(winnerKey)) {
        widget.tournament.teamStats[winnerKey]?.won++;
        widget.tournament.teamStats[winnerKey]?.points += 2;
      }
      if (widget.tournament.teamStats.containsKey(loserKey)) {
        widget.tournament.teamStats[loserKey]?.lost++;
      }
    }

    // Player stats are keyed by player ID (not name). Two different teams'
    // default squads both contain "Player 1", "Player 2", etc, so keying
    // by name used to silently merge unrelated players' stats together.
    Map<String, String> idToName = {};
    for (var bat in result.allBatsmen) idToName[bat.id] = bat.name;
    for (var bowl in result.allBowlers) idToName[bowl.id] = bowl.name;

    for (var id in idToName.keys) {
      if (!widget.tournament.playerStats.containsKey(id)) {
        widget.tournament.playerStats[id] = PlayerStat(name: idToName[id]!);
      } else {
        // Keep the display name in sync in case it was edited mid-match.
        widget.tournament.playerStats[id]!.name = idToName[id]!;
      }
      widget.tournament.playerStats[id]!.matches++;
    }

    for (var bat in result.allBatsmen) {
      var stat = widget.tournament.playerStats[bat.id]!;
      if (bat.balls > 0 || bat.dismissal != "not out") stat.innings++;
      if (bat.dismissal == "not out") stat.notOuts++;
      stat.runs += bat.runs;
      stat.balls += bat.balls;
      stat.fours += bat.fours;
      stat.sixes += bat.sixes;
      if (bat.runs >= 100) stat.hundreds++; else if (bat.runs >= 50) stat.fifties++;
      if (bat.runs >= 90 && bat.runs < 100) stat.nineties++;
      if (bat.runs > stat.highestScore) stat.highestScore = bat.runs;
    }

    for (var bowl in result.allBowlers) {
      var stat = widget.tournament.playerStats[bowl.id]!;
      stat.wickets += bowl.wickets;
      stat.runsConceded += bowl.runs;
      double overs = bowl.balls / 6.0;
      stat.oversBowled += overs;
      if (bowl.wickets >= 4) stat.fourWickets++;
      if (stat.bbWickets < bowl.wickets || (stat.bbWickets == bowl.wickets && stat.bbRuns > bowl.runs)) {
        stat.bbWickets = bowl.wickets; stat.bbRuns = bowl.runs;
      }
    }
  }

  void _onMatchCompleted(TournamentMatch match, MatchResultData result) {
    if (match.isCompleted) return;
    setState(() {
      match.status = 'Completed';
      match.resultSummary = result.margin;
      match.matchData = result;
      _applyMatchStatsToTournament(match, result);
    });
    _persist();
    // Tournaments auto-sync to the cloud (see StorageService.saveTournaments
    // above via _persist), so a completed tournament match IS a synced
    // match - this is the equivalent moment to a quick match's "Save to
    // Cloud" for registering its players in the shared global registry.
    // No-ops for guests (registerMatchPlayers checks cloud access itself).
    StorageService.registerMatchPlayers(result, tournamentId: widget.tournament.id);

    final stage = (match.stage == null || match.stage!.trim().isEmpty) ? "League" : match.stage!.trim();
    if (stage == "Final") _promptManOfTheTournament();
  }

  // Asked once the Final is completed - picks from everyone who's played
  // anywhere in the tournament (playerStats already covers that). "SKIP"
  // leaves it unset; can't be re-triggered automatically afterward, but
  // nothing stops setting tournament.manOfTheTournament by re-running this
  // if a Final gets replayed/edited.
  Future<void> _promptManOfTheTournament() async {
    final names = widget.tournament.playerStats.values.map((p) => p.name).toSet().toList();
    if (names.isEmpty || !mounted) return;
    final selected = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(tr('man_of_tournament')),
        content: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(context).size.height * 0.4,
          child: ListView.builder(
            itemCount: names.length,
            itemBuilder: (context, index) => ListTile(
              leading: const Icon(Icons.emoji_events_outlined, color: Colors.amber),
              title: Text(names[index]),
              onTap: () => Navigator.pop(context, names[index]),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, null), child: Text(tr('skip').toUpperCase())),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => widget.tournament.manOfTheTournament = selected);
    _persist();
  }

  // Match was exited early ("Exit Anyway") instead of finished. Keeps the
  // partial scorecard + a resumable draft on the match itself (NOT sent to
  // Match History - this is tournament-owned data) so "Continue Scoring"
  // can pick up exactly where it left off. Deliberately does not touch
  // points/player stats - the match isn't actually over yet.
  void _onMatchIncomplete(TournamentMatch match, MatchResultData result) {
    setState(() {
      match.status = 'Incomplete';
      match.resultSummary = 'Exited early - incomplete';
      match.matchData = result;
    });
    _persist();
  }

  // Fired after every ball while scoring (see MatchScorerScreen.onProgressUpdate)
  // so the match survives the app being killed outright, not just a normal
  // exit. Mutates the match directly without setState - this dashboard isn't
  // the visible screen while scoring is happening, so there's nothing to
  // redraw yet; the existing setState-driven paths (_onMatchCompleted /
  // _onMatchIncomplete / _continueMatch) already refresh the UI whenever the
  // person actually returns here. isOverBoundary is true right as an over
  // completes - a good moment to also push to the cloud (for logged-in
  // users) without doing it on every single ball.
  void _autoSaveProgress(TournamentMatch match, MatchResultData result, bool isOverBoundary) {
    match.status = 'Incomplete';
    match.resultSummary = 'Exited early - incomplete';
    match.matchData = result;
    if (isOverBoundary) {
      _persist();
    } else {
      StorageService.saveTournamentsLocalOnly(globalTournaments);
    }
  }

  // Full rebuild of the points table + player stats from every completed
  // match still in the list. Used after a delete instead of trying to
  // "subtract" one match's contribution back out - recomputing from scratch
  // can't drift out of sync the way incremental reversal math could.
  void _recomputeAllStats() {
    widget.tournament.teamStats = {for (var team in widget.tournament.teams) team: TeamStats(teamName: team)};
    widget.tournament.playerStats = {};
    for (var m in widget.tournament.matches) {
      if (m.isCompleted && m.matchData != null) {
        _applyMatchStatsToTournament(m, m.matchData!);
      }
    }
  }

  void _continueMatch(TournamentMatch match) {
    if (match.matchData?.draft == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MatchScorerScreen(
          draft: match.matchData!.draft,
          onMatchComplete: (result) => result.isComplete ? _onMatchCompleted(match, result) : _onMatchIncomplete(match, result),
          onProgressUpdate: (result, isOverBoundary) => _autoSaveProgress(match, result, isOverBoundary),
          tournamentId: widget.tournament.id,
        ),
      ),
    );
  }

  // Verifies it's really the account owner before a destructive, hard-to-recover
  // action (deleting a scored/in-progress tournament match, which would also
  // wipe its contribution to the points table and every player's stats).
  // Logged-in: re-checks their actual account password via Supabase (doesn't
  // change which account is signed in, just confirms it). Guest: there's no
  // account/password to check, so falls back to a strict type-to-confirm.
  Future<bool> _verifyIdentityForDelete() async {
    if (!AuthService.isLoggedIn) {
      final controller = TextEditingController();
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr('confirm_delete')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('guest_delete_confirm_body')),
              const SizedBox(height: 12),
              TextField(controller: controller, autofocus: true, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(hintText: "DELETE", border: OutlineInputBorder())),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('cancel').toUpperCase())),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim().toUpperCase() == "DELETE"),
              child: Text(tr('delete').toUpperCase(), style: const TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
      return confirmed ?? false;
    }

    final controller = TextEditingController();
    final verified = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(builder: (context, setStateDialog) {
        bool obscure = true;
        bool verifying = false;
        String? error;
        return StatefulBuilder(builder: (context, setLocal) {
          return AlertDialog(
            title: Text(tr('confirm_your_password')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('delete_match_password_body')),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  obscureText: obscure,
                  autofocus: true,
                  enabled: !verifying,
                  decoration: InputDecoration(
                    labelText: tr('password_label'),
                    border: const OutlineInputBorder(),
                    errorText: error,
                    suffixIcon: IconButton(
                      icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setLocal(() => obscure = !obscure),
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: verifying ? null : () => Navigator.pop(context, false), child: Text(tr('cancel').toUpperCase())),
              ElevatedButton(
                onPressed: verifying
                    ? null
                    : () async {
                        if (controller.text.isEmpty) {
                          setLocal(() => error = "Enter your password");
                          return;
                        }
                        setLocal(() { verifying = true; error = null; });
                        final ok = await AuthService.verifyPassword(controller.text);
                        if (!context.mounted) return;
                        if (ok) {
                          Navigator.pop(context, true);
                        } else {
                          setLocal(() { verifying = false; error = "Incorrect password"; });
                        }
                      },
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                child: verifying
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(tr('verify_and_delete').toUpperCase()),
              ),
            ],
          );
        });
      }),
    );
    return verified ?? false;
  }

  Future<void> _deleteMatch(TournamentMatch match) async {
    final verified = await _verifyIdentityForDelete();
    if (!verified) return;
    setState(() {
      widget.tournament.matches.removeWhere((m) => m.id == match.id);
      _recomputeAllStats();
    });
    _persist();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('match_deleted'))));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.tournament.name), backgroundColor: const Color(0xFF00695C), foregroundColor: Colors.white, bottom: TabBar(controller: _tabController, indicatorColor: Colors.white, labelColor: Colors.white, unselectedLabelColor: Colors.white70, tabs: [Tab(text: tr('tab_schedule').toUpperCase()), Tab(text: tr('tab_points').toUpperCase()), Tab(text: tr('tab_stats').toUpperCase())])),
      body: TabBarView(controller: _tabController, children: [_buildScheduleTab(), _buildPointsTable(), TournamentStatsScreen(tournament: widget.tournament)]),
      floatingActionButton: FloatingActionButton(onPressed: _scheduleMatchDialog, backgroundColor: const Color(0xFF00695C), foregroundColor: Colors.white, child: const Icon(Icons.add)),
    );
  }

  IconData _stageIcon(String stage) {
    switch (stage) {
      case "Final": return Icons.emoji_events;
      case "Semifinal": return Icons.military_tech;
      case "Quarterfinal": return Icons.flag;
      case "League": return Icons.view_list;
      default: return Icons.label_outline;
    }
  }

  // Best-guess next stage after the given one, using the preset knockout
  // progression - just a convenience default the person can still overwrite
  // in the dialog, not a rule the app enforces.
  String? _suggestedNextStage(String? currentStage) {
    final normalized = (currentStage == null || currentStage.trim().isEmpty) ? "League" : currentStage.trim();
    final idx = _presetStages.indexOf(normalized);
    if (idx == -1 || idx == _presetStages.length - 1) return null;
    return _presetStages[idx + 1];
  }

  // Pre-fills a new match's Team A with this match's winner (and suggests
  // the next stage) so advancing a winner into the next round doesn't mean
  // retyping their name - the actual match is still created manually,
  // nothing here is auto-generated or auto-advanced on its own.
  void _advanceWinner(TournamentMatch match) {
    final winner = match.matchData?.winner;
    if (winner == null || winner.isEmpty || winner == "Tie") return;
    _scheduleMatchDialog(initialTeamA: winner, initialStage: _suggestedNextStage(match.stage));
  }

  Widget _buildScheduleTab() {
    if (widget.tournament.matches.isEmpty) return Center(child: Text(tr('no_matches_scheduled'), style: const TextStyle(color: Colors.grey)));

    // Group by stage ("League" for blank/unset), ordered League -> the
    // preset knockout stages -> any custom stage names in the order they
    // first appeared - so it's always clear which match belongs to which
    // round instead of one flat list.
    final Map<String, List<TournamentMatch>> grouped = {};
    for (var m in widget.tournament.matches) {
      final key = (m.stage == null || m.stage!.trim().isEmpty) ? "League" : m.stage!.trim();
      grouped.putIfAbsent(key, () => []).add(m);
    }
    final stageKeys = grouped.keys.toList()
      ..sort((a, b) {
        final ai = _presetStages.indexOf(a);
        final bi = _presetStages.indexOf(b);
        if (ai != -1 && bi != -1) return ai.compareTo(bi);
        if (ai != -1) return -1;
        if (bi != -1) return 1;
        return 0;
      });

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (widget.tournament.manOfTheTournament != null && widget.tournament.manOfTheTournament!.isNotEmpty)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [Colors.amber.shade100, Colors.amber.shade50]),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.amber.shade300),
            ),
            child: Row(
              children: [
                Icon(Icons.emoji_events, color: Colors.amber.shade800, size: 26),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr('man_of_tournament'), style: TextStyle(fontSize: 11, color: Colors.amber.shade900, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
                      Text(widget.tournament.manOfTheTournament!, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.amber.shade900)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        for (final stage in stageKeys) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 10, 6, 8),
            child: Row(children: [
              Icon(_stageIcon(stage), size: 16, color: const Color(0xFF00695C)),
              const SizedBox(width: 6),
              Text(stage.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF00695C), letterSpacing: 0.5)),
            ]),
          ),
          ...grouped[stage]!.map((match) => _matchCard(match)),
        ],
      ],
    );
  }

  Widget _matchCard(TournamentMatch match) {
    return InkWell(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => MatchDetailScreen(match: match))),
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        color: match.isCompleted ? Colors.grey.shade100 : (match.isIncomplete ? Colors.orange.shade50 : Colors.white),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text("${match.dateTime.day}/${match.dateTime.month} • ${match.time.format(context)}", style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ),
                  InkWell(
                    onTap: () => _deleteMatch(match),
                    child: const Padding(
                      padding: EdgeInsets.all(4.0),
                      child: Icon(Icons.delete_outline, size: 18, color: Colors.grey),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Expanded(child: Text(match.teamA, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
                Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: Colors.teal.withOpacity(0.1), borderRadius: BorderRadius.circular(4)), child: Text(tr('vs_label'), style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.teal.shade800))),
                Expanded(child: Text(match.teamB, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
              ]),
              if (match.isCompleted) Padding(padding: const EdgeInsets.only(top: 8.0), child: Text(match.resultSummary, style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold))),
              if (match.isCompleted && match.matchData?.manOfTheMatch != null && match.matchData!.manOfTheMatch!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.star, size: 14, color: Colors.amber.shade700),
                      const SizedBox(width: 4),
                      Text(tr('motm_label').replaceFirst('%s', '${match.matchData!.manOfTheMatch}'), style: TextStyle(fontSize: 12, color: Colors.amber.shade900, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              if (match.isCompleted && match.matchData?.winner != null && match.matchData!.winner.isNotEmpty && match.matchData!.winner != "Tie") ...[
                const Divider(),
                TextButton.icon(
                  onPressed: () => _advanceWinner(match),
                  icon: const Icon(Icons.arrow_forward, size: 18),
                  label: Text(tr('advance_to_next_round').replaceFirst('%s', '${match.matchData!.winner}')),
                ),
              ],
              if (match.isIncomplete) ...[
                Padding(padding: const EdgeInsets.only(top: 8.0), child: Text(tr('incomplete_exited_early'), style: TextStyle(color: Colors.orange.shade800, fontWeight: FontWeight.bold))),
                const Divider(),
                ElevatedButton.icon(
                  onPressed: () => _continueMatch(match),
                  icon: const Icon(Icons.play_arrow),
                  label: Text(tr('continue_scoring').toUpperCase()),
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00695C), foregroundColor: Colors.white),
                ),
              ],
              if (!match.isCompleted && !match.isIncomplete) ...[
                const Divider(),
                TextButton(
                  onPressed: () {
                    Navigator.push(context, MaterialPageRoute(builder: (context) => StartMatchScreen(
                      initialTeamA: match.teamA, initialTeamB: match.teamB,
                      onMatchComplete: (result) => result.isComplete ? _onMatchCompleted(match, result) : _onMatchIncomplete(match, result),
                      onProgressUpdate: (result, isOverBoundary) => _autoSaveProgress(match, result, isOverBoundary),
                      tournamentId: widget.tournament.id,
                    )));
                  },
                  child: Text(tr('start_scoring').toUpperCase()),
                )
              ]
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPointsTable() {
    var statsList = widget.tournament.teamStats.values.toList();
    statsList.sort((a, b) => b.points.compareTo(a.points));
    return SingleChildScrollView(
      child: DataTable(
        columnSpacing: 20,
        columns: [DataColumn(label: Text(tr('col_team'))), DataColumn(label: Text(tr('col_p'))), DataColumn(label: Text(tr('col_w'))), DataColumn(label: Text(tr('col_l'))), DataColumn(label: Text(tr('col_pts')))],
        rows: statsList.map((stat) => DataRow(cells: [
          DataCell(Text(stat.teamName, style: const TextStyle(fontWeight: FontWeight.bold))),
          DataCell(Text("${stat.played}")),
          DataCell(Text("${stat.won}")),
          DataCell(Text("${stat.lost}")),
          DataCell(Text("${stat.points}", style: const TextStyle(fontWeight: FontWeight.bold))),
        ])).toList(),
      ),
    );
  }
}
