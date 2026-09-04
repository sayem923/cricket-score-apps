import 'package:flutter/material.dart';
import '../models/models.dart';

/// Aggregates this match's ball-by-ball Delivery log into per-(batsman,
/// bowler)-pair totals, keyed by the squad-LOCAL ids (same pattern as
/// MatchResultStatDeltas.computePlayerStatDeltas - StorageService resolves
/// local ids to global registry ids before pushing). Empty for any match
/// saved before Delivery tracking existed.
extension MatchResultMatchups on MatchResultData {
  Map<(String batsmanLocalId, String bowlerLocalId), MatchupDelta> computeMatchupDeltas() {
    final map = <(String, String), MatchupDelta>{};
    for (final d in deliveries) {
      final key = (d.batsmanId, d.bowlerId);
      final entry = map.putIfAbsent(key, () => MatchupDelta());
      if (d.countsAsBallFaced) entry.balls++;
      entry.runs += d.runsOffBat;
      // Only count as "bowler X dismissed batsman Y" when the bowler
      // actually gets credit AND the person dismissed is the same person
      // who faced this ball (excludes a run-out of the non-striker, which
      // isn't attributable to whoever happened to be bowling).
      if (d.isWicket && d.bowlerCreditedWicket && d.dismissedPlayerId == d.batsmanId) {
        entry.dismissals++;
      }
    }
    return map;
  }
}

extension PlayerStatMetrics on PlayerStat {
  // Returns -1 when there's no meaningful average yet (no innings played).
  // Callers should display "-" when avg < 0.
  double get avg {
    if (innings == 0) return -1;
    int timesDismissed = innings - notOuts;
    if (timesDismissed == 0) return runs.toDouble(); // undefeated average
    return runs / timesDismissed;
  }

  double get sr => balls > 0 ? (runs / balls) * 100 : 0.0;
  double get econ => oversBowled > 0 ? runsConceded / oversBowled : 0.0;
  double get bowlSr => wickets > 0 ? (oversBowled * 6) / wickets : 0.0;
  double get bowlAvg => wickets > 0 ? runsConceded / wickets : 0.0;
  String get bestBowling => "$bbWickets/$bbRuns";
}

/// Turns this player's lifetime numbers into a badge list for
/// PlayerDetailScreen - purely derived from existing PlayerStat fields, no
/// new schema needed. Per category, only the HIGHEST tier reached is
/// returned (e.g. someone with 120 matches gets "100 Matches", not also
/// "50 Matches" and "25 Matches") so the badge row stays short and reads
/// as a real achievement list rather than a checklist of everything ever
/// passed along the way.
extension PlayerBadges on PlayerStat {
  static const _matchTiers = [10, 25, 50, 100, 200];
  static const _runTiers = [100, 500, 1000, 2500, 5000, 10000];
  static const _wicketTiers = [10, 25, 50, 100, 200];

  List<PlayerBadge> get earnedBadges {
    final badges = <PlayerBadge>[];

    final matchTier = _highestTierReached(matches, _matchTiers);
    if (matchTier != null) {
      badges.add(PlayerBadge('$matchTier Matches', Icons.event_available, const Color(0xFF0284C7)));
    }

    final runTier = _highestTierReached(runs, _runTiers);
    if (runTier != null) {
      badges.add(PlayerBadge('$runTier Runs', Icons.sports_cricket, const Color(0xFF16A34A)));
    }

    if (hundreds > 0) {
      badges.add(PlayerBadge(hundreds >= 5 ? '$hundreds Centuries' : 'Century Maker', Icons.emoji_events, const Color(0xFFD4AF37)));
    }
    if (fifties > 0) {
      badges.add(PlayerBadge(fifties >= 10 ? '$fifties Fifties' : 'Fifty Club', Icons.star, const Color(0xFFF59E0B)));
    }

    final wicketTier = _highestTierReached(wickets, _wicketTiers);
    if (wicketTier != null) {
      badges.add(PlayerBadge('$wicketTier Wickets', Icons.sports_baseball, const Color(0xFFD97706)));
    }

    if (bbWickets >= 5) {
      badges.add(PlayerBadge('5-Wicket Haul', Icons.local_fire_department, const Color(0xFFDC2626)));
    }
    // Separate from the personal-best badge above: this is a running count
    // of every innings with 4+ wickets across their career (5-wicket
    // hauls count toward this too) - not mutually exclusive with it, so
    // both can and should show together.
    if (fourWickets > 0) {
      badges.add(PlayerBadge(
        fourWickets == 1 ? '4-Wicket Haul' : '$fourWickets Four-Wicket Hauls',
        Icons.whatshot,
        const Color(0xFFEA580C),
      ));
    }

    return badges;
  }

  static int? _highestTierReached(int value, List<int> tiers) {
    int? reached;
    for (final t in tiers) {
      if (value >= t) reached = t;
    }
    return reached;
  }
}

extension BatsmanLogic on Batsman {
  String get sr {
    if (balls == 0) return "0.0";
    return ((runs / balls) * 100).toStringAsFixed(1);
  }

  Batsman clone() {
    return Batsman(
      name: name, id: id, runs: runs, balls: balls, fours: fours, sixes: sixes, dismissal: dismissal,
    );
  }
}

extension BowlerLogic on Bowler {
  String get oversDisplay => '${balls ~/ 6}.${balls % 6}';

  // Runs conceded per over, e.g. "7.33" - standard economy-rate figure
  // shown alongside O/M/R/W on a bowling scorecard. 0 balls bowled yet
  // (a bowler who's been brought on but not bowled a delivery) shows
  // "0.00" rather than dividing by zero.
  String get economy => balls == 0 ? "0.00" : ((runs * 6) / balls).toStringAsFixed(2);

  Bowler clone() {
    return Bowler(
      name: name, id: id, runs: runs, wickets: wickets, balls: balls, maidens: maidens,
    );
  }
}

extension MatchUtils on TournamentMatch {
  bool get isCompleted => status == 'Completed';
  // Exited early via "Exit Anyway" mid-scoring - has a resumable draft
  // embedded in matchData, distinct from a match that hasn't started yet.
  bool get isIncomplete => status == 'Incomplete';
}

extension StatSorting on List<PlayerStat> {
  void sortByCategory(String category) {
    switch (category) {
      case "Most Runs": sort((a, b) => b.runs.compareTo(a.runs)); break;
      case "Highest Score": sort((a, b) => b.highestScore.compareTo(a.highestScore)); break;
      case "Best Average": sort((a, b) => b.avg.compareTo(a.avg)); break;
      case "Best Strike Rate": sort((a, b) => b.sr.compareTo(a.sr)); break;
      case "Most Hundreds": sort((a, b) => b.hundreds.compareTo(a.hundreds)); break;
      case "Most Fifties": sort((a, b) => b.fifties.compareTo(a.fifties)); break;
      case "Most Fours": sort((a, b) => b.fours.compareTo(a.fours)); break;
      case "Most Sixes": sort((a, b) => b.sixes.compareTo(a.sixes)); break;
      case "Most Nineties": sort((a, b) => b.nineties.compareTo(a.nineties)); break;
      case "Most Wickets": sort((a, b) => b.wickets.compareTo(a.wickets)); break;
      case "Best Bowling Average": sort((a, b) { if(a.wickets==0) return 1; if(b.wickets==0) return -1; return a.bowlAvg.compareTo(b.bowlAvg); }); break;
      case "Best Bowling": sort((a, b) { if (b.bbWickets != a.bbWickets) return b.bbWickets.compareTo(a.bbWickets); return a.bbRuns.compareTo(b.bbRuns); }); break;
      case "Most 4 Wickets": sort((a, b) => b.fourWickets.compareTo(a.fourWickets)); break;
      case "Best Economy": sort((a, b) { if(a.oversBowled==0) return 1; if(b.oversBowled==0) return -1; return a.econ.compareTo(b.econ); }); break;
      case "Best Bowling Strike Rate": sort((a, b) { if(a.wickets==0) return 1; if(b.wickets==0) return -1; return a.bowlSr.compareTo(b.bowlSr); }); break;
    }
  }
}

/// Client-side preview helper for the merge screen - mirrors exactly what
/// the merge_players SQL function does server-side (see
/// player_registry_schema.sql), so the "combined preview" the user sees
/// before confirming matches what actually gets written.
extension PlayerStatMerge on PlayerStat {
  void mergeWith(PlayerStat other) {
    matches += other.matches;
    innings += other.innings;
    notOuts += other.notOuts;
    runs += other.runs;
    balls += other.balls;
    fours += other.fours;
    sixes += other.sixes;
    hundreds += other.hundreds;
    fifties += other.fifties;
    nineties += other.nineties;
    // Highest Score is a single-match record, not a running total - keep
    // whichever is bigger rather than summing.
    highestScore = highestScore > other.highestScore ? highestScore : other.highestScore;
    wickets += other.wickets;
    runsConceded += other.runsConceded;
    oversBowled += other.oversBowled;
    fourWickets += other.fourWickets;
    // Best Bowling is also a single-match record - keep more wickets, and
    // on a tie, fewer runs conceded.
    if (other.bbWickets > bbWickets || (other.bbWickets == bbWickets && other.bbRuns < bbRuns)) {
      bbWickets = other.bbWickets;
      bbRuns = other.bbRuns;
    }
  }
}

/// Builds a [PlayerStat] from a `player_career_stats` row (snake_case
/// columns - see player_registry_schema.sql), so the Player Detail screen
/// can reuse every getter in [PlayerStatMetrics] unchanged.
extension PlayerStatFromCareerRow on PlayerStat {
  static PlayerStat fromCareerRow(String name, Map<String, dynamic> r) {
    final p = PlayerStat(name: name);
    p.matches = r['matches'] ?? 0;
    p.innings = r['innings'] ?? 0;
    p.notOuts = r['not_outs'] ?? 0;
    p.runs = r['runs'] ?? 0;
    p.balls = r['balls'] ?? 0;
    p.fours = r['fours'] ?? 0;
    p.sixes = r['sixes'] ?? 0;
    p.hundreds = r['hundreds'] ?? 0;
    p.fifties = r['fifties'] ?? 0;
    p.nineties = r['nineties'] ?? 0;
    p.highestScore = r['highest_score'] ?? 0;
    p.wickets = r['wickets'] ?? 0;
    p.runsConceded = r['runs_conceded'] ?? 0;
    p.oversBowled = (r['overs_bowled'] ?? 0).toDouble();
    p.fourWickets = r['four_wickets'] ?? 0;
    p.bbWickets = r['bb_wickets'] ?? 0;
    p.bbRuns = r['bb_runs'] ?? 0;
    return p;
  }
}

/// Turns one match's raw scorecard (allBatsmen/allBowlers) into a
/// per-player, single-match [PlayerStat] delta keyed by the *local squad*
/// player id - not the global registry id, since a match's scorecard has no
/// idea what a player's global id is. Callers (StorageService) resolve
/// squad id -> global id via findOrCreateGlobalPlayer before pushing.
///
/// Mirrors exactly the per-match math in
/// TournamentDashboard._applyMatchStatsToTournament's player-stats loop, so
/// a quick match and a tournament match contribute identically to a
/// player's global career stats.
extension MatchResultStatDeltas on MatchResultData {
  Map<String, PlayerStat> computePlayerStatDeltas() {
    final Map<String, String> idToName = {};
    for (final bat in allBatsmen) idToName[bat.id] = bat.name;
    for (final bowl in allBowlers) idToName[bowl.id] = bowl.name;

    final Map<String, PlayerStat> deltas = {
      for (final entry in idToName.entries) entry.key: (PlayerStat(name: entry.value)..matches = 1),
    };

    for (final bat in allBatsmen) {
      final stat = deltas[bat.id]!;
      if (bat.balls > 0 || bat.dismissal != "not out") stat.innings++;
      if (bat.dismissal == "not out") stat.notOuts++;
      stat.runs += bat.runs;
      stat.balls += bat.balls;
      stat.fours += bat.fours;
      stat.sixes += bat.sixes;
      if (bat.runs >= 100) {
        stat.hundreds++;
      } else if (bat.runs >= 50) {
        stat.fifties++;
      }
      if (bat.runs >= 90 && bat.runs < 100) stat.nineties++;
      if (bat.runs > stat.highestScore) stat.highestScore = bat.runs;
    }

    for (final bowl in allBowlers) {
      final stat = deltas[bowl.id]!;
      stat.wickets += bowl.wickets;
      stat.runsConceded += bowl.runs;
      stat.oversBowled += bowl.balls / 6.0;
      if (bowl.wickets >= 4) stat.fourWickets++;
      if (stat.bbWickets < bowl.wickets || (stat.bbWickets == bowl.wickets && stat.bbRuns > bowl.runs)) {
        stat.bbWickets = bowl.wickets;
        stat.bbRuns = bowl.runs;
      }
    }

    return deltas;
  }
}