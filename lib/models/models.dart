import 'package:flutter/material.dart';

// Playing XI role tags shown under each player's name on the broadcast
// card (see live_viewer_screen.dart's _PlayingXIPlayerTile) - purely
// descriptive metadata the scorer sets once per squad player, has no
// effect on scoring logic. Kept as short display labels (not a Dart enum)
// so they serialize directly as-is and stay easy to extend later (e.g.
// splitting "Bowler" into pace/spin) without a migration.
const List<String> kPlayerRoles = ["Batsman", "Bowler", "All-rounder", "Keeper"];

class Player {
  String name;
  String id;
  // Null/empty means "not set" - older saved squads/rosters (saved before
  // this field existed) simply show no role tag, same as a player the
  // scorer hasn't gotten around to tagging yet. See kPlayerRoles for the
  // allowed values; nothing enforces the value stays one of them, so a
  // squad synced from a future app version with a new role string still
  // round-trips fine, it just won't match a dropdown option here.
  String? role;
  Player({required this.name, required this.id, this.role});
  @override
  bool operator ==(Object other) => identical(this, other) || other is Player && runtimeType == other.runtimeType && id == other.id;
  @override
  int get hashCode => id.hashCode;

  Map<String, dynamic> toJson() => {'name': name, 'id': id, if (role != null && role!.isNotEmpty) 'role': role};
  factory Player.fromJson(Map<String, dynamic> j) => Player(name: j['name'], id: j['id'], role: j['role'] as String?);
}

class Batsman {
  String name;
  String id;
  int runs;
  int balls;
  int fours;
  int sixes;
  String dismissal;

  Batsman({required this.name, required this.id, this.runs = 0, this.balls = 0, this.fours = 0, this.sixes = 0, this.dismissal = "not out"});

  Map<String, dynamic> toJson() => {
        'name': name, 'id': id, 'runs': runs, 'balls': balls, 'fours': fours, 'sixes': sixes, 'dismissal': dismissal,
      };
  factory Batsman.fromJson(Map<String, dynamic> j) => Batsman(
        name: j['name'], id: j['id'], runs: j['runs'], balls: j['balls'], fours: j['fours'], sixes: j['sixes'], dismissal: j['dismissal'],
      );
}

class Bowler {
  String name;
  String id;
  int runs;
  int wickets;
  int balls;
  int maidens;

  Bowler({required this.name, required this.id, this.runs = 0, this.wickets = 0, this.balls = 0, this.maidens = 0});

  Map<String, dynamic> toJson() => {
        'name': name, 'id': id, 'runs': runs, 'wickets': wickets, 'balls': balls, 'maidens': maidens,
      };
  factory Bowler.fromJson(Map<String, dynamic> j) => Bowler(
        name: j['name'], id: j['id'], runs: j['runs'], wickets: j['wickets'], balls: j['balls'], maidens: j['maidens'] ?? 0,
      );
}

class PlayerStat {
  String name;
  int matches = 0;
  int innings = 0;
  int notOuts = 0;
  int runs = 0;
  int balls = 0;
  int fours = 0;
  int sixes = 0;
  int hundreds = 0;
  int fifties = 0;
  int nineties = 0;
  int highestScore = 0;

  int wickets = 0;
  int runsConceded = 0;
  double oversBowled = 0.0;
  int fourWickets = 0;

  int bbWickets = 0;
  int bbRuns = 0;

  PlayerStat({required this.name});

  Map<String, dynamic> toJson() => {
        'name': name, 'matches': matches, 'innings': innings, 'notOuts': notOuts, 'runs': runs, 'balls': balls,
        'fours': fours, 'sixes': sixes, 'hundreds': hundreds, 'fifties': fifties, 'nineties': nineties,
        'highestScore': highestScore, 'wickets': wickets, 'runsConceded': runsConceded, 'oversBowled': oversBowled,
        'fourWickets': fourWickets, 'bbWickets': bbWickets, 'bbRuns': bbRuns,
      };

  factory PlayerStat.fromJson(Map<String, dynamic> j) {
    final p = PlayerStat(name: j['name']);
    p.matches = j['matches'] ?? 0;
    p.innings = j['innings'] ?? 0;
    p.notOuts = j['notOuts'] ?? 0;
    p.runs = j['runs'] ?? 0;
    p.balls = j['balls'] ?? 0;
    p.fours = j['fours'] ?? 0;
    p.sixes = j['sixes'] ?? 0;
    p.hundreds = j['hundreds'] ?? 0;
    p.fifties = j['fifties'] ?? 0;
    p.nineties = j['nineties'] ?? 0;
    p.highestScore = j['highestScore'] ?? 0;
    p.wickets = j['wickets'] ?? 0;
    p.runsConceded = j['runsConceded'] ?? 0;
    p.oversBowled = (j['oversBowled'] ?? 0.0).toDouble();
    p.fourWickets = j['fourWickets'] ?? 0;
    p.bbWickets = j['bbWickets'] ?? 0;
    p.bbRuns = j['bbRuns'] ?? 0;
    return p;
  }
}

class Tournament {
  String name;
  List<String> teams;
  List<TournamentMatch> matches;
  Map<String, TeamStats> teamStats;
  // Keyed by player ID (not name) so same-named players across teams never collide.
  Map<String, PlayerStat> playerStats;
  // Stable identifier - maps this tournament to a single Supabase row so
  // repeated saves UPDATE the same row instead of creating duplicates.
  String id;
  // Set once, typically right after the Final is completed.
  String? manOfTheTournament;

  Tournament({String? id, required this.name, required this.teams, required this.matches, this.manOfTheTournament})
      : id = id ?? '${DateTime.now().microsecondsSinceEpoch}_${teams.hashCode}',
        teamStats = {for (var team in teams) team: TeamStats(teamName: team)},
        playerStats = {};

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'teams': teams,
        'matches': matches.map((m) => m.toJson()).toList(),
        'teamStats': teamStats.map((k, v) => MapEntry(k, v.toJson())),
        'playerStats': playerStats.map((k, v) => MapEntry(k, v.toJson())),
        'manOfTheTournament': manOfTheTournament,
      };

  factory Tournament.fromJson(Map<String, dynamic> j) {
    final t = Tournament(
      id: j['id'],
      name: j['name'],
      teams: List<String>.from(j['teams']),
      matches: (j['matches'] as List).map((m) => TournamentMatch.fromJson(m)).toList(),
      manOfTheTournament: j['manOfTheTournament'],
    );
    t.teamStats = (j['teamStats'] as Map).map((k, v) => MapEntry(k as String, TeamStats.fromJson(v)));
    t.playerStats = (j['playerStats'] as Map? ?? {}).map((k, v) => MapEntry(k as String, PlayerStat.fromJson(v)));
    return t;
  }
}

class TeamStats {
  String teamName;
  int played = 0;
  int won = 0;
  int lost = 0;
  int tied = 0;
  int points = 0;

  TeamStats({required this.teamName});

  Map<String, dynamic> toJson() => {
        'teamName': teamName, 'played': played, 'won': won, 'lost': lost, 'tied': tied, 'points': points,
      };

  factory TeamStats.fromJson(Map<String, dynamic> j) {
    final t = TeamStats(teamName: j['teamName']);
    t.played = j['played'] ?? 0;
    t.won = j['won'] ?? 0;
    t.lost = j['lost'] ?? 0;
    t.tied = j['tied'] ?? 0;
    t.points = j['points'] ?? 0;
    return t;
  }
}

class TournamentMatch {
  String id;
  String teamA;
  String teamB;
  DateTime dateTime;
  TimeOfDay time;
  String status;
  String resultSummary;
  MatchResultData? matchData;
  // Which round/stage this match belongs to (e.g. "League", "Quarterfinal",
  // "Semifinal", "Final", or any custom label) - lets Schedule group matches
  // so it's clear which match is which round. Null/blank is treated as
  // "League" everywhere it's displayed.
  String? stage;

  TournamentMatch({
    required this.id,
    required this.teamA,
    required this.teamB,
    required this.dateTime,
    required this.time,
    this.status = 'Scheduled',
    this.resultSummary = '',
    this.matchData,
    this.stage,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'teamA': teamA,
        'teamB': teamB,
        'dateTime': dateTime.toIso8601String(),
        'timeHour': time.hour,
        'timeMinute': time.minute,
        'status': status,
        'resultSummary': resultSummary,
        'matchData': matchData?.toJson(),
        'stage': stage,
      };

  factory TournamentMatch.fromJson(Map<String, dynamic> j) => TournamentMatch(
        id: j['id'],
        teamA: j['teamA'],
        teamB: j['teamB'],
        dateTime: DateTime.parse(j['dateTime']),
        time: TimeOfDay(hour: j['timeHour'], minute: j['timeMinute']),
        status: j['status'] ?? 'Scheduled',
        resultSummary: j['resultSummary'] ?? '',
        stage: j['stage'],
        matchData: j['matchData'] != null ? MatchResultData.fromJson(j['matchData']) : null,
      );
}

/// One ball's worth of batter-vs-bowler data, captured live in
/// match_scorer_screen's _processDelivery - the single choke point every
/// delivery already passes through. Powers the head-to-head "Player
/// Battle" matchup (runs/balls/dismissals of one specific batter against
/// one specific bowler), which the match-level/innings-level totals alone
/// can't answer.
/// Mutable accumulator for one (batsman, bowler) pair while summing up a
/// match's Delivery log - see MatchResultMatchups.computeMatchupDeltas in
/// extensions.dart. Records are immutable so a plain class is used here
/// instead, purely as scratch space during that summation.
class MatchupDelta {
  int runs = 0;
  int balls = 0;
  int dismissals = 0;
}

class Delivery {
  final String batsmanId;
  final String batsmanName;
  final String bowlerId;
  final String bowlerName;
  final int runsOffBat;
  // Matches the same convention already used for Batsman.balls elsewhere
  // in this file: every delivery except a wide counts as a ball faced
  // (no-balls DO count, per the existing ESPNcricinfo-style convention).
  final bool countsAsBallFaced;
  final bool isWicket;
  // Who actually got out - usually the batsman who faced the ball, but on
  // a run-out this can be the non-striker instead, which is why this is
  // tracked separately from batsmanId rather than assumed to match it.
  final String? dismissedPlayerId;
  // Only true for dismissal types where cricket convention actually
  // credits the bowler (bowled/caught/lbw/stumped/hit wicket) - a run-out
  // is never "bowler A dismissed batsman B" for matchup purposes.
  final bool bowlerCreditedWicket;

  Delivery({
    required this.batsmanId,
    required this.batsmanName,
    required this.bowlerId,
    required this.bowlerName,
    required this.runsOffBat,
    required this.countsAsBallFaced,
    this.isWicket = false,
    this.dismissedPlayerId,
    this.bowlerCreditedWicket = false,
  });

  Map<String, dynamic> toJson() => {
        'batsmanId': batsmanId,
        'batsmanName': batsmanName,
        'bowlerId': bowlerId,
        'bowlerName': bowlerName,
        'runsOffBat': runsOffBat,
        'countsAsBallFaced': countsAsBallFaced,
        'isWicket': isWicket,
        'dismissedPlayerId': dismissedPlayerId,
        'bowlerCreditedWicket': bowlerCreditedWicket,
      };

  factory Delivery.fromJson(Map<String, dynamic> j) => Delivery(
        batsmanId: j['batsmanId'],
        batsmanName: j['batsmanName'],
        bowlerId: j['bowlerId'],
        bowlerName: j['bowlerName'],
        runsOffBat: j['runsOffBat'],
        countsAsBallFaced: j['countsAsBallFaced'],
        isWicket: j['isWicket'] ?? false,
        dismissedPlayerId: j['dismissedPlayerId'],
        bowlerCreditedWicket: j['bowlerCreditedWicket'] ?? false,
      );
}

class MatchResultData {
  final String id;
  final String winner;
  final String margin;
  final List<Batsman> allBatsmen;
  final List<Bowler> allBowlers;
  final List<Player> fullSquad;
  final InningsHistory? innings1;
  final InningsHistory? innings2;
  final String teamName1;
  final String teamName2;
  final String innings1Score;
  final String innings2Score;
  // When this quick-match result is saved to local history, this is set.
  final DateTime? playedAt;
  // False when the match was exited early (e.g. "Exit Anyway" mid-scoring)
  // instead of being finished normally via "End & Save Match". Lets History
  // flag it as incomplete instead of silently pretending it was a full result.
  final bool isComplete;
  // Only set when isComplete is false - the full resumable state, so History
  // can offer "Continue" on an incomplete match instead of just showing its
  // partial scorecard read-only.
  final MatchDraft? draft;
  // Player name chosen as Man of the Match when the match was finished
  // (skipped for incomplete/exited-early results). Null if not set.
  final String? manOfTheMatch;
  // Ball-by-ball log across both innings - see the Delivery class doc for
  // why this exists. Empty for matches saved before this field existed
  // (old local drafts/history), which is fine: matchup computation on an
  // empty list just yields no matchup data for that match, same as if it
  // had never been played.
  final List<Delivery> deliveries;

  MatchResultData({
    String? id,
    required this.winner,
    required this.margin,
    required this.allBatsmen,
    required this.allBowlers,
    required this.fullSquad,
    this.innings1,
    this.innings2,
    required this.teamName1,
    required this.teamName2,
    required this.innings1Score,
    required this.innings2Score,
    this.playedAt,
    this.isComplete = true,
    this.draft,
    this.manOfTheMatch,
    this.deliveries = const [],
  }) : id = id ?? '${DateTime.now().microsecondsSinceEpoch}';

  Map<String, dynamic> toJson() => {
        'id': id,
        'winner': winner,
        'margin': margin,
        'allBatsmen': allBatsmen.map((b) => b.toJson()).toList(),
        'allBowlers': allBowlers.map((b) => b.toJson()).toList(),
        'fullSquad': fullSquad.map((p) => p.toJson()).toList(),
        'innings1': innings1?.toJson(),
        'innings2': innings2?.toJson(),
        'teamName1': teamName1,
        'teamName2': teamName2,
        'innings1Score': innings1Score,
        'innings2Score': innings2Score,
        'playedAt': playedAt?.toIso8601String(),
        'isComplete': isComplete,
        'draft': draft?.toJson(),
        'manOfTheMatch': manOfTheMatch,
        'deliveries': deliveries.map((d) => d.toJson()).toList(),
      };

  factory MatchResultData.fromJson(Map<String, dynamic> j) => MatchResultData(
        id: j['id'],
        winner: j['winner'],
        margin: j['margin'],
        allBatsmen: (j['allBatsmen'] as List).map((b) => Batsman.fromJson(b)).toList(),
        allBowlers: (j['allBowlers'] as List).map((b) => Bowler.fromJson(b)).toList(),
        fullSquad: (j['fullSquad'] as List? ?? []).map((p) => Player.fromJson(p)).toList(),
        innings1: j['innings1'] != null ? InningsHistory.fromJson(j['innings1']) : null,
        innings2: j['innings2'] != null ? InningsHistory.fromJson(j['innings2']) : null,
        teamName1: j['teamName1'],
        teamName2: j['teamName2'],
        innings1Score: j['innings1Score'],
        innings2Score: j['innings2Score'],
        playedAt: j['playedAt'] != null ? DateTime.parse(j['playedAt']) : null,
        isComplete: j['isComplete'] ?? true,
        draft: j['draft'] != null ? MatchDraft.fromJson(j['draft']) : null,
        manOfTheMatch: j['manOfTheMatch'],
        deliveries: (j['deliveries'] as List? ?? []).map((d) => Delivery.fromJson(d)).toList(),
      );
}

class InningsHistory {
  final String teamName;
  final int totalRuns;
  final int totalWickets;
  final String overs;
  final List<Batsman> batsmen;
  final List<Bowler> bowlers;
  final List<Player> squad;
  final int extras;
  // Ball-by-ball commentary lines for this innings (newest first, same
  // format shown live in the Commentary tab) - persisted so History keeps
  // the full ball-by-ball record instead of losing it once the innings ends.
  final List<String> commentary;
  // Runs scored in each completed over of this innings (index 0 = over 1) -
  // powers the Scoring Comparison (worm) chart. Empty for innings saved
  // before this field existed.
  final List<int> overRuns;
  // Cumulative team total after EVERY delivery of this innings (index 0 =
  // total after ball 1, etc, including extras) - powers the ball-by-ball
  // Scoring Comparison worm chart, same granularity a TV broadcast's worm
  // graph moves at rather than jumping only at over boundaries. Empty for
  // innings saved before this field existed (falls back to the coarser
  // overRuns above).
  final List<int> ballRuns;

  InningsHistory({
    required this.teamName,
    required this.totalRuns,
    required this.totalWickets,
    required this.overs,
    required this.batsmen,
    required this.bowlers,
    required this.squad,
    required this.extras,
    this.commentary = const [],
    this.overRuns = const [],
    this.ballRuns = const [],
  });

  Map<String, dynamic> toJson() => {
        'teamName': teamName,
        'totalRuns': totalRuns,
        'totalWickets': totalWickets,
        'overs': overs,
        'batsmen': batsmen.map((b) => b.toJson()).toList(),
        'bowlers': bowlers.map((b) => b.toJson()).toList(),
        'squad': squad.map((p) => p.toJson()).toList(),
        'extras': extras,
        'commentary': commentary,
        'overRuns': overRuns,
        'ballRuns': ballRuns,
      };

  factory InningsHistory.fromJson(Map<String, dynamic> j) => InningsHistory(
        teamName: j['teamName'],
        totalRuns: j['totalRuns'],
        totalWickets: j['totalWickets'],
        overs: j['overs'],
        batsmen: (j['batsmen'] as List).map((b) => Batsman.fromJson(b)).toList(),
        bowlers: (j['bowlers'] as List).map((b) => Bowler.fromJson(b)).toList(),
        squad: (j['squad'] as List? ?? []).map((p) => Player.fromJson(p)).toList(),
        extras: j['extras'],
        commentary: (j['commentary'] as List? ?? []).map((e) => e.toString()).toList(),
        overRuns: (j['overRuns'] as List? ?? []).map((e) => e as int).toList(),
        ballRuns: (j['ballRuns'] as List? ?? []).map((e) => e as int).toList(),
      );
}

/// A snapshot of an in-progress Quick Match, written to disk after every
/// ball so scoring survives the app being force-closed/swiped away from
/// recent apps - not just a normal back-button exit (which is handled
/// separately by saving straight into Match History). On next launch, Home
/// checks for one of these and offers to resume straight back into the
/// scorer with everything restored.
class MatchDraft {
  final int maxOvers;
  final int totalPlayers;
  final String currentBattingTeam;
  final String currentBowlingTeam;
  final int totalRuns;
  final int totalWickets;
  final int matchBalls;
  final int extras;
  final int currentOverRuns;
  // Runs scored in each COMPLETED over of the current innings (index 0 =
  // over 1), for the live Graph tab's bar chart. currentOverRuns above
  // covers the in-progress over on top of this.
  final List<int> overRunsHistory;
  // Same idea as currentOverRuns/overRunsHistory above, but counting
  // wickets instead of runs - powers the wicket-dot markers on the
  // Runs/Over chart (both the scorer's local Graph tab and the broadcast
  // view viewers see). Index-aligned with overRunsHistory.
  final int currentOverWickets;
  final List<int> overWicketsHistory;
  // Same idea as overRunsHistory, but one entry per delivery (cumulative
  // team total, not runs-in-that-ball) rather than one per completed over -
  // feeds the ball-by-ball Scoring Comparison worm chart.
  final List<int> ballCumulativeRuns;
  final bool isSecondInnings;
  final int targetScore;
  final InningsHistory? firstInningsData;
  final List<String> ballHistoryDisplay;
  final List<Player> squadBatting;
  final List<Player> squadBowling;
  final List<Batsman> activeBatsmenList;
  final List<Bowler> activeBowlersList;
  final Batsman striker;
  final Batsman nonStriker;
  final Bowler currentBowler;
  final String? lastBowlerId;
  final bool isMatchOver;
  final bool isInningsBreak;
  final String matchStatus;
  final String? winnerTeamName;
  final DateTime savedAt;
  // If this draft was created from an "Incomplete" match already saved to
  // History (see MatchResultData.draft), this is that entry's id - so
  // finishing (or re-exiting incomplete) this match updates that same
  // History row instead of creating a duplicate one. Null for the plain
  // crash-recovery auto-save draft, which isn't in History yet.
  final String? resultId;
  // These four were added after MatchDraft already existed, for features
  // that came later (Free Hit banner, ball-by-ball Player Battle matchups,
  // tournament-wide boundary counter) - without persisting them here too,
  // exiting an in-progress match and resuming it via Continue silently
  // reset all four back to their defaults, which is exactly what caused
  // the boundary count to restart mid-tournament instead of picking up
  // where the match left off.
  final bool isFreeHit;
  final int matchFours;
  final int matchSixes;
  final List<Delivery> deliveryLog;

  MatchDraft({
    required this.maxOvers,
    required this.totalPlayers,
    required this.currentBattingTeam,
    required this.currentBowlingTeam,
    required this.totalRuns,
    required this.totalWickets,
    required this.matchBalls,
    required this.extras,
    required this.currentOverRuns,
    this.overRunsHistory = const [],
    this.currentOverWickets = 0,
    this.overWicketsHistory = const [],
    this.ballCumulativeRuns = const [],
    required this.isSecondInnings,
    required this.targetScore,
    this.firstInningsData,
    required this.ballHistoryDisplay,
    required this.squadBatting,
    required this.squadBowling,
    required this.activeBatsmenList,
    required this.activeBowlersList,
    required this.striker,
    required this.nonStriker,
    required this.currentBowler,
    this.lastBowlerId,
    required this.isMatchOver,
    required this.isInningsBreak,
    required this.matchStatus,
    this.winnerTeamName,
    required this.savedAt,
    this.resultId,
    this.isFreeHit = false,
    this.matchFours = 0,
    this.matchSixes = 0,
    this.deliveryLog = const [],
  });

  Map<String, dynamic> toJson() => {
        'maxOvers': maxOvers,
        'totalPlayers': totalPlayers,
        'currentBattingTeam': currentBattingTeam,
        'currentBowlingTeam': currentBowlingTeam,
        'totalRuns': totalRuns,
        'totalWickets': totalWickets,
        'matchBalls': matchBalls,
        'extras': extras,
        'currentOverRuns': currentOverRuns,
        'overRunsHistory': overRunsHistory,
        'currentOverWickets': currentOverWickets,
        'overWicketsHistory': overWicketsHistory,
        'ballCumulativeRuns': ballCumulativeRuns,
        'isSecondInnings': isSecondInnings,
        'targetScore': targetScore,
        'firstInningsData': firstInningsData?.toJson(),
        'ballHistoryDisplay': ballHistoryDisplay,
        'squadBatting': squadBatting.map((p) => p.toJson()).toList(),
        'squadBowling': squadBowling.map((p) => p.toJson()).toList(),
        'activeBatsmenList': activeBatsmenList.map((b) => b.toJson()).toList(),
        'activeBowlersList': activeBowlersList.map((b) => b.toJson()).toList(),
        'striker': striker.toJson(),
        'nonStriker': nonStriker.toJson(),
        'currentBowler': currentBowler.toJson(),
        'lastBowlerId': lastBowlerId,
        'isMatchOver': isMatchOver,
        'isInningsBreak': isInningsBreak,
        'matchStatus': matchStatus,
        'winnerTeamName': winnerTeamName,
        'savedAt': savedAt.toIso8601String(),
        'resultId': resultId,
        'isFreeHit': isFreeHit,
        'matchFours': matchFours,
        'matchSixes': matchSixes,
        'deliveryLog': deliveryLog.map((d) => d.toJson()).toList(),
      };

  factory MatchDraft.fromJson(Map<String, dynamic> j) => MatchDraft(
        maxOvers: j['maxOvers'],
        totalPlayers: j['totalPlayers'],
        currentBattingTeam: j['currentBattingTeam'],
        currentBowlingTeam: j['currentBowlingTeam'],
        totalRuns: j['totalRuns'],
        totalWickets: j['totalWickets'],
        matchBalls: j['matchBalls'],
        extras: j['extras'],
        currentOverRuns: j['currentOverRuns'],
        overRunsHistory: (j['overRunsHistory'] as List? ?? []).map((e) => e as int).toList(),
        currentOverWickets: j['currentOverWickets'] ?? 0,
        overWicketsHistory: (j['overWicketsHistory'] as List? ?? []).map((e) => e as int).toList(),
        ballCumulativeRuns: (j['ballCumulativeRuns'] as List? ?? []).map((e) => e as int).toList(),
        isSecondInnings: j['isSecondInnings'],
        targetScore: j['targetScore'],
        firstInningsData: j['firstInningsData'] != null ? InningsHistory.fromJson(j['firstInningsData']) : null,
        ballHistoryDisplay: (j['ballHistoryDisplay'] as List? ?? []).map((e) => e.toString()).toList(),
        squadBatting: (j['squadBatting'] as List? ?? []).map((p) => Player.fromJson(p)).toList(),
        squadBowling: (j['squadBowling'] as List? ?? []).map((p) => Player.fromJson(p)).toList(),
        activeBatsmenList: (j['activeBatsmenList'] as List? ?? []).map((b) => Batsman.fromJson(b)).toList(),
        activeBowlersList: (j['activeBowlersList'] as List? ?? []).map((b) => Bowler.fromJson(b)).toList(),
        striker: Batsman.fromJson(j['striker']),
        nonStriker: Batsman.fromJson(j['nonStriker']),
        currentBowler: Bowler.fromJson(j['currentBowler']),
        lastBowlerId: j['lastBowlerId'],
        isMatchOver: j['isMatchOver'] ?? false,
        isInningsBreak: j['isInningsBreak'] ?? false,
        matchStatus: j['matchStatus'] ?? '',
        winnerTeamName: j['winnerTeamName'],
        savedAt: DateTime.parse(j['savedAt']),
        resultId: j['resultId'],
        isFreeHit: j['isFreeHit'] ?? false,
        matchFours: j['matchFours'] ?? 0,
        matchSixes: j['matchSixes'] ?? 0,
        deliveryLog: (j['deliveryLog'] as List? ?? []).map((d) => Delivery.fromJson(d)).toList(),
      );
}
/// Undo restores the whole snapshot at once instead of patching individual
/// fields, so a wicket/over-change followed by Undo can never leave a stale
/// or mismatched player object behind.
class BallSnapshot {
  final int totalRuns;
  final int totalWickets;
  final int matchBalls;
  final int extras;
  final int currentOverRuns;
  final List<int> overRunsHistory;
  final int currentOverWickets;
  final List<int> overWicketsHistory;
  // Cumulative team total after every delivery so far this innings -
  // mirrors overRunsHistory but at ball granularity, for the ball-by-ball
  // Scoring Comparison worm chart.
  final List<int> ballCumulativeRuns;
  final String? lastBowlerId;
  final String strikerId;
  final String nonStrikerId;
  final String currentBowlerId;
  final List<Batsman> activeBatsmenList;
  final List<Bowler> activeBowlersList;
  final List<String> ballHistoryDisplay;
  final bool isMatchOver;
  final bool isInningsBreak;
  final String matchStatus;
  final String? winnerTeamName;
  // Length of deliveryLog right before this ball was recorded - lets undo
  // truncate the log back to exactly this point instead of leaving a
  // stale Delivery entry for a ball that's been undone.
  final int deliveryLogLength;
  final bool isFreeHit;
  final int matchFours;
  final int matchSixes;

  BallSnapshot({
    required this.totalRuns,
    required this.totalWickets,
    required this.matchBalls,
    required this.extras,
    required this.currentOverRuns,
    this.overRunsHistory = const [],
    this.currentOverWickets = 0,
    this.overWicketsHistory = const [],
    this.ballCumulativeRuns = const [],
    required this.lastBowlerId,
    required this.strikerId,
    required this.nonStrikerId,
    required this.currentBowlerId,
    required this.activeBatsmenList,
    required this.activeBowlersList,
    required this.ballHistoryDisplay,
    required this.isMatchOver,
    required this.isInningsBreak,
    required this.matchStatus,
    required this.winnerTeamName,
    this.deliveryLogLength = 0,
    this.isFreeHit = false,
    this.matchFours = 0,
    this.matchSixes = 0,
  });
}

/// One saved photo (Photos page). Cloud-only - see StorageService.uploadPhoto
/// and the `photos` table + `photos` storage bucket SQL provided separately.
class PhotoEntry {
  final String id;
  final String url;
  final String storagePath;
  final String? caption;
  final DateTime createdAt;

  PhotoEntry({required this.id, required this.url, required this.storagePath, this.caption, required this.createdAt});
}

/// The signed-in user's profile - backed by the `profiles` table (see the
/// SQL provided separately), not just Supabase auth metadata, so it's a
/// real queryable row like everything else in this app.
class UserProfile {
  final String? name;
  final String? phone;
  final String? bio;
  final String? avatarUrl;

  UserProfile({this.name, this.phone, this.bio, this.avatarUrl});
}

/// A lightweight, live-updating scoreboard snapshot - deliberately NOT the
/// full match state (no full commentary/undo history), just enough for a
/// viewer on another device to see the score, who's batting/bowling, and
/// the target. Backed by the `live_matches` table (see the SQL provided
/// separately) - readable by anyone with the broadcast id, writable only by
/// the scorer.
class LiveBroadcast {
  final String id;
  final String teamA;
  final String teamB;
  final int totalRuns;
  final int totalWickets;
  final int matchBalls;
  final int maxOvers;
  final bool isSecondInnings;
  final int targetScore;
  final String striker;
  final int strikerRuns;
  final int strikerBalls;
  final int strikerFours;
  final int strikerSixes;
  final String nonStriker;
  final int nonStrikerRuns;
  final int nonStrikerBalls;
  final String bowler;
  final int bowlerWickets;
  final int bowlerRuns;
  final String bowlerOvers;
  final int extras;
  final int currentOverRuns;
  // Short outcome labels for this over so far (e.g. "1", "4", "W", "•"),
  // newest first - powers the little ball-by-ball chip row.
  final List<String> recentBalls;
  final bool isMatchOver;
  final String matchStatus;
  final String? videoUrl;
  final DateTime updatedAt;
  // True when the next ball is a free hit (the previous no-ball's
  // aftermath) - shown to viewers as a persistent banner.
  final bool isFreeHit;
  // Boundary running totals for THIS match - always present. Combined
  // client-side with a tournament's already-completed matches (see
  // LiveViewerScreen) to show a tournament-wide tally without any extra
  // per-ball writes.
  final int matchFours;
  final int matchSixes;
  // Non-null only when this match is part of a tournament - lets the
  // viewer do ONE extra query (on screen open, not per poll) to pull the
  // tournament's other completed matches and add their boundaries in.
  final String? tournamentId;
  // "New batter/bowler" intro card - non-null only right after a new
  // player is confirmed and only for one who has real career stats (see
  // StorageService.loadSpotlightCard). Viewers detect a genuinely new one
  // via SpotlightCard.at rather than assuming every poll means "show it
  // again".
  final SpotlightCard? spotlight;
  // On-demand broadcast graphics - pushed only when the scorer taps the
  // corresponding button on the new "PLAYERS" tab, not automatically.
  final BroadcastGraphData? graph;
  final BroadcastOversData? overs;
  final BroadcastPlayerBattle? playerBattle;
  // A single team's full squad - pushed on-demand when the scorer taps
  // one of the two "Playing XI" buttons (one per team) on the LIVE
  // CONTROL tab, same one-off timed-push pattern as graph/overs/
  // playerBattle above.
  final BroadcastPlayingXI? playingXI;
  // One team's full batting scorecard - pushed on-demand when the scorer
  // taps one of the two "Scorecard" buttons (one per team) on the LIVE
  // CONTROL tab, same one-off timed-push pattern as playingXI above.
  final BroadcastScorecardData? scorecard;
  // The fielding team's bowling figures (O/M/R/W/Econ per bowler) for the
  // current innings - pushed on-demand when the scorer taps the "bowling
  // team" button on the LIVE CONTROL tab (same button that used to push
  // that team's OWN batting scorecard - see _broadcastBowlingFigures).
  final BroadcastBowlingData? bowling;
  // Which stat the scorer has selected to show on the strip below the two
  // batsmen on viewers' screens - "crr", "rrr", "need", or "custom". Set from
  // the buttons/text field on the scorer's PLAYERS tab; stays selected until
  // the scorer picks a different one (unlike graph/overs/playerBattle, which
  // are one-off timed pushes).
  final String statLineMode;
  // Free text the scorer typed for the "custom" stat line mode - only shown
  // to viewers when statLineMode == 'custom'. Null/empty otherwise.
  final String? statLineCustomText;

  LiveBroadcast({
    required this.id,
    required this.teamA,
    required this.teamB,
    required this.totalRuns,
    required this.totalWickets,
    required this.matchBalls,
    required this.maxOvers,
    required this.isSecondInnings,
    required this.targetScore,
    required this.striker,
    this.strikerRuns = 0,
    this.strikerBalls = 0,
    this.strikerFours = 0,
    this.strikerSixes = 0,
    required this.nonStriker,
    this.nonStrikerRuns = 0,
    this.nonStrikerBalls = 0,
    required this.bowler,
    this.bowlerWickets = 0,
    this.bowlerRuns = 0,
    this.bowlerOvers = "0.0",
    this.extras = 0,
    this.currentOverRuns = 0,
    this.recentBalls = const [],
    required this.isMatchOver,
    required this.matchStatus,
    this.videoUrl,
    required this.updatedAt,
    this.isFreeHit = false,
    this.matchFours = 0,
    this.matchSixes = 0,
    this.tournamentId,
    this.spotlight,
    this.graph,
    this.overs,
    this.playerBattle,
    this.playingXI,
    this.scorecard,
    this.bowling,
    this.statLineMode = 'crr',
    this.statLineCustomText,
  });

  Map<String, dynamic> toJson() => {
        'runs': totalRuns,
        'wickets': totalWickets,
        'balls': matchBalls,
        'maxOvers': maxOvers,
        'isSecondInnings': isSecondInnings,
        'targetScore': targetScore,
        'striker': striker,
        'strikerRuns': strikerRuns,
        'strikerBalls': strikerBalls,
        'strikerFours': strikerFours,
        'strikerSixes': strikerSixes,
        'nonStriker': nonStriker,
        'nonStrikerRuns': nonStrikerRuns,
        'nonStrikerBalls': nonStrikerBalls,
        'bowler': bowler,
        'bowlerWickets': bowlerWickets,
        'bowlerRuns': bowlerRuns,
        'bowlerOvers': bowlerOvers,
        'extras': extras,
        'currentOverRuns': currentOverRuns,
        'matchFours': matchFours,
        'matchSixes': matchSixes,
        'tournamentId': tournamentId,
        'spotlight': spotlight?.toJson(),
        'graph': graph?.toJson(),
        'overs': overs?.toJson(),
        'playerBattle': playerBattle?.toJson(),
        'playingXI': playingXI?.toJson(),
        'scorecard': scorecard?.toJson(),
        'bowling': bowling?.toJson(),
        'statLineMode': statLineMode,
        'statLineCustomText': statLineCustomText,
        'recentBalls': recentBalls,
        'isMatchOver': isMatchOver,
        'matchStatus': matchStatus,
        'isFreeHit': isFreeHit,
      };

  factory LiveBroadcast.fromRow(Map<String, dynamic> row) {
    final data = row['data'] as Map<String, dynamic>? ?? {};
    return LiveBroadcast(
      id: row['id'],
      teamA: row['team_a'] ?? '',
      teamB: row['team_b'] ?? '',
      totalRuns: data['runs'] ?? 0,
      totalWickets: data['wickets'] ?? 0,
      matchBalls: data['balls'] ?? 0,
      maxOvers: data['maxOvers'] ?? 0,
      isSecondInnings: data['isSecondInnings'] ?? false,
      targetScore: data['targetScore'] ?? 0,
      striker: data['striker'] ?? '',
      strikerRuns: data['strikerRuns'] ?? 0,
      strikerBalls: data['strikerBalls'] ?? 0,
      strikerFours: data['strikerFours'] ?? 0,
      strikerSixes: data['strikerSixes'] ?? 0,
      nonStriker: data['nonStriker'] ?? '',
      nonStrikerRuns: data['nonStrikerRuns'] ?? 0,
      nonStrikerBalls: data['nonStrikerBalls'] ?? 0,
      bowler: data['bowler'] ?? '',
      bowlerWickets: data['bowlerWickets'] ?? 0,
      bowlerRuns: data['bowlerRuns'] ?? 0,
      bowlerOvers: data['bowlerOvers'] ?? "0.0",
      extras: data['extras'] ?? 0,
      currentOverRuns: data['currentOverRuns'] ?? 0,
      recentBalls: (data['recentBalls'] as List? ?? []).map((e) => e.toString()).toList(),
      isMatchOver: data['isMatchOver'] ?? false,
      matchStatus: data['matchStatus'] ?? '',
      videoUrl: row['video_url'],
      updatedAt: DateTime.parse(row['updated_at']),
      isFreeHit: data['isFreeHit'] ?? false,
      matchFours: data['matchFours'] ?? 0,
      matchSixes: data['matchSixes'] ?? 0,
      tournamentId: data['tournamentId'],
      spotlight: data['spotlight'] != null ? SpotlightCard.fromJson(data['spotlight']) : null,
      graph: data['graph'] != null ? BroadcastGraphData.fromJson(data['graph']) : null,
      overs: data['overs'] != null ? BroadcastOversData.fromJson(data['overs']) : null,
      playerBattle: data['playerBattle'] != null ? BroadcastPlayerBattle.fromJson(data['playerBattle']) : null,
      playingXI: data['playingXI'] != null ? BroadcastPlayingXI.fromJson(data['playingXI']) : null,
      scorecard: data['scorecard'] != null ? BroadcastScorecardData.fromJson(data['scorecard']) : null,
      bowling: data['bowling'] != null ? BroadcastBowlingData.fromJson(data['bowling']) : null,
      statLineMode: data['statLineMode'] ?? 'crr',
      statLineCustomText: data['statLineCustomText'] as String?,
    );
  }
}

/// Result of StorageService.loadHeadToHead(idA, idB).
class HeadToHead {
  final int opponentMatches;
  final int teammateMatches;
  final int playerAWins;
  final int playerBWins;

  HeadToHead({
    required this.opponentMatches,
    required this.teammateMatches,
    required this.playerAWins,
    required this.playerBWins,
  });

  factory HeadToHead.empty() => HeadToHead(opponentMatches: 0, teammateMatches: 0, playerAWins: 0, playerBWins: 0);

  int get undecidedMatches => opponentMatches - playerAWins - playerBWins;
}

/// A single earned achievement shown on PlayerDetailScreen - see
/// PlayerBadges.earnedBadges in extensions.dart for how these are computed
/// purely from existing PlayerStat numbers (no new schema/table needed).
class PlayerBadge {
  final String label;
  final IconData icon;
  final Color color;
  PlayerBadge(this.label, this.icon, this.color);
}

/// One row from `player_match_performances` - a single match's individual
/// batting/bowling line for one player. Powers PlayerDetailScreen's
/// "Recent Matches" list and form graph.
class MatchPerformance {
  final String matchId;
  final DateTime playedAt;
  final String? opponentTeam;
  final int runs;
  final int balls;
  final int fours;
  final int sixes;
  final String? dismissal;
  final int wickets;
  final int runsConceded;
  final double oversBowled;

  MatchPerformance({
    required this.matchId,
    required this.playedAt,
    this.opponentTeam,
    this.runs = 0,
    this.balls = 0,
    this.fours = 0,
    this.sixes = 0,
    this.dismissal,
    this.wickets = 0,
    this.runsConceded = 0,
    this.oversBowled = 0,
  });

  factory MatchPerformance.fromJson(Map<String, dynamic> j) => MatchPerformance(
        matchId: j['match_id'],
        playedAt: DateTime.parse(j['played_at']),
        opponentTeam: j['opponent_team'],
        runs: j['runs'] ?? 0,
        balls: j['balls'] ?? 0,
        fours: j['fours'] ?? 0,
        sixes: j['sixes'] ?? 0,
        dismissal: j['dismissal'],
        wickets: j['wickets'] ?? 0,
        runsConceded: j['runs_conceded'] ?? 0,
        oversBowled: (j['overs_bowled'] ?? 0).toDouble(),
      );
}

/// One row from `player_milestones` - a badge a player newly crossed into
/// (see StorageService._detectAndRecordMilestones), not every badge they
/// currently hold. Powers the in-app notification feed.
class Milestone {
  final String id;
  final String playerId;
  final String playerName;
  final String badgeLabel;
  final DateTime createdAt;

  Milestone({required this.id, required this.playerId, required this.playerName, required this.badgeLabel, required this.createdAt});

  factory Milestone.fromJson(Map<String, dynamic> j) => Milestone(
        id: j['id'],
        playerId: j['player_id'],
        playerName: j['player_name'],
        badgeLabel: j['badge_label'],
        createdAt: DateTime.parse(j['created_at']),
      );
}

/// Match-wide run-rate comparison ("worm chart") pushed to viewers on
/// demand via the scorer's "Graph" button - same ball-by-ball cumulative
/// data the scorer's own local GRAPH/COMPARE tab already computes.
class BroadcastGraphData {
  final String teamAName;
  final String teamBName;
  // Cumulative team total after EVERY delivery (not just at over
  // boundaries) - one entry per ball bowled so the line moves smoothly as
  // the scorer scores, matching a TV broadcast's worm graph rather than
  // stair-stepping only once per over.
  final List<int> teamACumulative;
  final List<int> teamBCumulative;
  final int maxOvers;
  // e.g. "TEAM NEED 45 MORE TO WIN FROM 8.2 OVERS AT 5.45 RPO" - matches
  // the scorer's own COMPARE tab exactly, only shown during a 2nd innings
  // chase (null otherwise).
  final String? footerText;
  final DateTime at;

  BroadcastGraphData({
    required this.teamAName,
    required this.teamBName,
    required this.teamACumulative,
    required this.teamBCumulative,
    required this.maxOvers,
    this.footerText,
    required this.at,
  });

  Map<String, dynamic> toJson() => {
        'teamAName': teamAName,
        'teamBName': teamBName,
        'teamACumulative': teamACumulative,
        'teamBCumulative': teamBCumulative,
        'maxOvers': maxOvers,
        'footerText': footerText,
        'at': at.toIso8601String(),
      };

  factory BroadcastGraphData.fromJson(Map<String, dynamic> j) => BroadcastGraphData(
        teamAName: j['teamAName'],
        teamBName: j['teamBName'],
        teamACumulative: (j['teamACumulative'] as List? ?? []).map((e) => e as int).toList(),
        teamBCumulative: (j['teamBCumulative'] as List? ?? []).map((e) => e as int).toList(),
        maxOvers: j['maxOvers'] ?? 20,
        footerText: j['footerText'],
        at: DateTime.parse(j['at']),
      );
}

/// Runs-per-over bar chart pushed to viewers on demand via the scorer's
/// "Runs/Over" button - same data the scorer's own GRAPH tab already
/// computes and shows locally.
class BroadcastOversData {
  final String teamName;
  final List<int> overRuns;
  // Wickets that fell in each over, index-aligned with overRuns (index 0 =
  // over 1) - drives the red "W" dots stacked above each bar on the
  // viewer's chart, same as the fall-of-wicket markers on a TV-broadcast
  // Manhattan/run-rate graph. Defaults to empty so older saved/cached
  // payloads without this field still decode fine (just renders with no
  // dots instead of crashing).
  final List<int> overWickets;
  final DateTime at;

  BroadcastOversData({required this.teamName, required this.overRuns, this.overWickets = const [], required this.at});

  Map<String, dynamic> toJson() => {
        'teamName': teamName,
        'overRuns': overRuns,
        'overWickets': overWickets,
        'at': at.toIso8601String(),
      };

  factory BroadcastOversData.fromJson(Map<String, dynamic> j) => BroadcastOversData(
        teamName: j['teamName'],
        overRuns: (j['overRuns'] as List? ?? []).map((e) => e as int).toList(),
        overWickets: (j['overWickets'] as List? ?? []).map((e) => e as int).toList(),
        at: DateTime.parse(j['at']),
      );
}

/// Striker-vs-bowler head-to-head ("Player Battle") pushed to viewers on
/// demand via the scorer's "Compare" button - sourced from the same
/// `player_matchups` data ComparePlayersScreen already shows.
class BroadcastPlayerBattle {
  final String batsmanName;
  final String bowlerName;
  final int runs;
  final int balls;
  final int dismissals;
  final DateTime at;

  BroadcastPlayerBattle({
    required this.batsmanName,
    required this.bowlerName,
    required this.runs,
    required this.balls,
    required this.dismissals,
    required this.at,
  });

  Map<String, dynamic> toJson() => {
        'batsmanName': batsmanName,
        'bowlerName': bowlerName,
        'runs': runs,
        'balls': balls,
        'dismissals': dismissals,
        'at': at.toIso8601String(),
      };

  factory BroadcastPlayerBattle.fromJson(Map<String, dynamic> j) => BroadcastPlayerBattle(
        batsmanName: j['batsmanName'],
        bowlerName: j['bowlerName'],
        runs: j['runs'] ?? 0,
        balls: j['balls'] ?? 0,
        dismissals: j['dismissals'] ?? 0,
        at: DateTime.parse(j['at']),
      );
}

/// A "new batter/bowler" intro card for live viewers - resolved ONCE by
/// the scorer (see StorageService.loadSpotlightCard) when that player is
/// confirmed, then carried along on the next regular broadcast update.
/// [at] lets the viewer tell "this is a new arrival" apart from "the same
/// spotlight from a few polls ago" without needing its own query.
class SpotlightCard {
  final String name;
  final String? photoUrl;
  final bool isBatter;
  final int matches;
  final int primaryValue; // runs (batter) or wickets (bowler)
  final double? average;
  final double? secondaryRate; // strike rate (batter) or economy (bowler)
  final String tertiaryLabel; // "Highest Score" or "Best Bowling"
  final String tertiaryValue; // "87" or "4/23"
  final DateTime at;

  SpotlightCard({
    required this.name,
    this.photoUrl,
    required this.isBatter,
    required this.matches,
    required this.primaryValue,
    this.average,
    this.secondaryRate,
    required this.tertiaryLabel,
    required this.tertiaryValue,
    required this.at,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'photoUrl': photoUrl,
        'isBatter': isBatter,
        'matches': matches,
        'primaryValue': primaryValue,
        'average': average,
        'secondaryRate': secondaryRate,
        'tertiaryLabel': tertiaryLabel,
        'tertiaryValue': tertiaryValue,
        'at': at.toIso8601String(),
      };

  factory SpotlightCard.fromJson(Map<String, dynamic> j) => SpotlightCard(
        name: j['name'],
        photoUrl: j['photoUrl'],
        isBatter: j['isBatter'] ?? true,
        matches: j['matches'] ?? 0,
        primaryValue: j['primaryValue'] ?? 0,
        average: (j['average'] as num?)?.toDouble(),
        secondaryRate: (j['secondaryRate'] as num?)?.toDouble(),
        tertiaryLabel: j['tertiaryLabel'] ?? '',
        tertiaryValue: j['tertiaryValue'] ?? '-',
        at: DateTime.parse(j['at']),
      );
}

/// "Playing XI" broadcast card - pushed on-demand from the scorer's LIVE
/// CONTROL tab (see MatchScorerScreen._broadcastPlayingXI) so viewers can
/// see both full squads at once. Sourced directly from squadBatting/
/// squadBowling, which already exist locally - no extra query needed.
class BroadcastPlayingXI {
  final String teamName;
  final List<String> names;
  // Parallel to [names] (same index = same player). A null/empty entry
  // means that player has no photo in the shared player registry - the
  // viewer card falls back to a generic silhouette for that slot rather
  // than leaving it blank. Added alongside [names] rather than replacing
  // it so older broadcasts (pushed before this field existed) still parse
  // fine: fromJson pads/truncates to names.length with nulls.
  final List<String?> photoUrls;
  // Parallel to [names] - each squad player's Player.role at broadcast
  // time (see kPlayerRoles), or null if that player was never tagged with
  // one. Same pad/truncate-to-names.length backward compatibility as
  // [photoUrls].
  final List<String?> roles;
  final DateTime at;

  BroadcastPlayingXI({
    required this.teamName,
    required this.names,
    List<String?>? photoUrls,
    List<String?>? roles,
    required this.at,
  })  : photoUrls = photoUrls ?? List<String?>.filled(names.length, null),
        roles = roles ?? List<String?>.filled(names.length, null);

  Map<String, dynamic> toJson() => {
        'teamName': teamName,
        'names': names,
        'photoUrls': photoUrls,
        'roles': roles,
        'at': at.toIso8601String(),
      };

  factory BroadcastPlayingXI.fromJson(Map<String, dynamic> j) {
    final names = (j['names'] as List? ?? []).map((e) => e.toString()).toList();
    final rawPhotos = (j['photoUrls'] as List?) ?? const [];
    final photoUrls = List<String?>.generate(
      names.length,
      (i) => i < rawPhotos.length ? (rawPhotos[i] as String?) : null,
    );
    final rawRoles = (j['roles'] as List?) ?? const [];
    final roles = List<String?>.generate(
      names.length,
      (i) => i < rawRoles.length ? (rawRoles[i] as String?) : null,
    );
    return BroadcastPlayingXI(
      teamName: j['teamName'] ?? '',
      names: names,
      photoUrls: photoUrls,
      roles: roles,
      at: DateTime.parse(j['at']),
    );
  }
}

/// One team's full batting scorecard, pushed on-demand when the scorer taps
/// a "Scorecard" button on the LIVE CONTROL tab (see
/// MatchScorerScreen._broadcastScorecard) - shown to viewers as a
/// broadcast-style innings card (team name, every batter's runs/balls/
/// dismissal, extras, overs and total), same one-off timed-push pattern as
/// graph/overs/playerBattle/playingXI above. Reuses the existing Batsman
/// model as-is (name/runs/balls/dismissal already match what the card
/// needs) rather than inventing a parallel-lists shape like
/// BroadcastPlayingXI - a scorecard's rows are naturally one object per
/// batter, not per-field arrays.
class BroadcastScorecardData {
  final String teamName;
  final int totalRuns;
  final int totalWickets;
  final String oversDisplay;
  final int extras;
  final List<Batsman> batsmen;
  final DateTime at;
  // Only set when the match belongs to a tournament (see
  // MatchScorerScreen.tournamentId) - shown as a small subtitle line under
  // the team name on the broadcast card, TV-graphic style. Null for a
  // standalone (non-tournament) match, in which case that line is simply
  // omitted rather than left blank.
  final String? tournamentName;
  // id of whichever not-out batsman is CURRENTLY ON STRIKE (facing the
  // bowler) - null when the innings is already over (the "already batted"
  // team's card, pushed via _broadcastScorecard(battingTeam: false), has
  // no current striker at all). During an in-progress innings there are
  // always two not-out batsmen (striker + non-striker), but only the
  // striker should get the "on strike" arrow on the viewer card - without
  // this id there was no way to tell the two apart, so BOTH not-out rows
  // wrongly got the arrow.
  final String? strikerId;
  // Squad members who haven't come out to bat yet this innings (just
  // names - runs/balls don't apply to them so there's no need for the
  // full Player object). Shown on the viewer card as dimmed "YET TO BAT"
  // rows after the played batsmen, so the full squad size is always
  // visible even mid-innings, not just once everyone's out. Empty list
  // (not null) once nobody's left to bat - null only for old cached data
  // pushed before this field existed.
  final List<String> yetToBat;

  BroadcastScorecardData({
    required this.teamName,
    required this.totalRuns,
    required this.totalWickets,
    required this.oversDisplay,
    required this.extras,
    required this.batsmen,
    required this.at,
    this.tournamentName,
    this.strikerId,
    this.yetToBat = const [],
  });

  Map<String, dynamic> toJson() => {
        'teamName': teamName,
        'totalRuns': totalRuns,
        'totalWickets': totalWickets,
        'oversDisplay': oversDisplay,
        'extras': extras,
        'batsmen': batsmen.map((b) => b.toJson()).toList(),
        'at': at.toIso8601String(),
        'tournamentName': tournamentName,
        'strikerId': strikerId,
        'yetToBat': yetToBat,
      };

  factory BroadcastScorecardData.fromJson(Map<String, dynamic> j) => BroadcastScorecardData(
        teamName: j['teamName'] ?? '',
        totalRuns: j['totalRuns'] ?? 0,
        totalWickets: j['totalWickets'] ?? 0,
        oversDisplay: j['oversDisplay'] ?? '0.0',
        extras: j['extras'] ?? 0,
        batsmen: (j['batsmen'] as List? ?? []).map((b) => Batsman.fromJson(b)).toList(),
        at: DateTime.parse(j['at']),
        tournamentName: j['tournamentName'],
        strikerId: j['strikerId'],
        yetToBat: List<String>.from(j['yetToBat'] ?? const []),
      );
}

/// The FIELDING team's bowling figures for the current innings - pushed via
/// MatchScorerScreen._broadcastBowlingFigures when the scorer taps the
/// "bowling team" button on the LIVE CONTROL tab. [teamName] here is the
/// team whose BOWLERS are listed (i.e. currentBowlingTeam), while
/// [totalRuns]/[totalWickets]/[oversDisplay]/[extras] describe the innings
/// those bowlers are conceding runs in - the CURRENT batting team's score,
/// same figures _broadcastScorecard(battingTeam: true) already sends.
class BroadcastBowlingData {
  final String teamName;
  final int totalRuns;
  final int totalWickets;
  final String oversDisplay;
  final int extras;
  final List<Bowler> bowlers;
  final DateTime at;
  final String? tournamentName;

  BroadcastBowlingData({
    required this.teamName,
    required this.totalRuns,
    required this.totalWickets,
    required this.oversDisplay,
    required this.extras,
    required this.bowlers,
    required this.at,
    this.tournamentName,
  });

  Map<String, dynamic> toJson() => {
        'teamName': teamName,
        'totalRuns': totalRuns,
        'totalWickets': totalWickets,
        'oversDisplay': oversDisplay,
        'extras': extras,
        'bowlers': bowlers.map((b) => b.toJson()).toList(),
        'at': at.toIso8601String(),
        'tournamentName': tournamentName,
      };

  factory BroadcastBowlingData.fromJson(Map<String, dynamic> j) => BroadcastBowlingData(
        teamName: j['teamName'] ?? '',
        totalRuns: j['totalRuns'] ?? 0,
        totalWickets: j['totalWickets'] ?? 0,
        oversDisplay: j['oversDisplay'] ?? '0.0',
        extras: j['extras'] ?? 0,
        bowlers: (j['bowlers'] as List? ?? []).map((b) => Bowler.fromJson(b)).toList(),
        at: DateTime.parse(j['at']),
        tournamentName: j['tournamentName'],
      );
}

/// Result of StorageService.checkForUpdate(). [mandatory] means the
/// installed version is below `min_required_version` in `app_config` - the
/// dialog for this must not be dismissible.
class UpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final bool mandatory;
  final String? message;
  final String storeUrl;

  UpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.mandatory,
    required this.storeUrl,
    this.message,
  });
}

/// A global, cross-account player identity backed by the `players` table
/// (see player_registry_schema.sql). Unlike the per-match `Player`
/// (a fresh id minted every time a squad is typed) and the per-tournament
/// `PlayerStat` (a breakdown scoped to one Tournament), this is the single
/// canonical record searchable from any account - it's what the Players
/// screen and squad autocomplete both point at.
class GlobalPlayer {
  final String id;
  final String name;
  // Non-null means this row lost a merge and should be treated as an alias
  // of [mergedInto] rather than shown in search results.
  final String? mergedInto;
  final String? photoUrl;

  GlobalPlayer({required this.id, required this.name, this.mergedInto, this.photoUrl});

  factory GlobalPlayer.fromJson(Map<String, dynamic> j) => GlobalPlayer(
        id: j['id'],
        name: j['canonical_name'],
        mergedInto: j['merged_into'],
        photoUrl: j['photo_url'],
      );

  GlobalPlayer copyWith({String? photoUrl}) => GlobalPlayer(
        id: id,
        name: name,
        mergedInto: mergedInto,
        photoUrl: photoUrl ?? this.photoUrl,
      );
}