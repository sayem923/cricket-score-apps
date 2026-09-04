import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../../models/models.dart';
import '../../utils/extensions.dart';
import '../../services/storage_service.dart';
import '../players/player_detail_screen.dart';
import '../players/compare_players_screen.dart';
import 'match_result_screen.dart';
import '../../widgets/share_format_sheet.dart';
import '../../widgets/share_score_cards.dart';
import '../../utils/share_image.dart';
import '../../l10n/app_strings.dart';
import '../../services/deep_link_service.dart';

class MatchScorerScreen extends StatefulWidget {
  final String? teamA;
  final String? teamB;
  final int? maxOvers;
  final int? playersPerTeam;
  final String? strikerName;
  final String? nonStrikerName;
  final String? bowlerName;

  final List<Player>? initialSquadA;
  final List<Player>? initialSquadB;

  final Function(MatchResultData)? onMatchComplete;

  // When set, the screen resumes an in-progress match from this saved draft
  // instead of starting fresh - used to recover a match after the app was
  // force-closed (e.g. swiped away from recent apps) mid-scoring.
  final MatchDraft? draft;

  // Tournament mode only: fired after every ball with the current partial
  // result (isComplete: false) so the dashboard can keep the match
  // resumable even if the app is killed outright, not just on a confirmed
  // "Exit Anyway". The bool is true right at an over boundary, a hint to do
  // a full cloud sync there instead of a cheaper local-only write every ball.
  final Function(MatchResultData result, bool isOverBoundary)? onProgressUpdate;

  // True when this screen is nested inside another match flow (currently:
  // the Super Over) rather than being a real standalone match - suppresses
  // the "Match Saved Successfully!" snackbar on finish, which would
  // otherwise misleadingly imply the outer match itself was just saved.
  final bool suppressSavedSnackbar;

  // Non-null only when this match belongs to a tournament - purely
  // decorative for "Go Live" (see LiveBroadcast.tournamentId), so viewers
  // can see a tournament-wide boundary tally. Nothing else in scoring
  // depends on it.
  final String? tournamentId;

  // BUG FIX (live viewers stuck on "Match Tied!", never seeing the Super
  // Over score): when the main match ended tied and the scorer started a
  // Super Over, _offerSuperOver() below pushes a brand-new
  // MatchScorerScreen for it - but that new instance's own _broadcastId
  // always started null, so none of ITS scoring ever got pushed to the
  // live broadcast; viewers just kept seeing whatever the outer match
  // last sent (the tie) until the very end. Passing the outer match's
  // current broadcast id in here lets the Super Over screen push live
  // updates to that SAME broadcast, so anyone already watching sees the
  // Super Over's score ball-by-ball, same as the main innings. Null
  // (the default) when the outer match wasn't live in the first place -
  // in that case the Super Over simply isn't broadcast either, same as
  // before.
  final String? superOverBroadcastId;

  const MatchScorerScreen({
    super.key,
    this.teamA,
    this.teamB,
    this.maxOvers,
    this.playersPerTeam,
    this.strikerName,
    this.nonStrikerName,
    this.bowlerName,
    this.initialSquadA,
    this.initialSquadB,
    this.onMatchComplete,
    this.draft,
    this.onProgressUpdate,
    this.suppressSavedSnackbar = false,
    this.tournamentId,
    this.superOverBroadcastId,
  }) : assert(draft != null || (teamA != null && teamB != null && maxOvers != null && playersPerTeam != null && strikerName != null && nonStrikerName != null && bowlerName != null), 'Either a draft or full match-setup params must be provided');

  @override
  State<MatchScorerScreen> createState() => _MatchScorerScreenState();
}

class _MatchScorerScreenState extends State<MatchScorerScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  late String currentBattingTeam;
  late String currentBowlingTeam;

  // Match Stats
  int totalRuns = 0;
  int totalWickets = 0;
  int matchBalls = 0;
  int extras = 0;
  // Runs conceded so far in the over currently being bowled - used to detect maiden overs.
  int currentOverRuns = 0;
  // Runs scored in each completed over of the current innings, for the
  // Graph tab. currentOverRuns (above) is the in-progress over on top.
  List<int> overRunsHistory = [];
  // Same idea, but counting wickets - drives the red "W" dot markers drawn
  // above each bar of the Runs/Over chart (local Graph tab and the
  // broadcast view viewers see), the same way a TV run-rate graph marks
  // the fall of each wicket against the over it fell in.
  int currentOverWickets = 0;
  List<int> overWicketsHistory = [];
  // Cumulative team total after every delivery bowled this innings (index
  // 0 = total after ball 1, etc, including extras) - feeds the ball-by-ball
  // Scoring Comparison worm chart so it moves on every ball instead of
  // jumping only at over boundaries.
  List<int> ballCumulativeRuns = [];

  late int totalPlayers;
  // Mutable copy of maxOvers - editable mid-match via Manage Squad/Settings,
  // so an accidental wrong overs count at match start can be corrected.
  late int maxOvers;

  // Innings Data
  bool isSecondInnings = false;
  int targetScore = 0;
  InningsHistory? firstInningsData;

  List<String> ballHistoryDisplay = [];
  // Ball-by-ball batter-vs-bowler log across both innings - appended to
  // once per delivery inside _processDelivery, carried through to the
  // final MatchResultData for head-to-head "Player Battle" stats. Undo
  // truncates this back via BallSnapshot.deliveryLogLength, same as every
  // other piece of scoring state.
  List<Delivery> deliveryLog = [];
  // True when the NEXT delivery bowled is a free hit (i.e. this delivery
  // or the most recent legal-or-not delivery was a no-ball, and no legal
  // delivery has happened since). Broadcast to viewers as a persistent
  // banner - see _pushLiveUpdate / LiveBroadcast.isFreeHit.
  bool isFreeHit = false;
  // Running tally of boundaries hit THIS match - broadcast to viewers
  // alongside everything else (piggybacks the existing per-ball
  // updateLiveBroadcast call, so this adds zero extra network calls).
  int matchFours = 0;
  int matchSixes = 0;
  // "New batter/bowler" intro card for live viewers - see
  // StorageService.loadSpotlightCard. Rides along on the next regular
  // broadcast push once fetched; no dedicated push of its own.
  SpotlightCard? _pendingSpotlight;
  BroadcastGraphData? _pendingGraph;
  BroadcastOversData? _pendingOvers;
  BroadcastPlayerBattle? _pendingBattle;
  BroadcastPlayingXI? _pendingPlayingXI;
  BroadcastScorecardData? _pendingScorecard;
  // Fielding team's current bowling figures (O/M/R/W/Econ per bowler) -
  // see _broadcastBowlingFigures. Same one-off timed-push pattern as
  // _pendingScorecard above.
  BroadcastBowlingData? _pendingBowling;
  // Which stat shows on the strip below the two batsmen on viewers'
  // screens - stays selected (unlike the pending pushes above, which are
  // one-off) until the scorer taps a different button on the PLAYERS tab.
  String _statLineMode = 'crr';
  // Free text for the "custom" stat line mode - typed into _statLineTextCtrl
  // on the PLAYERS tab. Unlike CRR/RRR/Need (which only take effect on the
  // next ball, piggybacking the normal push), this pushes live update on
  // every keystroke (see onChanged below) so viewers see it appear as the
  // scorer types, not after the next delivery.
  String _statLineCustomText = '';
  final TextEditingController _statLineTextCtrl = TextEditingController();
  // Full-state snapshots taken right before each delivery. Undo restores the
  // *entire* snapshot (including player identities), so a wicket or over-change
  // followed immediately by Undo can never leave stats attached to the wrong
  // player - this replaces the old per-field patch approach which could corrupt
  // data when a new batsman/bowler had already been chosen after the ball.
  List<BallSnapshot> undoStack = [];

  // Squads
  List<Player> squadBatting = [];
  List<Player> squadBowling = [];

  List<Batsman> activeBatsmenList = [];
  List<Bowler> activeBowlersList = [];

  late Batsman striker;
  late Batsman nonStriker;
  late Bowler currentBowler;
  String? lastBowlerId;

  bool isMatchOver = false;
  bool isInningsBreak = false;
  String matchStatus = "";
  String? winnerTeamName;

  // If this match was resumed from an "Incomplete" History entry, this is
  // that entry's id - so finishing (or exiting incomplete again) updates
  // that same row instead of creating a duplicate. Null for a brand-new
  // match, or one resumed only from the plain crash-recovery draft.
  String? _originResultId;

  // Watch Live - null means not currently broadcasting.
  String? _broadcastId;
  String? _liveVideoUrl;

  // Momentary "FOUR"/"SIX"/"OUT" celebration banner shown over the scoring
  // tab (see _buildCelebrationOverlay/_triggerCelebration below) - purely
  // decorative polish, has no effect on scoring. _celebrationKey forces the
  // pop-in animation to replay even when the SAME event fires twice in a
  // row (e.g. two sixes back to back), since a TweenAnimationBuilder only
  // re-animates when its key actually changes.
  String? _celebrationEvent;
  int _celebrationKey = 0;
  Timer? _celebrationTimer;

  void _triggerCelebration(String event) {
    _celebrationTimer?.cancel();
    setState(() {
      _celebrationEvent = event;
      _celebrationKey++;
    });
    _celebrationTimer = Timer(const Duration(milliseconds: 1100), () {
      if (!mounted) return;
      setState(() => _celebrationEvent = null);
    });
  }

  @override
  void dispose() {
    _statLineTextCtrl.dispose();
    _celebrationTimer?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    // See the superOverBroadcastId doc comment on the widget above - this
    // is what makes a Super Over broadcast live to the SAME viewers who
    // were already watching the tied main match, instead of starting
    // silent.
    _broadcastId = widget.superOverBroadcastId;

    if (widget.draft != null) {
      final d = widget.draft!;
      currentBattingTeam = d.currentBattingTeam;
      currentBowlingTeam = d.currentBowlingTeam;
      totalPlayers = d.totalPlayers;
      maxOvers = d.maxOvers;
      totalRuns = d.totalRuns;
      totalWickets = d.totalWickets;
      matchBalls = d.matchBalls;
      extras = d.extras;
      currentOverRuns = d.currentOverRuns;
      overRunsHistory = List<int>.from(d.overRunsHistory);
      currentOverWickets = d.currentOverWickets;
      overWicketsHistory = List<int>.from(d.overWicketsHistory);
      ballCumulativeRuns = List<int>.from(d.ballCumulativeRuns);
      isSecondInnings = d.isSecondInnings;
      targetScore = d.targetScore;
      firstInningsData = d.firstInningsData;
      ballHistoryDisplay = List<String>.from(d.ballHistoryDisplay);
      squadBatting = List.from(d.squadBatting);
      squadBowling = List.from(d.squadBowling);
      activeBatsmenList = d.activeBatsmenList.map((b) => b.clone()).toList();
      activeBowlersList = d.activeBowlersList.map((b) => b.clone()).toList();
      striker = d.striker.clone();
      nonStriker = d.nonStriker.clone();
      currentBowler = d.currentBowler.clone();
      lastBowlerId = d.lastBowlerId;
      isMatchOver = d.isMatchOver;
      isInningsBreak = d.isInningsBreak;
      matchStatus = d.matchStatus;
      winnerTeamName = d.winnerTeamName;
      _originResultId = d.resultId;
      isFreeHit = d.isFreeHit;
      matchFours = d.matchFours;
      matchSixes = d.matchSixes;
      deliveryLog = List<Delivery>.from(d.deliveryLog);
      _pushInitialSuperOverLiveUpdate();
      return;
    }

    currentBattingTeam = widget.teamA!;
    currentBowlingTeam = widget.teamB!;
    totalPlayers = widget.playersPerTeam!;
    maxOvers = widget.maxOvers!;

    if (widget.initialSquadA != null && widget.initialSquadB != null) {
      squadBatting = List.from(widget.initialSquadA!);
      squadBowling = List.from(widget.initialSquadB!);
    } else {
      _initSquads();
    }

    Player? sP = squadBatting.firstWhere((p) => p.name == widget.strikerName, orElse: () => Player(name: widget.strikerName!, id: "s_init"));
    Player? nsP = squadBatting.firstWhere((p) => p.name == widget.nonStrikerName, orElse: () => Player(name: widget.nonStrikerName!, id: "ns_init"));
    Player? bP = squadBowling.firstWhere((p) => p.name == widget.bowlerName, orElse: () => Player(name: widget.bowlerName!, id: "b_init"));

    striker = Batsman(name: sP.name, id: sP.id);
    nonStriker = Batsman(name: nsP.name, id: nsP.id);
    currentBowler = Bowler(name: bP.name, id: bP.id);

    activeBatsmenList.add(striker);
    activeBatsmenList.add(nonStriker);
    activeBowlersList.add(currentBowler);
    _pushInitialSuperOverLiveUpdate();
  }

  // BUG FIX (continued from the superOverBroadcastId doc comment above):
  // inheriting _broadcastId alone isn't quite enough - _pushLiveUpdate()
  // only ever fires from inside setState(), and nothing here calls
  // setState() until the first ball is scored. Without this, viewers
  // would keep seeing the stale "Match Tied!" broadcast for however long
  // it takes the Super Over's first ball to be bowled. Firing one push
  // right after the first frame (all the score fields above are set by
  // then) immediately replaces that with the Super Over's fresh 0/0
  // state and new batting/bowling team names, then every ball after
  // keeps it live the normal way.
  void _pushInitialSuperOverLiveUpdate() {
    if (_broadcastId == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pushLiveUpdate();
    });
  }


  // Every setState in this screen also (fire-and-forget) persists progress
  // to disk - so scoring survives the app process being killed outright
  // (e.g. swiped away from recent apps), not just a normal back-button exit.
  // Quick Match: a standalone crash-recovery draft (see _persistDraft).
  // Tournament: written directly onto the TournamentMatch itself (see
  // _persistTournamentProgress) - local-only on every ball (cheap, no
  // network), with a full cloud sync at each over boundary so a logged-in
  // user's cloud copy never lags by more than the current partial over.
  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    if (widget.onMatchComplete == null) {
      _persistDraft();
    } else {
      _persistTournamentProgress();
    }
    if (_broadcastId != null) _pushLiveUpdate();
  }

  // Last 6 ball outcomes (this over so far), newest first, with the
  // "over.ball - " prefix and "End of Over" markers stripped - just the
  // short outcome label for the broadcast-style chip row.
  List<String> get _recentBallLabels {
    return ballHistoryDisplay
        .where((e) => !e.startsWith("End of Over"))
        .take(6)
        .map((e) {
          final idx = e.indexOf(' - ');
          return (idx != -1 ? e.substring(idx + 3) : e).trim();
        })
        .toList();
  }

  // Looks up [name]'s career stats ONCE (no cost to viewers - this is the
  // scorer's own device making one extra query) and stashes the result to
  // ride along on the next regular broadcast push. Silently does nothing
  // if not live, not logged in, or the player has no registry/career
  // entry yet (still-default-named, or a real name that just hasn't
  // played a synced match before) - exactly the same "nothing to show"
  // cases as everywhere else in the app.
  Future<void> _fetchSpotlight(String name, {required bool isBatter}) async {
    if (_broadcastId == null) return;
    final result = await StorageService.loadSpotlightCard(name);
    if (result == null || !mounted) return;
    final stat = result.stat;
    _pendingSpotlight = SpotlightCard(
      name: result.player.name,
      photoUrl: result.player.photoUrl,
      isBatter: isBatter,
      matches: stat.matches,
      primaryValue: isBatter ? stat.runs : stat.wickets,
      average: isBatter ? (stat.avg < 0 ? null : stat.avg) : (stat.wickets > 0 ? stat.bowlAvg : null),
      secondaryRate: isBatter ? stat.sr : (stat.oversBowled > 0 ? stat.econ : null),
      tertiaryLabel: isBatter ? 'Highest Score' : 'Best Bowling',
      tertiaryValue: isBatter ? '${stat.highestScore}' : (stat.wickets > 0 ? stat.bestBowling : '-'),
      at: DateTime.now(),
    );
    if (_broadcastId != null) _pushLiveUpdate();
  }

  void _pushLiveUpdate() {
    // If a comparison graph is currently the live card, refresh its
    // ball-by-ball arrays against the CURRENT match state before sending -
    // same [at] though, so the viewer treats this as an update to the
    // card already on screen rather than a brand new one (no restarted
    // entrance animation / auto-hide timer). This is what makes the worm
    // actually move ball-by-ball instead of freezing at whatever it
    // looked like when "Compare" was tapped.
    if (_pendingGraph != null) {
      _pendingGraph = _buildComparisonGraphData(at: _pendingGraph!.at);
    }
    // Same idea as the comparison graph above: if the Runs/Over card is
    // currently the live card, refresh its bars against the CURRENT match
    // state before sending - same [at] though, so this reads as an update
    // to the card already on screen rather than a new one. Without this,
    // the bars stayed frozen at whatever they were when "Runs/Over" was
    // tapped while the header score pill (pulled live from this same
    // broadcast) kept moving - showing one score in the header and a
    // different, stale score reflected in the bars.
    if (_pendingOvers != null) {
      _pendingOvers = _buildRunsPerOverData(at: _pendingOvers!.at);
    }
    StorageService.updateLiveBroadcast(LiveBroadcast(
      id: _broadcastId!,
      teamA: currentBattingTeam,
      teamB: currentBowlingTeam,
      totalRuns: totalRuns,
      totalWickets: totalWickets,
      matchBalls: matchBalls,
      maxOvers: maxOvers,
      isSecondInnings: isSecondInnings,
      targetScore: targetScore,
      striker: striker.name,
      strikerRuns: striker.runs,
      strikerBalls: striker.balls,
      strikerFours: striker.fours,
      strikerSixes: striker.sixes,
      nonStriker: nonStriker.name,
      nonStrikerRuns: nonStriker.runs,
      nonStrikerBalls: nonStriker.balls,
      bowler: currentBowler.name,
      bowlerWickets: currentBowler.wickets,
      bowlerRuns: currentBowler.runs,
      bowlerOvers: currentBowler.oversDisplay,
      extras: extras,
      currentOverRuns: currentOverRuns,
      recentBalls: _recentBallLabels,
      isMatchOver: isMatchOver,
      matchStatus: matchStatus,
      videoUrl: _liveVideoUrl,
      updatedAt: DateTime.now(),
      isFreeHit: isFreeHit,
      matchFours: matchFours,
      matchSixes: matchSixes,
      tournamentId: widget.tournamentId,
      spotlight: _pendingSpotlight,
      graph: _pendingGraph,
      overs: _pendingOvers,
      playerBattle: _pendingBattle,
      playingXI: _pendingPlayingXI,
      scorecard: _pendingScorecard,
      bowling: _pendingBowling,
      statLineMode: _statLineMode,
      statLineCustomText: _statLineCustomText.trim().isEmpty ? null : _statLineCustomText,
    ));
  }

  void _persistTournamentProgress() {
    if (widget.onProgressUpdate == null || !_hasAnyProgress) return;
    final result = _buildIncompleteResult();
    final isOverBoundary = matchBalls > 0 && matchBalls % 6 == 0;
    widget.onProgressUpdate!(result, isOverBoundary);
  }

  void _persistDraft() {
    final draft = MatchDraft(
      maxOvers: maxOvers,
      totalPlayers: totalPlayers,
      currentBattingTeam: currentBattingTeam,
      currentBowlingTeam: currentBowlingTeam,
      totalRuns: totalRuns,
      totalWickets: totalWickets,
      matchBalls: matchBalls,
      extras: extras,
      currentOverRuns: currentOverRuns,
      overRunsHistory: overRunsHistory,
      currentOverWickets: currentOverWickets,
      overWicketsHistory: overWicketsHistory,
      ballCumulativeRuns: ballCumulativeRuns,
      isSecondInnings: isSecondInnings,
      targetScore: targetScore,
      firstInningsData: firstInningsData,
      ballHistoryDisplay: ballHistoryDisplay,
      squadBatting: squadBatting,
      squadBowling: squadBowling,
      activeBatsmenList: activeBatsmenList,
      activeBowlersList: activeBowlersList,
      striker: striker,
      nonStriker: nonStriker,
      currentBowler: currentBowler,
      lastBowlerId: lastBowlerId,
      isMatchOver: isMatchOver,
      isInningsBreak: isInningsBreak,
      matchStatus: matchStatus,
      winnerTeamName: winnerTeamName,
      savedAt: DateTime.now(),
      resultId: _originResultId,
      isFreeHit: isFreeHit,
      matchFours: matchFours,
      matchSixes: matchSixes,
      deliveryLog: deliveryLog,
    );
    // Fire-and-forget: scoring must never wait on disk I/O.
    StorageService.saveMatchDraft(draft);
  }

  void _initSquads() {
    squadBatting = List.generate(totalPlayers, (index) => Player(name: "Bat-Player ${index + 1}", id: "bat_$index"));
    squadBowling = List.generate(totalPlayers, (index) => Player(name: "Bowl-Player ${index + 1}", id: "bowl_$index"));
  }

  void _addNewPlayerToSquads() {
    setState(() {
      totalPlayers++;
      squadBatting.add(Player(name: "Bat-Player $totalPlayers", id: "bat_${totalPlayers - 1}"));
      squadBowling.add(Player(name: "Bowl-Player $totalPlayers", id: "bowl_${totalPlayers - 1}"));
    });
  }

  // Launches a Super Over when the match ends tied: a real 1-over-per-side
  // mini match, using the SAME MatchScorerScreen as the main match (not a
  // separate simplified scorer) - so it gets every scoring option (WD/NB
  // with extra runs, byes, leg byes, undo) for free and can never fall
  // behind if those rules change. playersPerTeam is capped at 3 (or fewer if
  // the squad doesn't have 3), which makes the built-in wicket limit exactly
  // 2 - the standard Super Over convention (out after 1 over or 2 wickets).
  // Doesn't touch this screen's own totalRuns/activeBatsmenList/etc - only
  // winnerTeamName/matchStatus get updated on a decisive result, so the
  // real (tied) scorecard is preserved exactly as it happened.
  Future<void> _offerSuperOver() async {
    // Real convention: the team that batted second (chased) in the main
    // match bats first in the Super Over.
    final battingSquad = squadBatting.length > 3 ? squadBatting.sublist(0, 3) : List<Player>.from(squadBatting);
    final bowlingSquad = squadBowling.length > 3 ? squadBowling.sublist(0, 3) : List<Player>.from(squadBowling);
    if (battingSquad.length < 2 || bowlingSquad.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('not_enough_players_super_over'))));
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MatchScorerScreen(
          teamA: currentBattingTeam,
          teamB: currentBowlingTeam,
          maxOvers: 1,
          playersPerTeam: battingSquad.length,
          strikerName: battingSquad[0].name,
          nonStrikerName: battingSquad.length > 1 ? battingSquad[1].name : battingSquad[0].name,
          bowlerName: bowlingSquad[0].name,
          initialSquadA: battingSquad,
          initialSquadB: bowlingSquad,
          onMatchComplete: _handleSuperOverResult,
          suppressSavedSnackbar: true,
          // BUG FIX: without this, live viewers watching the tied match
          // never saw the Super Over's score - see the doc comment on
          // superOverBroadcastId above. Only actually broadcasts if the
          // outer match itself is currently live (_broadcastId != null);
          // otherwise this is null too and the Super Over stays offline,
          // same as before.
          superOverBroadcastId: _broadcastId,
        ),
      ),
    );
  }

  void _handleSuperOverResult(MatchResultData result) async {
    // Backed out of the Super Over itself (its own "Exit Anyway") instead of
    // finishing it - leave the original match's Tie exactly as it was;
    // there's no real Super Over result to apply.
    if (!result.isComplete) return;

    if (result.winner == "Tie") {
      if (!mounted) return;
      final playAgain = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(tr('still_tied_title')),
          content: Text(tr('still_tied_body')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('accept_tie').toUpperCase())),
            ElevatedButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('play_again').toUpperCase())),
          ],
        ),
      );
      if (playAgain == true) _offerSuperOver();
      return;
    }
    if (!mounted) return;
    setState(() {
      winnerTeamName = result.winner;
      matchStatus = "${result.winner} won the match in a Super Over!";
    });
  }

  // Lets the person pick Man of the Match from everyone who batted or
  // bowled in this match, right as it's being finished. "SKIP" leaves it
  // unset rather than forcing a choice.
  Future<String?> _pickManOfTheMatch(List<Batsman> allBats, List<Bowler> allBowls) async {
    final Map<String, String> uniquePlayers = {};
    for (var b in allBats) uniquePlayers[b.id] = b.name;
    for (var b in allBowls) uniquePlayers[b.id] = b.name;
    final names = uniquePlayers.values.toList();
    if (names.isEmpty) return null;

    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(tr('man_of_match_dialog_title')),
        content: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(context).size.height * 0.4,
          child: ListView.builder(
            itemCount: names.length,
            itemBuilder: (context, index) => ListTile(
              leading: const Icon(Icons.star_outline, color: Colors.amber),
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
  }

  void _finishMatchAndSave() async {
    // BUG FIX: this used to unconditionally end the broadcast whenever
    // THIS screen's own match finished. For a nested Super Over that's
    // sharing the outer match's live broadcast (see superOverBroadcastId
    // above), that meant the broadcast - and with it, the live viewers'
    // connection - got killed the instant the Super Over itself ended,
    // before the outer screen ever got a chance to push the real final
    // result ("X won in a Super Over!"). Only the top-level match (the
    // one that isn't just borrowing someone else's broadcast id) should
    // ever end it here.
    if (_broadcastId != null && widget.superOverBroadcastId == null) {
      StorageService.endLiveBroadcast(_broadcastId!);
    }
    String winner = winnerTeamName ?? "Tie";
    String margin = matchStatus;

    List<Batsman> allBats = [];
    List<Bowler> allBowls = [];

    if (firstInningsData != null) {
      allBats.addAll(firstInningsData!.batsmen);
      allBowls.addAll(firstInningsData!.bowlers);
    }
    allBats.addAll(activeBatsmenList);
    allBowls.addAll(activeBowlersList);

    InningsHistory innings2Data = InningsHistory(
      teamName: currentBattingTeam,
      totalRuns: totalRuns,
      totalWickets: totalWickets,
      overs: "${matchBalls ~/ 6}.${matchBalls % 6}",
      batsmen: List.from(activeBatsmenList),
      bowlers: List.from(activeBowlersList),
      squad: squadBatting,
      extras: extras,
      commentary: List<String>.from(ballHistoryDisplay),
    );

    final motm = widget.suppressSavedSnackbar ? null : await _pickManOfTheMatch(allBats, allBowls);
    if (!mounted) return;

    MatchResultData result = MatchResultData(
      id: _originResultId,
      winner: winner,
      margin: margin,
      allBatsmen: allBats,
      allBowlers: allBowls,
      innings1: firstInningsData,
      innings2: innings2Data,
      teamName1: firstInningsData?.teamName ?? "",
      teamName2: currentBattingTeam,
      innings1Score: firstInningsData != null ? "${firstInningsData!.totalRuns}/${firstInningsData!.totalWickets}" : "",
      innings2Score: "$totalRuns/$totalWickets",
      fullSquad: [],
      playedAt: DateTime.now(),
      isComplete: true,
      manOfTheMatch: motm,
      deliveries: deliveryLog,
    );

    // Remember each team's XI from this match as their "usual squad" for
    // next time (see StorageService.saveTeamRoster). Awaited here - the
    // method now saves locally first before ever touching the network
    // (see its doc comment), so this adds negligible delay, and awaiting
    // it guarantees the roster is actually on disk before this screen
    // can be popped/exited - closing the exact race that could otherwise
    // lose the roster if the app was closed right after finishing a match.
    if (firstInningsData != null) {
      await StorageService.saveTeamRoster(firstInningsData!.teamName, firstInningsData!.squad);
    }
    await StorageService.saveTeamRoster(currentBattingTeam, squadBatting);

    if (widget.onMatchComplete != null) {
      // Tournament mode: the dashboard owns saving this into the tournament's
      // stats/points table (and persisting the tournament to disk).
      if (!widget.suppressSavedSnackbar) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(children: [const Icon(Icons.check_circle, color: Colors.white), const SizedBox(width: 10), Text(tr('match_saved_success'))]),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 1),
          ),
        );
        await Future.delayed(const Duration(seconds: 1));
      }
      if (mounted) Navigator.pop(context);
      widget.onMatchComplete!(result);
    } else {
      // Quick Match: always saved locally first. Reaching the cloud is a
      // deliberate, separate step from Match History ("Save to Cloud" /
      // "Sync All") - never automatic for quick matches.
      await StorageService.addQuickMatchToHistory(result);
      await StorageService.clearMatchDraft();
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => MatchResultScreen(data: result, isFreshResult: true)),
      );
    }
  }

  /// True once at least one ball has actually been recorded (this innings or
  /// a completed first innings) - used to avoid saving a blank "match" to
  /// history if the person backs out before scoring anything.
  bool get _hasAnyProgress => firstInningsData != null || matchBalls > 0 || totalWickets > 0;

  /// Builds an (isComplete: false) snapshot of the match as it stands right
  /// now - full scorecard-so-far plus an embedded resumable MatchDraft.
  /// Shared by the confirmed "EXIT ANYWAY" save and the frequent tournament
  /// autosave, so there's exactly one place that knows how to represent
  /// "the match, mid-way through".
  MatchResultData _buildIncompleteResult() {
    List<Batsman> allBats = [];
    List<Bowler> allBowls = [];
    if (firstInningsData != null) {
      allBats.addAll(firstInningsData!.batsmen);
      allBowls.addAll(firstInningsData!.bowlers);
    }
    allBats.addAll(activeBatsmenList);
    allBowls.addAll(activeBowlersList);

    InningsHistory? currentInningsData;
    // Only include the innings actually in progress here if any legal ball
    // (or wicket) has happened in it - an untouched 2nd innings shouldn't
    // overwrite/duplicate what's already stored in firstInningsData.
    if (matchBalls > 0 || totalWickets > 0 || totalRuns > 0) {
      currentInningsData = InningsHistory(
        teamName: currentBattingTeam,
        totalRuns: totalRuns,
        totalWickets: totalWickets,
        overs: "${matchBalls ~/ 6}.${matchBalls % 6}",
        batsmen: List.from(activeBatsmenList),
        bowlers: List.from(activeBowlersList),
        squad: squadBatting,
        extras: extras,
        commentary: List<String>.from(ballHistoryDisplay),
      );
    }

    // Reuse the id from a previous incomplete save (if this match was
    // already resumed once, or already autosaved earlier this session) so
    // every further save replaces that same row instead of creating a new
    // one; otherwise mint a fresh id now and remember it for the rest of
    // this screen's lifetime.
    _originResultId ??= '${DateTime.now().microsecondsSinceEpoch}';
    final resultId = _originResultId!;
    final embeddedDraft = MatchDraft(
      maxOvers: maxOvers,
      totalPlayers: totalPlayers,
      currentBattingTeam: currentBattingTeam,
      currentBowlingTeam: currentBowlingTeam,
      totalRuns: totalRuns,
      totalWickets: totalWickets,
      matchBalls: matchBalls,
      extras: extras,
      currentOverRuns: currentOverRuns,
      overRunsHistory: overRunsHistory,
      currentOverWickets: currentOverWickets,
      overWicketsHistory: overWicketsHistory,
      ballCumulativeRuns: ballCumulativeRuns,
      isSecondInnings: isSecondInnings,
      targetScore: targetScore,
      firstInningsData: firstInningsData,
      ballHistoryDisplay: ballHistoryDisplay,
      squadBatting: squadBatting,
      squadBowling: squadBowling,
      activeBatsmenList: activeBatsmenList,
      activeBowlersList: activeBowlersList,
      striker: striker,
      nonStriker: nonStriker,
      currentBowler: currentBowler,
      lastBowlerId: lastBowlerId,
      isMatchOver: isMatchOver,
      isInningsBreak: isInningsBreak,
      matchStatus: matchStatus,
      winnerTeamName: winnerTeamName,
      savedAt: DateTime.now(),
      resultId: resultId,
      isFreeHit: isFreeHit,
      matchFours: matchFours,
      matchSixes: matchSixes,
      deliveryLog: deliveryLog,
    );

    return MatchResultData(
      id: resultId,
      winner: "",
      margin: "Match exited early - incomplete",
      allBatsmen: allBats,
      allBowlers: allBowls,
      innings1: isSecondInnings ? firstInningsData : (currentInningsData ?? firstInningsData),
      innings2: isSecondInnings ? currentInningsData : null,
      teamName1: isSecondInnings ? (firstInningsData?.teamName ?? "") : currentBattingTeam,
      teamName2: isSecondInnings ? currentBattingTeam : currentBowlingTeam,
      innings1Score: isSecondInnings
          ? (firstInningsData != null ? "${firstInningsData!.totalRuns}/${firstInningsData!.totalWickets}" : "")
          : "$totalRuns/$totalWickets",
      innings2Score: isSecondInnings ? "$totalRuns/$totalWickets" : "",
      fullSquad: [],
      playedAt: DateTime.now(),
      isComplete: false,
      draft: embeddedDraft,
    );
  }

  /// Called instead of silently discarding the match when the person taps
  /// "EXIT ANYWAY" on the exit-confirmation dialog. Routes the current
  /// partial result back through onMatchComplete (tournament mode) or into
  /// local Match History (quick match) as an incomplete match - instead of
  /// losing the scoring that's already been entered.
  Future<void> _saveIncompleteMatchAndExit() async {
    // Same reasoning as the fix in _finishMatchAndSave() above: backing
    // out of a nested Super Over early must NOT end the outer match's
    // shared live broadcast - only the top-level match should ever do
    // that (see superOverBroadcastId).
    if (_broadcastId != null && widget.superOverBroadcastId == null) {
      await StorageService.endLiveBroadcast(_broadcastId!);
    }
    // BUG FIX: this used to only remember each team's XI (saveTeamRoster)
    // when a match finished normally via _finishMatchAndSave. Exiting
    // early via "Exit Anyway" skipped it entirely, so a match that was
    // scored partway through and then exited never got its player names
    // remembered - the next match with the same team name silently fell
    // back to default "A-Player 1" placeholders instead of offering back
    // the XI that had just been used. Saving here too (unconditionally,
    // even if _hasAnyProgress is false - the squad may have already been
    // customized in Start Match / Manage Squad before a single ball was
    // bowled) closes that gap. Awaited for the same reason as in
    // _finishMatchAndSave: saveTeamRoster now saves locally first (fast,
    // no network dependency), so awaiting it guarantees the roster is
    // actually on disk before this screen can be popped/exited.
    if (firstInningsData != null) {
      await StorageService.saveTeamRoster(firstInningsData!.teamName, firstInningsData!.squad);
    }
    await StorageService.saveTeamRoster(currentBattingTeam, squadBatting);
    if (_hasAnyProgress) {
      final result = _buildIncompleteResult();

      if (widget.onMatchComplete != null) {
        // Tournament mode: hand the incomplete result back to the dashboard,
        // which stores it on the TournamentMatch itself (not Match History)
        // and does NOT touch points/stats until the match is truly finished.
        widget.onMatchComplete!(result);
      } else {
        await StorageService.addQuickMatchToHistory(result);
        await StorageService.clearMatchDraft();
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _showSquadManagementDialog() {
    TextEditingController battingTeamCtrl = TextEditingController(text: currentBattingTeam);
    TextEditingController bowlingTeamCtrl = TextEditingController(text: currentBowlingTeam);
    TextEditingController oversCtrl = TextEditingController(text: "$maxOvers");
    TextEditingController playersCtrl = TextEditingController(text: "$totalPlayers");

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) {
          return AlertDialog(
            title: Text(tr('match_settings_squads_title')),
            content: SizedBox(
              width: double.maxFinite,
              // Was a hard-coded 480 - fine until the keyboard opened (e.g.
              // typing into a team-name field on the Match Settings tab),
              // at which point the dialog had no room to shrink and
              // overflowed. Now it shrinks with the keyboard instead of
              // fighting it, capped at the original 480 when there's no
              // keyboard to worry about.
              height: (MediaQuery.of(context).size.height * 0.6 - MediaQuery.of(context).viewInsets.bottom).clamp(200.0, 480.0),
              child: DefaultTabController(
                length: 3,
                child: Column(
                  children: [
                    TabBar(
                      labelColor: Theme.of(context).primaryColor,
                      unselectedLabelColor: Colors.grey,
                      isScrollable: true,
                      tabs: const [Tab(text: "Match Settings"), Tab(text: "Batting Team"), Tab(text: "Bowling Team")],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          _buildMatchSettingsTab(battingTeamCtrl, bowlingTeamCtrl, oversCtrl, playersCtrl, setStateDialog),
                          _buildSquadList(squadBatting, setStateDialog),
                          _buildSquadList(squadBowling, setStateDialog),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('close').toUpperCase()))],
          );
        },
      ),
    );
  }

  Widget _buildMatchSettingsTab(TextEditingController battingCtrl, TextEditingController bowlingCtrl, TextEditingController oversCtrl, TextEditingController playersCtrl, StateSetter setStateDialog) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('match_settings_hint'), style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 16),
          TextField(controller: battingCtrl, decoration: InputDecoration(labelText: tr('currently_batting_team_label'))),
          const SizedBox(height: 12),
          TextField(controller: bowlingCtrl, decoration: InputDecoration(labelText: tr('currently_bowling_team_label'))),
          const SizedBox(height: 12),
          TextField(controller: oversCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: tr('total_overs_label'))),
          const SizedBox(height: 12),
          TextField(controller: playersCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: tr('players_per_team_label'))),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: () {
              int? newOvers = int.tryParse(oversCtrl.text);
              int? newPlayers = int.tryParse(playersCtrl.text);
              if (battingCtrl.text.trim().isEmpty || bowlingCtrl.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('team_names_empty_error'))));
                return;
              }
              if (newOvers == null || newOvers <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('invalid_overs_error'))));
                return;
              }
              if (newPlayers == null || newPlayers <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('invalid_players_error'))));
                return;
              }
              if (newOvers < (matchBalls / 6).ceil()) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('overs_less_than_bowled_error').replaceFirst('%s', '${(matchBalls / 6).ceil()}'))));
                return;
              }
              setState(() {
                currentBattingTeam = battingCtrl.text.trim();
                currentBowlingTeam = bowlingCtrl.text.trim();
                maxOvers = newOvers;
                if (newPlayers != totalPlayers) {
                  _resizeSquad(squadBatting, newPlayers, "bat");
                  _resizeSquad(squadBowling, newPlayers, "bowl");
                  totalPlayers = newPlayers;
                }
                _checkMatchStatus();
              });
              setStateDialog(() {});
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('match_settings_updated')), backgroundColor: Colors.green));
            },
            icon: const Icon(Icons.save),
            label: Text(tr('save_settings')),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00695C), foregroundColor: Colors.white),
          ),
        ],
      ),
    );
  }

  // Grows or shrinks a squad to [newCount] players. Players who are already
  // batting/bowling in the current innings are never removed, even if the
  // new count is smaller than their position, so shrinking never corrupts
  // an innings already in progress. [prefix] ("bat"/"bowl") keeps default
  // names distinguishable between the two squads.
  void _resizeSquad(List<Player> squad, int newCount, String prefix) {
    if (squad.length < newCount) {
      for (int i = squad.length; i < newCount; i++) {
        squad.add(Player(name: "${prefix == 'bat' ? 'Bat' : 'Bowl'}-Player ${i + 1}", id: "${prefix}_extra_${DateTime.now().millisecondsSinceEpoch}_$i"));
      }
    } else if (squad.length > newCount) {
      for (int i = squad.length - 1; i >= newCount; i--) {
        bool inUse = activeBatsmenList.any((b) => b.id == squad[i].id) || activeBowlersList.any((b) => b.id == squad[i].id);
        if (!inUse) squad.removeAt(i);
      }
    }
  }

  Widget _buildSquadList(List<Player> squad, StateSetter setStateDialog) {
    return ListView.builder(
      itemCount: squad.length,
      itemBuilder: (context, index) {
        final player = squad[index];
        return ListTile(
          dense: true,
          title: Text("${index + 1}. ${player.name}"),
          trailing: IconButton(
            icon: const Icon(Icons.edit, size: 18),
            onPressed: () async {
              await _editPlayerNameDialog(player);
              setStateDialog(() {});
            },
          ),
        );
      },
    );
  }

  Future<void> _editPlayerNameDialog(Player player) async {
    TextEditingController controller = TextEditingController(text: player.name);
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('edit_player_name_title')),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('cancel').toUpperCase())),
          ElevatedButton(onPressed: () {
            if (controller.text.isNotEmpty) {
              setState(() {
                player.name = controller.text;
                _updateActivePlayerName(player.id, controller.text);
              });
            }
            Navigator.pop(context);
          }, child: Text(tr('save_caps').toUpperCase())),
        ],
      ),
    );
  }

  void _updateActivePlayerName(String id, String newName) {
    for (var b in activeBatsmenList) { if (b.id == id) b.name = newName; }
    if (striker.id == id) striker.name = newName;
    if (nonStriker.id == id) nonStriker.name = newName;
    for (var b in activeBowlersList) { if (b.id == id) b.name = newName; }
    if (currentBowler.id == id) currentBowler.name = newName;
  }

  // Lets the bowler be swapped partway through an over (injury, retirement,
  // etc) - not just the usual "pick a new bowler" prompt that only happens
  // at over boundaries. The outgoing bowler keeps whatever figures they
  // already have for the balls bowled so far this over; the incoming
  // bowler's own Bowler stats object (fresh, or their existing one if
  // they've bowled earlier in the innings) just keeps accumulating from
  // here - no special-casing needed since every delivery already scores
  // against whichever object currentBowler happens to point to.
  Future<void> _changeBowlerMidOver() async {
    final available = squadBowling.where((p) => p.id != currentBowler.id).toList();
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('no_other_bowler_available'))));
      return;
    }
    final ballsThisOver = matchBalls % 6;
    Player? selected;
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) => AlertDialog(
          title: Text(tr('change_bowler_title')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("${currentBowler.name} has bowled $ballsThisOver ball${ballsThisOver == 1 ? '' : 's'} this over. Who's completing it?"),
              const SizedBox(height: 12),
              DropdownButton<Player>(
                isExpanded: true,
                hint: Text(tr('select_new_bowler_hint')),
                value: selected,
                items: available.map((p) => DropdownMenuItem(value: p, child: Text(p.name))).toList(),
                onChanged: (v) => setStateDialog(() => selected = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('cancel').toUpperCase())),
            ElevatedButton(
              onPressed: selected == null
                  ? null
                  : () {
                      final chosen = selected!;
                      setState(() {
                        Bowler newBowler = activeBowlersList.firstWhere((b) => b.id == chosen.id, orElse: () => Bowler(name: chosen.name, id: chosen.id));
                        if (!activeBowlersList.any((b) => b.id == chosen.id)) activeBowlersList.add(newBowler);
                        currentBowler = newBowler;
                      });
                      Navigator.pop(context);
                    },
              child: Text(tr('confirm_caps').toUpperCase()),
            ),
          ],
        ),
      ),
    );
  }

  // --- Watch Live ---

  String _generateBroadcastCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O/1/I - easy to read aloud
    final rand = DateTime.now().microsecondsSinceEpoch;
    return List.generate(6, (i) => chars[(rand ~/ (i + 1)) % chars.length]).join();
  }

  Future<void> _goLive() async {
    final urlCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('go_live_title')),
        content: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('go_live_desc')),
            const SizedBox(height: 12),
            TextField(
              controller: urlCtrl,
              decoration: InputDecoration(
                labelText: tr('yt_fb_link_label'),
                hintText: tr('paste_link_hint'),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('cancel').toUpperCase())),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('go_live_caps').toUpperCase())),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final code = _generateBroadcastCode();
    final videoUrl = urlCtrl.text.trim().isEmpty ? null : urlCtrl.text.trim();
    final error = await StorageService.startLiveBroadcast(LiveBroadcast(
      id: code,
      teamA: currentBattingTeam,
      teamB: currentBowlingTeam,
      totalRuns: totalRuns,
      totalWickets: totalWickets,
      matchBalls: matchBalls,
      maxOvers: maxOvers,
      isSecondInnings: isSecondInnings,
      targetScore: targetScore,
      striker: striker.name,
      strikerRuns: striker.runs,
      strikerBalls: striker.balls,
      strikerFours: striker.fours,
      strikerSixes: striker.sixes,
      nonStriker: nonStriker.name,
      nonStrikerRuns: nonStriker.runs,
      nonStrikerBalls: nonStriker.balls,
      bowler: currentBowler.name,
      bowlerWickets: currentBowler.wickets,
      bowlerRuns: currentBowler.runs,
      bowlerOvers: currentBowler.oversDisplay,
      extras: extras,
      currentOverRuns: currentOverRuns,
      recentBalls: _recentBallLabels,
      isMatchOver: isMatchOver,
      matchStatus: matchStatus,
      videoUrl: videoUrl,
      updatedAt: DateTime.now(),
      isFreeHit: isFreeHit,
      matchFours: matchFours,
      matchSixes: matchSixes,
      tournamentId: widget.tournamentId,
      spotlight: _pendingSpotlight,
      graph: _pendingGraph,
      overs: _pendingOvers,
      playerBattle: _pendingBattle,
      playingXI: _pendingPlayingXI,
      scorecard: _pendingScorecard,
      bowling: _pendingBowling,
      statLineMode: _statLineMode,
      statLineCustomText: _statLineCustomText.trim().isEmpty ? null : _statLineCustomText,
    ));

    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error), backgroundColor: Colors.red));
      return;
    }
    setState(() {
      _broadcastId = code;
      _liveVideoUrl = videoUrl;
    });
    // Nothing auto-announces here anymore - the PLAYERS tab's buttons are
    // the only way any spotlight/graph/battle card reaches viewers now.
    // Openers just don't get a card unless the scorer taps for them.
    _showLiveInfoDialog();
  }

  // Builds a plain-text score summary for the native share sheet (#5 -
  // Real-time score share). Kept deliberately simple - a one-line score
  // line, plus a chase-context line only when there's an active target -
  // since this is meant to be pasted into WhatsApp/Messenger, not read as
  // a scorecard.
  String _buildLiveScoreShareText() {
    final overs = "${matchBalls ~/ 6}.${matchBalls % 6}";
    final base = "$currentBattingTeam $totalRuns/$totalWickets ($overs/$maxOvers ov) vs $currentBowlingTeam";
    if (targetScore > 0) {
      final remaining = targetScore - totalRuns;
      final ballsLeft = (maxOvers * 6) - matchBalls;
      if (remaining > 0 && ballsLeft > 0) {
        return "$base - ${tr('need_off_balls').replaceFirst('%s', '$remaining').replaceFirst('%s', '$ballsLeft')}";
      }
    }
    return base;
  }

  // The chase-context line shown inside the shareable image card - same
  // underlying numbers as _buildLiveScoreShareText's, just phrased for a
  // standalone card rather than a one-line message.
  String? _buildLiveScoreChaseText() {
    if (targetScore <= 0) return null;
    final remaining = targetScore - totalRuns;
    final ballsLeft = (maxOvers * 6) - matchBalls;
    if (remaining <= 0 || ballsLeft <= 0) return null;
    return tr('need_off_balls').replaceFirst('%s', '$remaining').replaceFirst('%s', '$ballsLeft');
  }

  void _shareLiveScore() {
    showShareFormatSheet(context, onSelect: (format) async {
      switch (format) {
        case ShareFormat.text:
          Share.share(_buildLiveScoreShareText(), subject: tr('app_name'));
          break;
        case ShareFormat.image:
          await shareWidgetAsImage(
            context,
            card: LiveScoreShareCard(
              battingTeam: currentBattingTeam,
              bowlingTeam: currentBowlingTeam,
              runs: totalRuns,
              wickets: totalWickets,
              oversText: "${matchBalls ~/ 6}.${matchBalls % 6}",
              maxOvers: maxOvers,
              chaseText: _buildLiveScoreChaseText(),
            ),
            filename: 'live_score.png',
            text: tr('app_name'),
          );
          break;
        case ShareFormat.pdf:
          break; // not offered for a live/in-progress match - see includePdf: false below
      }
    });
  }

  void _shareLiveCode() {
    if (_broadcastId == null) return;
    // Deep link tacked on after the existing code message rather than
    // replacing it: a recipient without the app installed still gets a
    // usable code (per share_live_message's existing copy), while one
    // WITH the app installed can just tap the link (see
    // DeepLinkService.liveLink) instead of manually typing the code into
    // WatchLiveScreen.
    final message = '${tr('share_live_message').replaceFirst('%s', _broadcastId!)}\n${DeepLinkService.liveLink(_broadcastId!)}';
    Share.share(message, subject: tr('app_name'));
  }

  void _showLiveInfoDialog() {
    if (_broadcastId == null) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('youre_live_title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('share_code_desc')),
            const SizedBox(height: 12),
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(color: const Color(0xFFE0F2F1), borderRadius: BorderRadius.circular(8)),
                child: Text(_broadcastId!, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 4, color: Color(0xFF00695C))),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton.icon(
                onPressed: _shareLiveCode,
                icon: const Icon(Icons.share_outlined, size: 18),
                label: Text(tr('share_code_tooltip')),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _stopLive();
            },
            child: Text(tr('stop_live').toUpperCase(), style: const TextStyle(color: Colors.red)),
          ),
          ElevatedButton(onPressed: () => Navigator.pop(context), child: Text(tr('ok').toUpperCase())),
        ],
      ),
    );
  }

  Future<void> _stopLive() async {
    if (_broadcastId == null) return;
    await StorageService.endLiveBroadcast(_broadcastId!);
    if (!mounted) return;
    setState(() {
      _broadcastId = null;
      _liveVideoUrl = null;
    });
  }

  // --- SCORING LOGIC HANDLERS ---

  BallSnapshot _captureSnapshot() {
    return BallSnapshot(
      totalRuns: totalRuns,
      totalWickets: totalWickets,
      matchBalls: matchBalls,
      extras: extras,
      currentOverRuns: currentOverRuns,
      overRunsHistory: List<int>.from(overRunsHistory),
      currentOverWickets: currentOverWickets,
      overWicketsHistory: List<int>.from(overWicketsHistory),
      ballCumulativeRuns: List<int>.from(ballCumulativeRuns),
      lastBowlerId: lastBowlerId,
      strikerId: striker.id,
      nonStrikerId: nonStriker.id,
      currentBowlerId: currentBowler.id,
      activeBatsmenList: activeBatsmenList.map((b) => b.clone()).toList(),
      activeBowlersList: activeBowlersList.map((b) => b.clone()).toList(),
      ballHistoryDisplay: List<String>.from(ballHistoryDisplay),
      isMatchOver: isMatchOver,
      isInningsBreak: isInningsBreak,
      matchStatus: matchStatus,
      winnerTeamName: winnerTeamName,
      deliveryLogLength: deliveryLog.length,
      isFreeHit: isFreeHit,
      matchFours: matchFours,
      matchSixes: matchSixes,
    );
  }

  Future<void> _processDelivery({
    required int runsByBat,
    required int extraRuns,
    bool isWide = false,
    bool isNoBall = false,
    bool isBye = false,
    bool isLegBye = false,
    bool isWicket = false,
    String? wicketType,
    String? fielderName,
    bool isStrikerOut = true,
  }) async {
    if (isMatchOver || isInningsBreak) return;

    // Snapshot the FULL state before touching anything - this is what makes
    // Undo safe even across a wicket + new-batsman pick, or an over-change +
    // new-bowler pick.
    final snapshot = _captureSnapshot();

    setState(() {
      undoStack.add(snapshot);

      // For byes/leg-byes, extraRuns carries the number of runs run (the bat
      // was not involved at all), so the total for this delivery is just that.
      int totalDeliveryRuns = (isBye || isLegBye) ? extraRuns : (runsByBat + extraRuns);
      totalRuns += totalDeliveryRuns;
      currentOverRuns += totalDeliveryRuns;
      // One point per delivery (legal or not) - this is what makes the
      // Scoring Comparison worm chart move on every ball instead of only
      // at over boundaries.
      ballCumulativeRuns.add(totalRuns);

      // Extras bookkeeping: a wide means the batsman gets no credit at all, so
      // every run of it (the penalty AND any run taken) is an extra. A no-ball
      // only contributes its 1-run penalty to extras - runs off the bat still
      // go to the batsman. Byes/leg-byes are entirely extras.
      if (isWide) {
        extras += totalDeliveryRuns;
      } else if (isNoBall) {
        extras += extraRuns;
      } else if (isBye || isLegBye) {
        extras += totalDeliveryRuns;
      }

      bool isLegal = !isWide && !isNoBall;
      if (isLegal) { matchBalls++; currentBowler.balls++; }

      // Free hit rule: a no-ball makes the NEXT delivery a free hit. That
      // status carries through any further wides/no-balls (still no legal
      // delivery has happened yet) and only clears once a legal delivery
      // is actually bowled.
      if (isNoBall) {
        isFreeHit = true;
      } else if (isLegal) {
        isFreeHit = false;
      }

      // Byes/leg-byes never count against the bowler's conceded-runs figure.
      if (!isBye && !isLegBye) currentBowler.runs += totalDeliveryRuns;

      // A batsman faces every delivery except a wide (matches the standard
      // ESPNcricinfo-style scoring convention: no-balls DO count as balls
      // faced since the batsman had a genuine chance to hit them).
      if (!isWide) {
        striker.balls++;
        if (!isBye && !isLegBye) {
          striker.runs += runsByBat;
          if (runsByBat == 4) { striker.fours++; matchFours++; }
          if (runsByBat == 6) { striker.sixes++; matchSixes++; }
        }
      }

      String? dismissedPlayerIdForDelivery;
      bool bowlerCreditedWicketForDelivery = false;
      if (isWicket) {
        if (wicketType != "Retired Hurt") {
          totalWickets++;
          currentOverWickets++;
        }
        Batsman victim = isStrikerOut ? striker : nonStriker;
        String dismissalText;
        switch (wicketType) {
          case "Bowled":
            dismissalText = "b ${currentBowler.name}";
            break;
          case "Catch":
            dismissalText = "c $fielderName b ${currentBowler.name}";
            break;
          case "LBW":
            dismissalText = "lbw b ${currentBowler.name}";
            break;
          case "Stumped":
            dismissalText = "st $fielderName b ${currentBowler.name}";
            break;
          case "Hit Wicket":
            dismissalText = "hit wicket b ${currentBowler.name}";
            break;
          case "Run Out":
            dismissalText = "run out ($fielderName)";
            break;
          case "Obstructing the Field":
            dismissalText = "obstructing the field";
            break;
          case "Retired Hurt":
            dismissalText = "retired hurt";
            break;
          default:
            dismissalText = "b ${currentBowler.name}";
        }
        victim.dismissal = dismissalText;
        bool bowlerCredit = isLegal && (wicketType == "Bowled" || wicketType == "Catch" || wicketType == "LBW" || wicketType == "Stumped" || wicketType == "Hit Wicket");
        if (bowlerCredit) currentBowler.wickets++;
        dismissedPlayerIdForDelivery = victim.id;
        bowlerCreditedWicketForDelivery = bowlerCredit;
      }

      // Record this ball for head-to-head "Player Battle" matchup stats.
      // Always the striker who faced it (a run-out victim might be the
      // non-striker instead - see dismissedPlayerIdForDelivery).
      deliveryLog.add(Delivery(
        batsmanId: striker.id,
        batsmanName: striker.name,
        bowlerId: currentBowler.id,
        bowlerName: currentBowler.name,
        runsOffBat: (isWide || isBye || isLegBye) ? 0 : runsByBat,
        countsAsBallFaced: !isWide,
        isWicket: isWicket,
        dismissedPlayerId: dismissedPlayerIdForDelivery,
        bowlerCreditedWicket: bowlerCreditedWicketForDelivery,
      ));

      String prefix = isLegal ? "${(matchBalls ~/ 6)}.${matchBalls % 6}" : "Ex";
      String label;
      if (isWicket) {
        label = "W ";
      } else if (isWide) {
        label = "${1 + runsByBat}WD ";
      } else if (isNoBall) {
        label = "${1 + runsByBat}NB ";
      } else if (isBye) {
        label = "${extraRuns}B ";
      } else if (isLegBye) {
        label = "${extraRuns}LB ";
      } else {
        label = "$runsByBat ";
      }
      String historyText = "$prefix - $label";
      ballHistoryDisplay.insert(0, historyText);

      bool swap = ((isBye || isLegBye) ? extraRuns : runsByBat) % 2 != 0;
      bool isOverEnd = (matchBalls > 0 && matchBalls % 6 == 0 && isLegal);

      if (isOverEnd) {
        swap = !swap;
        // A maiden over is one where the bowler conceded zero runs across all
        // six legal balls (this was never actually tracked before, so "M"
        // always showed 0).
        if (currentOverRuns == 0) currentBowler.maidens++;
        overRunsHistory.add(currentOverRuns);
        currentOverRuns = 0;
        overWicketsHistory.add(currentOverWickets);
        currentOverWickets = 0;
        ballHistoryDisplay.insert(0, "End of Over ${matchBalls ~/ 6}");
        lastBowlerId = currentBowler.id;
      }

      if (swap) _swapBatsmen();

      _checkMatchStatus();
    });

    // Haptic + on-screen "FOUR"/"SIX"/"OUT" celebration - deliberately
    // outside the setState above (it doesn't touch match state, no reason
    // to bundle it into that rebuild) and skipped for extras-only
    // deliveries (a bye that happens to run 4 isn't a batting boundary).
    final isRealWicket = isWicket && wicketType != "Retired Hurt";
    final isBoundary = !isBye && !isLegBye && !isWide && !isNoBall;
    if (isRealWicket) {
      HapticFeedback.heavyImpact();
      _triggerCelebration("OUT");
    } else if (isBoundary && runsByBat == 6) {
      HapticFeedback.mediumImpact();
      _triggerCelebration("SIX");
    } else if (isBoundary && runsByBat == 4) {
      HapticFeedback.lightImpact();
      _triggerCelebration("FOUR");
    }

    if (isMatchOver || isInningsBreak) return;
    if (isWicket && activeBatsmenList.length < totalPlayers) await _showNewBatsmanDialog(isStrikerOut);
    if (matchBalls > 0 && matchBalls % 6 == 0 && !isWide && !isNoBall && (matchBalls ~/ 6) < maxOvers) await _showNewBowlerDialog();
  }

  void _handleRun(int runs) => _processDelivery(runsByBat: runs, extraRuns: 0);

  void _handleWide() {
    showModalBottomSheet(context: context, builder: (context) => Container(padding: const EdgeInsets.all(16), child: Wrap(spacing: 12, children: [
      _actionChip("Wide (1)", () => _processDelivery(runsByBat: 0, extraRuns: 1, isWide: true)),
      _actionChip("WD + 1", () => _processDelivery(runsByBat: 1, extraRuns: 1, isWide: true)),
      _actionChip("WD + 2", () => _processDelivery(runsByBat: 2, extraRuns: 1, isWide: true)),
      _actionChip("WD + 3", () => _processDelivery(runsByBat: 3, extraRuns: 1, isWide: true)),
      _actionChip("WD + 4", () => _processDelivery(runsByBat: 4, extraRuns: 1, isWide: true)),
      _actionChip("WD + 5", () => _processDelivery(runsByBat: 5, extraRuns: 1, isWide: true)),
    ])));
  }

  void _handleNoBall() {
    showModalBottomSheet(context: context, builder: (context) => Container(padding: const EdgeInsets.all(16), child: Wrap(spacing: 12, children: [
      _actionChip("NB (1)", () => _processDelivery(runsByBat: 0, extraRuns: 1, isNoBall: true)),
      _actionChip("NB + 1", () => _processDelivery(runsByBat: 1, extraRuns: 1, isNoBall: true)),
      _actionChip("NB + 2", () => _processDelivery(runsByBat: 2, extraRuns: 1, isNoBall: true)),
      _actionChip("NB + 3", () => _processDelivery(runsByBat: 3, extraRuns: 1, isNoBall: true)),
      _actionChip("NB + 4", () => _processDelivery(runsByBat: 4, extraRuns: 1, isNoBall: true)),
      _actionChip("NB + 5", () => _processDelivery(runsByBat: 5, extraRuns: 1, isNoBall: true)),
      _actionChip("NB + 6", () => _processDelivery(runsByBat: 6, extraRuns: 1, isNoBall: true)),
    ])));
  }

  void _handleBye() {
    showModalBottomSheet(context: context, builder: (context) => Container(padding: const EdgeInsets.all(16), child: Wrap(spacing: 12, children: [
      _actionChip("Bye 1", () => _processDelivery(runsByBat: 0, extraRuns: 1, isBye: true)),
      _actionChip("Bye 2", () => _processDelivery(runsByBat: 0, extraRuns: 2, isBye: true)),
      _actionChip("Bye 3", () => _processDelivery(runsByBat: 0, extraRuns: 3, isBye: true)),
      _actionChip("Bye 4", () => _processDelivery(runsByBat: 0, extraRuns: 4, isBye: true)),
    ])));
  }

  void _handleLegBye() {
    showModalBottomSheet(context: context, builder: (context) => Container(padding: const EdgeInsets.all(16), child: Wrap(spacing: 12, children: [
      _actionChip("Leg Bye 1", () => _processDelivery(runsByBat: 0, extraRuns: 1, isLegBye: true)),
      _actionChip("Leg Bye 2", () => _processDelivery(runsByBat: 0, extraRuns: 2, isLegBye: true)),
      _actionChip("Leg Bye 3", () => _processDelivery(runsByBat: 0, extraRuns: 3, isLegBye: true)),
      _actionChip("Leg Bye 4", () => _processDelivery(runsByBat: 0, extraRuns: 4, isLegBye: true)),
    ])));
  }

  void _handleWicket() {
    String selectedType = "Catch";
    TextEditingController fielderCtrl = TextEditingController();
    bool isStrikerOut = true;
    // BUG FIX (runs missing from the total/graph on a run out): a run out
    // can happen after the batsmen have already completed 1+ runs (e.g. 2
    // runs taken, dismissed going for a 3rd) - those completed runs count
    // and must be added to the team total same as any other delivery. This
    // dialog used to have no way to enter them at all, so every run out
    // silently hardcoded runsByBat to 0 - undercounting totalRuns,
    // currentOverRuns (hence the Runs/Over graph), and the bowler's
    // conceded runs by however many runs were actually completed. Only
    // relevant for Run Out (other dismissals stop the ball dead with no
    // completed run), so it only shows for that type and stays 0 for
    // everything else.
    int runOutRuns = 0;
    showDialog(context: context, builder: (context) => StatefulBuilder(builder: (context, set) => AlertDialog(
      title: Text(tr('wicket_title')),
      // Wrapped in SingleChildScrollView: the fielder-name TextField can
      // open the keyboard, and without this the dialog had no way to
      // shrink to fit the remaining space, causing a bottom overflow.
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButton<String>(value: selectedType, isExpanded: true, items: ["Catch", "Bowled", "Run Out", "LBW", "Stumped", "Hit Wicket", "Obstructing the Field", "Retired Hurt"].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(), onChanged: (v) => set(() { selectedType = v!; if (selectedType != "Run Out") runOutRuns = 0; })),
        if (selectedType == "Catch" || selectedType == "Run Out" || selectedType == "Stumped" || selectedType == "Obstructing the Field")
          TextField(controller: fielderCtrl, decoration: InputDecoration(labelText: tr('fielder_reason_label'))),
        if (selectedType == "Run Out") ...[
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerLeft, child: Text(tr('runs_before_runout'), style: const TextStyle(fontSize: 12, color: Colors.grey))),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: List.generate(4, (r) => ChoiceChip(
                label: Text("$r"),
                selected: runOutRuns == r,
                onSelected: (_) => set(() => runOutRuns = r),
              ))),
        ],
        Row(children: [
          Expanded(child: RadioListTile(title: Text(striker.name), value: true, groupValue: isStrikerOut, onChanged: (v) => set(() => isStrikerOut = true))),
          Expanded(child: RadioListTile(title: Text(nonStriker.name), value: false, groupValue: isStrikerOut, onChanged: (v) => set(() => isStrikerOut = false))),
        ])
        ]),
      ),
      actions: [
        ElevatedButton(onPressed: () { Navigator.pop(context); _processDelivery(runsByBat: selectedType == "Run Out" ? runOutRuns : 0, extraRuns: 0, isWicket: true, wicketType: selectedType, fielderName: fielderCtrl.text, isStrikerOut: isStrikerOut); }, child: Text(tr('out_caps').toUpperCase()))
      ],
    )));
  }

  void _undoLastBall() {
    if (undoStack.isEmpty) return;
    setState(() {
      final snap = undoStack.removeLast();
      totalRuns = snap.totalRuns;
      totalWickets = snap.totalWickets;
      matchBalls = snap.matchBalls;
      extras = snap.extras;
      currentOverRuns = snap.currentOverRuns;
      overRunsHistory = List<int>.from(snap.overRunsHistory);
      currentOverWickets = snap.currentOverWickets;
      overWicketsHistory = List<int>.from(snap.overWicketsHistory);
      ballCumulativeRuns = List<int>.from(snap.ballCumulativeRuns);
      lastBowlerId = snap.lastBowlerId;
      activeBatsmenList = snap.activeBatsmenList.map((b) => b.clone()).toList();
      activeBowlersList = snap.activeBowlersList.map((b) => b.clone()).toList();
      ballHistoryDisplay = List<String>.from(snap.ballHistoryDisplay);
      isMatchOver = snap.isMatchOver;
      isInningsBreak = snap.isInningsBreak;
      matchStatus = snap.matchStatus;
      winnerTeamName = snap.winnerTeamName;
      deliveryLog.length = snap.deliveryLogLength;
      isFreeHit = snap.isFreeHit;
      matchFours = snap.matchFours;
      matchSixes = snap.matchSixes;

      // Restore the exact player objects (by identity) that were on strike /
      // bowling right before this ball - this is what makes undo safe even
      // when a new batsman or bowler was picked after the ball being undone.
      striker = activeBatsmenList.firstWhere((b) => b.id == snap.strikerId, orElse: () => Batsman(name: "Unknown", id: snap.strikerId));
      nonStriker = activeBatsmenList.firstWhere((b) => b.id == snap.nonStrikerId, orElse: () => Batsman(name: "Unknown", id: snap.nonStrikerId));
      currentBowler = activeBowlersList.firstWhere((b) => b.id == snap.currentBowlerId, orElse: () => Bowler(name: "Unknown", id: snap.currentBowlerId));
    });
  }

  void _checkMatchStatus() {
    int wicketLimit = totalPlayers - 1;
    if (isSecondInnings) {
      if (totalRuns >= targetScore) {
        setState(() {
          isMatchOver = true;
          winnerTeamName = currentBattingTeam;
          matchStatus = "$currentBattingTeam Won by ${wicketLimit - totalWickets} Wickets!";
        });
      } else if (totalWickets >= wicketLimit || matchBalls ~/ 6 >= maxOvers) {
        setState(() {
          isMatchOver = true;
          if (totalRuns == targetScore - 1) {
            matchStatus = "Match Tied!";
            winnerTeamName = "Tie";
          } else {
            winnerTeamName = currentBowlingTeam;
            matchStatus = "$currentBowlingTeam Won by ${targetScore - totalRuns - 1} Runs!";
          }
        });
      }
    } else {
      if (totalWickets >= wicketLimit || matchBalls ~/ 6 >= maxOvers) {
        setState(() { isInningsBreak = true; targetScore = totalRuns + 1; matchStatus = "End of 1st Innings. Target: $targetScore"; });
      }
    }
  }

  void _swapBatsmen() { Batsman temp = striker; striker = nonStriker; nonStriker = temp; }

  Future<void> _showNewBatsmanDialog(bool isStrikerOut) async {
    List<Player> available = squadBatting.where((p) => p.id != striker.id && p.id != nonStriker.id && !activeBatsmenList.any((b) => b.id == p.id && b.dismissal != "not out")).toList();
    // Starts blank on purpose - see the matching note in
    // _showNewBowlerDialog for why a pre-filled default caused confusion.
    Player? selected;
    TextEditingController nameCtrl = TextEditingController();

    await showDialog(context: context, barrierDismissible: false, builder: (context) => StatefulBuilder(builder: (context, set) => AlertDialog(
      title: Text(tr('next_bat_title')),
      // Wrapped in SingleChildScrollView: the "Edit Name" field is
      // autofocus:true, so the keyboard opens the instant this dialog
      // appears - without a scroll wrapper the dialog had no way to
      // shrink and overflowed immediately.
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (available.isEmpty)
          Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(tr('no_more_players_squad'), style: const TextStyle(color: Colors.red)))
        else ...[
          DropdownButton<Player>(
            value: selected,
            isExpanded: true,
            hint: Text(tr('select_player_hint')),
            items: available.map((e) => DropdownMenuItem(value: e, child: Text(e.name))).toList(),
            onChanged: (v) {
              set(() {
                selected = v;
                nameCtrl.text = v!.name;
              });
            },
          ),
          TextField(controller: nameCtrl, decoration: InputDecoration(labelText: tr('edit_name')), autofocus: true),
        ],
        ]),
      ),
      actions: [
        if (available.isEmpty)
          TextButton(onPressed: () {
            setState(() {
              if (isSecondInnings) {
                isMatchOver = true;
                matchStatus = "Match ended - no more batsmen available";
              } else {
                isInningsBreak = true;
                targetScore = totalRuns + 1;
                matchStatus = "End of 1st Innings (no more batsmen). Target: $targetScore";
              }
            });
            Navigator.pop(context);
          }, child: Text(tr('end_innings_caps').toUpperCase())),
        ElevatedButton(onPressed: selected == null ? null : () {
          final newName = nameCtrl.text;
          setState(() {
            Batsman newB = Batsman(name: newName, id: selected!.id);
            activeBatsmenList.add(newB);
            if (isStrikerOut) striker = newB; else nonStriker = newB;
          });
          Navigator.pop(context);
        }, child: Text(tr('confirm_caps').toUpperCase()))
      ],
    )));
  }

  Future<void> _showNewBowlerDialog() async {
    List<Player> available = squadBowling.where((p) => p.id != lastBowlerId).toList();
    // Starts genuinely blank (no default selection, no pre-filled name) -
    // previously this pre-picked available.first and filled the name field
    // with it, which read as "still showing the last bowler's info" since
    // nothing forced an active choice before CONFIRM became enabled.
    Player? selected;
    TextEditingController nameCtrl = TextEditingController();

    await showDialog(context: context, barrierDismissible: false, builder: (context) => StatefulBuilder(builder: (context, set) => AlertDialog(
      title: Text(tr('next_bowler_title')),
      // Wrapped in SingleChildScrollView - same overflow cause as "Next
      // Bat" above: autofocus:true on "Edit Name" opens the keyboard
      // immediately, and without this the dialog couldn't shrink to fit.
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (available.isEmpty)
          Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(tr('no_eligible_bowler'), style: const TextStyle(color: Colors.red)))
        else ...[
          DropdownButton<Player>(
            value: selected,
            isExpanded: true,
            hint: Text(tr('select_bowler_hint')),
            items: available.map((e) => DropdownMenuItem(value: e, child: Text(e.name))).toList(),
            onChanged: (v) {
              set(() {
                selected = v;
                nameCtrl.text = v!.name;
              });
            },
          ),
          TextField(controller: nameCtrl, decoration: InputDecoration(labelText: tr('edit_name')), autofocus: true),
        ],
        ]),
      ),
      actions: [
        if (available.isEmpty)
          TextButton(onPressed: () {
            setState(() {
              if (isSecondInnings) {
                isMatchOver = true;
                matchStatus = "Match ended - no eligible bowler available";
              } else {
                isInningsBreak = true;
                targetScore = totalRuns + 1;
                matchStatus = "End of 1st Innings (no eligible bowler). Target: $targetScore";
              }
            });
            Navigator.pop(context);
          }, child: Text(tr('end_innings_caps').toUpperCase())),
        ElevatedButton(onPressed: selected == null ? null : () {
          final newName = nameCtrl.text;
          setState(() {
            var existing = activeBowlersList.where((b) => b.id == selected!.id);
            if (existing.isNotEmpty) {
              currentBowler = existing.first;
              currentBowler.name = newName;
            } else {
              currentBowler = Bowler(name: newName, id: selected!.id);
              activeBowlersList.add(currentBowler);
            }
          });
          Navigator.pop(context);
        }, child: Text(tr('confirm_caps').toUpperCase()))
      ],
    )));
  }

  Future<void> _startSecondInningsDialog() async {
    List<Player> openers = squadBowling;
    List<Player> bowlers = squadBatting;
    Player? s = openers[0], ns = openers.length > 1 ? openers[1] : openers[0], b = bowlers[0];

    TextEditingController sCtrl = TextEditingController(text: s.name);
    TextEditingController nsCtrl = TextEditingController(text: ns.name);
    TextEditingController bCtrl = TextEditingController(text: b.name);

    await showDialog(context: context, barrierDismissible: false, builder: (context) => StatefulBuilder(builder: (context, set) => AlertDialog(
      title: Text(tr('start_2nd_innings_title')),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(tr('target_label').replaceFirst('%s', '$targetScore')),
          DropdownButton<Player>(value: s, items: openers.map((e) => DropdownMenuItem(value: e, child: Text(e.name))).toList(), onChanged: (v) => { set(() => s = v), sCtrl.text = v!.name }),
          TextField(controller: sCtrl, decoration: InputDecoration(labelText: tr('striker_name_label'))),
          DropdownButton<Player>(value: ns, items: openers.map((e) => DropdownMenuItem(value: e, child: Text(e.name))).toList(), onChanged: (v) => { set(() => ns = v), nsCtrl.text = v!.name }),
          TextField(controller: nsCtrl, decoration: InputDecoration(labelText: tr('non_striker_name_label'))),
          DropdownButton<Player>(value: b, items: bowlers.map((e) => DropdownMenuItem(value: e, child: Text(e.name))).toList(), onChanged: (v) => { set(() => b = v), bCtrl.text = v!.name }),
          TextField(controller: bCtrl, decoration: InputDecoration(labelText: tr('bowler_name_label'))),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('cancel').toUpperCase())),
        ElevatedButton(onPressed: () {
        if (s!.id == ns!.id) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('striker_nonstriker_same_excl')))); return; }

        setState(() {
          // Fold in the current (partial) over too, in case the innings
          // ended all-out mid-over rather than at a clean over boundary -
          // otherwise the comparison graph would be missing those runs.
          final firstInningsOverRuns = List<int>.from(overRunsHistory);
          if (matchBalls % 6 != 0) firstInningsOverRuns.add(currentOverRuns);
          firstInningsData = InningsHistory(teamName: currentBattingTeam, totalRuns: totalRuns, totalWickets: totalWickets, overs: "${matchBalls ~/ 6}.${matchBalls % 6}", batsmen: List.from(activeBatsmenList), bowlers: List.from(activeBowlersList), squad: squadBatting, extras: extras, commentary: List<String>.from(ballHistoryDisplay), overRuns: firstInningsOverRuns, ballRuns: List<int>.from(ballCumulativeRuns));
          String t = currentBattingTeam; currentBattingTeam = currentBowlingTeam; currentBowlingTeam = t;
          List<Player> sq = squadBatting; squadBatting = squadBowling; squadBowling = sq;
          totalRuns = 0; totalWickets = 0; matchBalls = 0; extras = 0; currentOverRuns = 0; overRunsHistory = []; currentOverWickets = 0; overWicketsHistory = []; ballCumulativeRuns = [];
          ballHistoryDisplay.clear(); undoStack.clear(); activeBatsmenList.clear(); activeBowlersList.clear(); lastBowlerId = null;

          striker = Batsman(name: sCtrl.text, id: s!.id);
          nonStriker = Batsman(name: nsCtrl.text, id: ns!.id);
          currentBowler = Bowler(name: bCtrl.text, id: b!.id);

          activeBatsmenList = [striker, nonStriker]; activeBowlersList = [currentBowler];
          isSecondInnings = true; isInningsBreak = false; matchStatus = "";
        }); Navigator.pop(context);
      }, child: Text(tr('start_caps').toUpperCase())),
      ],
    )));
  }

  Widget _actionChip(String l, VoidCallback t) => ActionChip(label: Text(l), onPressed: () { Navigator.pop(context); t(); });

  Future<bool> _confirmExitMatch() async {
    final shouldExit = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('exit_match_title')),
        content: Text(tr('exit_match_body')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('cancel').toUpperCase())),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('exit_anyway').toUpperCase(), style: const TextStyle(color: Colors.red))),
        ],
      ),
    );
    return shouldExit ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        final shouldExit = await _confirmExitMatch();
        if (shouldExit && mounted) await _saveIncompleteMatchAndExit();
      },
      child: Scaffold(
        appBar: AppBar(title: Text("$currentBattingTeam vs $currentBowlingTeam", overflow: TextOverflow.ellipsis, maxLines: 1), backgroundColor: const Color(0xFF00695C), foregroundColor: Colors.white, actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: tr('share_score_tooltip'),
            onPressed: _shareLiveScore,
          ),
          IconButton(
            icon: Icon(_broadcastId != null ? Icons.podcasts : Icons.podcasts_outlined, color: _broadcastId != null ? Colors.redAccent : Colors.white),
            tooltip: _broadcastId != null ? "Live - tap to manage" : "Go Live",
            onPressed: _broadcastId != null ? _showLiveInfoDialog : _goLive,
          ),
          IconButton(icon: const Icon(Icons.more_vert), onPressed: _showSquadManagementDialog),
        ], bottom: TabBar(controller: _tabController, indicatorColor: Colors.white, labelColor: Colors.white, unselectedLabelColor: Colors.white70, isScrollable: true, labelPadding: const EdgeInsets.symmetric(horizontal: 18), tabs: const [Tab(text: "SCORING"), Tab(text: "SCORECARD"), Tab(text: "GRAPH"), Tab(text: "COMPARE"), Tab(text: "LIVE CONTROL"), Tab(text: "COMMENTARY")])),
        body: Stack(
          children: [
            TabBarView(controller: _tabController, children: [_buildScoringTab(), _buildScorecardTab(), _buildGraphTab(), _buildComparisonTab(), _buildPlayersTab(), _buildCommentaryTab()]),
            _buildCelebrationOverlay(),
          ],
        ),
      ),
    );
  }

  // Momentary pop-in/fade "FOUR" / "SIX" / "OUT!" banner - see
  // _triggerCelebration, called from _processDelivery. IgnorePointer keeps
  // it purely decorative so it never blocks taps on the scoring buttons
  // underneath, even mid-animation.
  Widget _buildCelebrationOverlay() {
    if (_celebrationEvent == null) return const SizedBox.shrink();
    final event = _celebrationEvent!;
    final Color color = event == "OUT" ? Colors.redAccent.shade700 : (event == "SIX" ? Colors.deepPurpleAccent : Colors.orangeAccent.shade700);
    return IgnorePointer(
      child: Center(
        child: TweenAnimationBuilder<double>(
          key: ValueKey(_celebrationKey),
          tween: Tween(begin: 0.3, end: 1.0),
          duration: const Duration(milliseconds: 320),
          curve: Curves.elasticOut,
          builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 18),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(18),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.35), blurRadius: 14, offset: const Offset(0, 6))],
            ),
            child: Text(
              event == "OUT" ? "OUT!" : event,
              style: const TextStyle(color: Colors.white, fontSize: 42, fontWeight: FontWeight.w900, letterSpacing: 3),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScoringTab() {
    return Column(
      children: [
        if (isMatchOver || isInningsBreak)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: isInningsBreak ? Colors.orangeAccent : Colors.redAccent,
            child: Column(
              children: [
                Text(
                  matchStatus,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
                if (isInningsBreak)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: ElevatedButton(
                      onPressed: _startSecondInningsDialog,
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                      child: Text(tr('start_2nd_innings_title')),
                    ),
                  )
                else if (isMatchOver)
                    Column(
                      children: [
                        if (winnerTeamName == "Tie")
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: ElevatedButton.icon(
                              onPressed: _offerSuperOver,
                              icon: const Icon(Icons.bolt),
                              label: Text(tr('play_super_over')),
                              style: ElevatedButton.styleFrom(backgroundColor: Colors.amber, foregroundColor: Colors.black),
                            ),
                          ),
                        ElevatedButton.icon(
                          onPressed: _finishMatchAndSave,
                          icon: const Icon(Icons.save),
                          label: Text(winnerTeamName == "Tie" ? tr('end_save_match_tie') : tr('end_save_match')),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                        ),
                      ],
                    )
              ],
            ),
          ),

        Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          decoration: BoxDecoration(
            color: const Color(0xFFE0F2F1),
            border: Border(bottom: BorderSide(color: Colors.teal.shade200)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(currentBattingTeam, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF004D40)), overflow: TextOverflow.ellipsis),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text("$totalRuns", style: const TextStyle(fontSize: 48, fontWeight: FontWeight.w900, color: Color(0xFF00695C))),
                      Text("/$totalWickets", style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF00695C))),
                    ],
                  ),
                  if (isSecondInnings)
                    Text("Target: $targetScore", style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.teal)),
                    child: Text("Overs: ${matchBalls ~/ 6}.${matchBalls % 6} / ${maxOvers}", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.teal)),
                  ),
                  const SizedBox(height: 4),
                  Text("CRR: ${(totalRuns / (matchBalls == 0 ? 1 : matchBalls / 6)).toStringAsFixed(2)}", style: const TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
                  if (isSecondInnings)
                      Text("Need ${targetScore - totalRuns} off ${(maxOvers * 6) - matchBalls}", style: const TextStyle(color: Colors.orange, fontSize: 12, fontWeight: FontWeight.bold)),
                ],
              ),
            ],
          ),
        ),

        Expanded(
          child: Container(
            color: Colors.grey[50],
            // This section (2 batsmen + bowler) is wrapped in a
            // SingleChildScrollView with scrolling DISABLED
            // (NeverScrollableScrollPhysics). That's on purpose: it must
            // never actually scroll on mobile (scrolling it down would
            // drag it under the fixed bottom control pad / the phone's
            // own bottom nav buttons) - but keeping the ScrollView means
            // that on a very small/cramped screen the content quietly
            // clips instead of throwing a yellow/black RenderFlex
            // overflow error. Sizes below are also kept compact so this
            // fits comfortably without clipping on virtually all phones.
            child: SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Column(
              children: [
                  _buildActiveBatsman(striker, true, (newName, newId) {
                    setState(() {
                      if (newId != null && newId != striker.id) striker.id = newId;
                      striker.name = newName;
                      _updateActivePlayerName(striker.id, newName);
                    });
                  }),
                  Center(
                    child: TextButton.icon(
                      onPressed: () => setState(() => _swapBatsmen()),
                      icon: const Icon(Icons.swap_vert, size: 15, color: Color(0xFF00695C)),
                      label: Text(tr('swap_batsmen'), style: const TextStyle(color: Color(0xFF00695C), fontWeight: FontWeight.bold, fontSize: 11)),
                      style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    ),
                  ),
                  _buildActiveBatsman(nonStriker, false, (newName, newId) {
                    setState(() {
                      if (newId != null && newId != nonStriker.id) nonStriker.id = newId;
                      nonStriker.name = newName;
                      _updateActivePlayerName(nonStriker.id, newName);
                    });
                  }),
                  const SizedBox(height: 6),

                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.1), blurRadius: 4, offset: const Offset(0, 2))],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(currentBowler.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                Text(tr('bowling_word'), style: const TextStyle(fontSize: 10, color: Colors.grey)),
                              ],
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit, size: 13, color: Colors.grey),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                              onPressed: () async {
                                await _editPlayerNameDialog(Player(name: currentBowler.name, id: currentBowler.id));
                                setState(() {});
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.swap_horiz, size: 15, color: Colors.blueGrey),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                              tooltip: tr('change_bowler_title'),
                              onPressed: _changeBowlerMidOver,
                            ),
                          ],
                        ),
                        Row(
                          children: [
                             _statItem("O", currentBowler.oversDisplay),
                             _statItem("M", "${currentBowler.maidens}"),
                             _statItem("R", "${currentBowler.runs}"),
                             _statItem("W", "${currentBowler.wickets}"),
                          ],
                        )
                      ],
                    ),
                  ),
              ],
            ),
            ),
          ),
        ),

        _buildControlPad(),
      ],
    );
  }

  Widget _buildControlPad() {
    return SafeArea(
      top: false,
      child: Container(padding: const EdgeInsets.fromLTRB(8, 6, 8, 6), color: Colors.white, child: Column(children: [
      Row(children: [_scoreBtn("0", () => _handleRun(0)), _scoreBtn("1", () => _handleRun(1)), _scoreBtn("2", () => _handleRun(2)), _scoreBtn("3", () => _handleRun(3))]),
      const SizedBox(height: 4),
      // 5 covers odd-run scenarios like a completed run plus an overthrow
      // that doesn't quite reach the boundary (e.g. 1 run + 4 overthrow
      // would be scored as the WD/NB "+4" option instead when it's off an
      // extra; this 5 is for when it happens off a normal, fair delivery).
      Row(children: [_scoreBtn("4", () => _handleRun(4), color: Colors.green), _scoreBtn("5", () => _handleRun(5)), _scoreBtn("6", () => _handleRun(6), color: Colors.green)]),
      const SizedBox(height: 4),
      Row(children: [_scoreBtn("WD", _handleWide, color: Colors.orange), _scoreBtn("NB", _handleNoBall, color: Colors.orange)]),
      const SizedBox(height: 4),
      Row(children: [_scoreBtn("BYE", _handleBye, color: Colors.blueGrey), _scoreBtn("LB", _handleLegBye, color: Colors.blueGrey)]),
      const SizedBox(height: 4),
      Row(children: [_scoreBtn("OUT", _handleWicket, color: Colors.red, flex: 2), const SizedBox(width: 8), Expanded(child: ElevatedButton(onPressed: _undoLastBall, style: ElevatedButton.styleFrom(backgroundColor: Colors.grey, padding: const EdgeInsets.symmetric(vertical: 10)), child: const Icon(Icons.undo, color: Colors.white, size: 20)))])
    ])),
    );
  }

  Widget _scoreBtn(String l, VoidCallback t, {Color? color, int flex = 1}) => Expanded(flex: flex, child: Container(margin: const EdgeInsets.symmetric(horizontal: 2), child: ElevatedButton(onPressed: t, style: ElevatedButton.styleFrom(backgroundColor: color ?? Colors.white, foregroundColor: color != null ? Colors.white : Colors.black, padding: const EdgeInsets.symmetric(vertical: 10), minimumSize: const Size(0, 0)), child: Text(l, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)))));

  Widget _buildScorecardTab() => SingleChildScrollView(child: Column(children: [
    if (firstInningsData != null) _buildFullInningsTable(firstInningsData!.teamName, "${firstInningsData!.totalRuns}/${firstInningsData!.totalWickets}", firstInningsData!.batsmen, firstInningsData!.bowlers, firstInningsData!.squad),
    _buildFullInningsTable(currentBattingTeam, "$totalRuns/$totalWickets", activeBatsmenList, activeBowlersList, squadBatting)
  ]));

  Widget _buildFullInningsTable(String team, String score, List<Batsman> bats, List<Bowler> bowls, List<Player> fullSquad) {
    List<Player> didNotBat = fullSquad.where((p) => !bats.any((b) => b.id == p.id)).toList();

    return Card(margin: const EdgeInsets.all(8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.all(8.0), child: Text("$team - $score", style: const TextStyle(fontWeight: FontWeight.bold))),
      const Divider(),
      ...bats.map((b) => ListTile(title: Text(b.name), subtitle: Text(b.dismissal), trailing: Text("${b.runs}(${b.balls})"))),
      if (didNotBat.isNotEmpty) ...[
        const Divider(),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Text(tr('yet_to_bat'), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, children: didNotBat.map((p) => Chip(label: Text(p.name, style: const TextStyle(fontSize: 10)))).toList()),
        )
      ],
      const Divider(),
      Padding(padding: const EdgeInsets.all(8.0), child: Text(tr('bowling_word'), style: const TextStyle(fontWeight: FontWeight.bold))),
      ...bowls.map((b) => ListTile(title: Text(b.name), trailing: Text("${b.wickets}/${b.runs} (${b.oversDisplay})")))
    ]));
  }

  // Live bar chart of runs per over for the innings currently batting -
  // completed overs from overRunsHistory, plus the in-progress over (if any
  // balls have been bowled in it) from currentOverRuns, so it updates as
  // the match is scored rather than only after each over finishes.
  //
  // BUG FIX (no reference scale): this used to have no axis/gridlines at
  // all - each bar's height was only ever relative to whichever over
  // happened to be the highest-scoring one so far (bars[i]/maxRuns), with
  // no run-value grid (rows) or over-position grid (columns) behind it to
  // actually read values off of. Added a fixed run-value axis on the left
  // (rows, via horizontal gridlines) that stays in place while only the
  // bars scroll, same approach the broadcast Runs/Over card already uses
  // for viewers.
  //
  // BUG FIX (axis/gridlines floating away from the bars): the first pass
  // at the fix above put the axis+gridlines in a plain fixed-height
  // SizedBox (maxBarHeight) but left the bars sitting in an Expanded that
  // stretched to fill the whole remaining tab height - so the axis stayed
  // pinned near the top while the bars (still bottom-aligned within that
  // much taller space) ended up rendered far below it, nowhere near their
  // own gridlines. The run-number label above each bar was also part of
  // that mismatch: it added height ABOVE the bar box that the axis side
  // never accounted for. Fix: axis+gridlines and the bar area now both sit
  // inside one and the same fixed-height block (chartBlockHeight below,
  // built from the exact same run-label/gap/bar-box/gap/over-label pieces
  // on both sides), so there's no flexible space left for either side to
  // drift away from the other.
  Widget _buildGraphTab() {
    final bars = List<int>.from(overRunsHistory);
    final wicketBars = List<int>.from(overWicketsHistory);
    final ballsThisOver = matchBalls % 6;
    final hasPartialOver = ballsThisOver > 0;
    if (hasPartialOver) {
      bars.add(currentOverRuns);
      wicketBars.add(currentOverWickets);
    }

    if (bars.isEmpty) {
      return Center(child: Text(tr('no_overs_bowled_yet'), style: const TextStyle(color: Colors.grey)));
    }

    final maxRuns = bars.reduce((a, b) => a > b ? a : b).clamp(1, 999);
    // Nice round axis ceiling (steps of 5) with headroom above the tallest
    // bar - this is the scale the horizontal gridlines (rows) are drawn
    // against, so bar heights are now proportional to a real run value
    // instead of just to each other.
    final axisMax = (((maxRuns * 1.3) / 5).ceil() * 5).clamp(5, 100000);
    // BUG FIX (bar height didn't match its own printed number/gridlines):
    // this used to scale bar height against `barFillHeight` (78% of
    // maxBarHeight, to leave headroom for wicket dots) while the gridlines
    // beside it were laid out across the FULL maxBarHeight - two different
    // scales sharing one axis. A bar for "8 runs" was drawn at 78% of where
    // the "8" gridline actually sits, so it visually read as ~6 even
    // though the number above it correctly said 8. axisMax already adds
    // 30% headroom above the tallest bar (see below), which is plenty of
    // room for wicket dots on its own - so the bar now scales against the
    // same maxBarHeight the gridlines use, and they line up correctly.
    const maxBarHeight = 160.0;
    const dotSize = 13.0;
    const dotGap = 3.0;
    const axisWidth = 28.0;
    // The exact vertical space each piece around a bar takes up - used on
    // BOTH the axis side and the bar side so the two stay locked together
    // instead of drifting apart like before.
    const runLabelHeight = 20.0;
    const runLabelGap = 4.0;
    const overLabelGap = 6.0;
    const overLabelHeight = 18.0;
    const chartBlockHeight = runLabelHeight + runLabelGap + maxBarHeight + overLabelGap + overLabelHeight;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("$currentBattingTeam - Runs per Over", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 20),
          SizedBox(
            height: chartBlockHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // FIXED RUN AXIS (rows) - doesn't scroll with the bars, so
                // it always lines up with its own gridline no matter how
                // far the bars beneath have been scrolled. Offset by the
                // same run-label height/gap the bar column reserves above
                // its bar box, so the axis's own maxBarHeight zone lines
                // up with the bars' maxBarHeight zone exactly.
                SizedBox(
                  width: axisWidth,
                  height: chartBlockHeight,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const SizedBox(height: runLabelHeight + runLabelGap),
                      SizedBox(
                        height: maxBarHeight,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: List.generate(5, (i) {
                            final value = (axisMax * (4 - i) / 4).round();
                            return Text("$value", style: const TextStyle(fontSize: 10, color: Colors.grey));
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: SizedBox(
                    height: chartBlockHeight,
                    child: Stack(
                      children: [
                        // Gridlines (rows) - fixed background layer behind
                        // the scrollable bars, offset down by the same
                        // run-label height/gap as the axis above so it
                        // lines up with both the axis numbers AND the
                        // bars' own maxBarHeight zone.
                        Positioned(
                          top: runLabelHeight + runLabelGap,
                          left: 0,
                          right: 0,
                          height: maxBarHeight,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: List.generate(5, (_) => Container(height: 1, color: Colors.grey.withOpacity(0.25))),
                          ),
                        ),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          reverse: true,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: List.generate(bars.length, (i) {
                              final isCurrent = hasPartialOver && i == bars.length - 1;
                              final runs = bars[i];
                              final wkts = i < wicketBars.length ? wicketBars[i] : 0;
                              final barHeight = (maxBarHeight * runs / axisMax).clamp(4.0, maxBarHeight);
                              final barColor = isCurrent ? Colors.orange : const Color(0xFF00695C);
                              return Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 6),
                                child: SizedBox(
                                  height: chartBlockHeight,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.center,
                                    children: [
                                      SizedBox(
                                        height: runLabelHeight,
                                        child: Text("$runs", style: TextStyle(fontWeight: FontWeight.bold, color: isCurrent ? Colors.orange.shade800 : const Color(0xFF00695C))),
                                      ),
                                      const SizedBox(height: runLabelGap),
                                      SizedBox(
                                        width: 28,
                                        height: maxBarHeight,
                                        child: Stack(
                                          clipBehavior: Clip.none,
                                          alignment: Alignment.bottomCenter,
                                          children: [
                                            Container(
                                              width: 28,
                                              height: barHeight,
                                              decoration: BoxDecoration(
                                                color: barColor,
                                                borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                                              ),
                                            ),
                                            if (wkts > 0)
                                              Positioned(
                                                bottom: barHeight + dotGap,
                                                child: Column(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: List.generate(wkts, (wi) => Padding(
                                                        padding: EdgeInsets.only(bottom: wi == wkts - 1 ? 0 : dotGap),
                                                        child: Container(
                                                          width: dotSize,
                                                          height: dotSize,
                                                          alignment: Alignment.center,
                                                          decoration: BoxDecoration(
                                                            color: const Color(0xFFE0233A),
                                                            shape: BoxShape.circle,
                                                            border: Border.all(color: Colors.white, width: 1.3),
                                                            boxShadow: const [BoxShadow(color: Color(0x55E0233A), blurRadius: 3)],
                                                          ),
                                                          child: const Text('W', style: TextStyle(color: Colors.white, fontSize: 7.5, fontWeight: FontWeight.w900)),
                                                        ),
                                                      )),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: overLabelGap),
                                      SizedBox(
                                        height: overLabelHeight,
                                        child: Text("${i + 1}", style: const TextStyle(fontSize: 12, color: Colors.grey)),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Container(width: 12, height: 12, color: const Color(0xFF00695C)),
              const SizedBox(width: 6),
              Text(tr('completed_over_legend'), style: const TextStyle(fontSize: 12)),
              const SizedBox(width: 16),
              Container(width: 12, height: 12, color: Colors.orange),
              const SizedBox(width: 6),
              Text(tr('current_over_legend'), style: const TextStyle(fontSize: 12)),
              const SizedBox(width: 16),
              Container(
                width: 12, height: 12,
                decoration: const BoxDecoration(color: Color(0xFFE0233A), shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(tr('wicket_legend'), style: const TextStyle(fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }

  // "Scoring Comparison" tab - a worm/Manhattan-style line chart plotting
  // both innings' cumulative score against overs, side by side, like the
  // classic TV-broadcast graphic. Team A's line is the (possibly still in
  // progress) first innings; Team B's is the current one once the 2nd
  // innings has started - it's just empty/flat until then.
  Widget _buildComparisonTab() {
    final teamABallRuns = firstInningsData?.ballRuns ?? [];
    final teamBBallRuns = List<int>.from(ballCumulativeRuns);

    if (teamABallRuns.isEmpty && teamBBallRuns.isEmpty) {
      return Center(child: Text(tr('no_overs_bowled_yet'), style: const TextStyle(color: Colors.grey)));
    }

    final teamAName = firstInningsData?.teamName ?? currentBattingTeam;
    final teamBName = isSecondInnings ? currentBattingTeam : currentBowlingTeam;

    String? footerText;
    if (isSecondInnings && !isMatchOver) {
      final remainingRuns = targetScore - totalRuns;
      final remainingBalls = (maxOvers * 6) - matchBalls;
      if (remainingRuns > 0 && remainingBalls > 0) {
        final remainingOvers = remainingBalls / 6.0;
        final rpo = remainingRuns / remainingOvers;
        footerText = "$currentBattingTeam NEED $remainingRuns MORE TO WIN FROM ${remainingOvers.toStringAsFixed(1)} OVERS AT ${rpo.toStringAsFixed(2)} RPO";
      }
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Text(tr('scoring_comparison_caps').toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const Spacer(),
              _teamChip(teamAName, const Color(0xFF2E6BE6)),
              const SizedBox(width: 8),
              _teamChip(teamBName, const Color(0xFFE8973A)),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
            child: Container(
              padding: const EdgeInsets.fromLTRB(4, 10, 10, 4),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 10, offset: const Offset(0, 3))],
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: CustomPaint(
                size: Size.infinite,
                painter: _WormChartPainter(
                  teamACumulative: teamABallRuns,
                  teamBCumulative: teamBBallRuns,
                  maxOvers: maxOvers,
                  colorA: const Color(0xFF2E6BE6),
                  colorB: const Color(0xFFE8973A),
                ),
              ),
            ),
          ),
        ),
        if (footerText != null)
          Container(
            width: double.infinity,
            color: Colors.grey.shade200,
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(footerText, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
          ),
      ],
    );
  }

  Widget _teamChip(String name, Color color) {
    final label = name.length > 12 ? "${name.substring(0, 12)}…" : name;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
      child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
    );
  }

  // Looks the player up in the shared registry (read-only - never creates
  // a row just because someone tapped a button) and opens their existing
  // PlayerDetailScreen if found. Reuses that screen entirely rather than
  // building a second copy of stats/badges/form-graph UI here - this tab
  // is just a fast way IN, not a rebuild of what already exists.
  Future<void> _openPlayerDetails(String name) async {
    final player = await StorageService.findGlobalPlayerByExactName(name);
    if (!mounted) return;
    if (player == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('no_career_details').replaceFirst('%s', name))),
      );
      return;
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerDetailScreen(player: player)));
  }

  // Pushes the "SCORING COMPARISON" worm chart to viewers - the exact same
  // ball-by-ball data (and footer requirement text during a chase)
  // _buildComparisonTab computes locally for the scorer's own COMPARE tab.
  // Unlike a one-shot push, _pendingGraph is kept live: _pushLiveUpdate
  // (called after every single ball via the setState override above)
  // refreshes its arrays in place while it's the active card, so the
  // worm actually keeps moving on the viewer's screen ball-by-ball
  // instead of freezing at whatever it looked like the moment this
  // button was tapped.
  void _broadcastComparison() {
    if (_broadcastId == null) return;
    _pendingGraph = _buildComparisonGraphData(at: DateTime.now());
    _pushLiveUpdate();
  }

  // Recomputes the comparison graph's payload against CURRENT match state,
  // keeping [at] as given so a mid-display refresh doesn't look like a
  // brand new push to the viewer (see _pushLiveUpdate).
  BroadcastGraphData _buildComparisonGraphData({required DateTime at}) {
    final teamABallRuns = firstInningsData?.ballRuns ?? [];
    final teamBBallRuns = List<int>.from(ballCumulativeRuns);

    String? footerText;
    if (isSecondInnings && !isMatchOver) {
      final remainingRuns = targetScore - totalRuns;
      final remainingBalls = (maxOvers * 6) - matchBalls;
      if (remainingRuns > 0 && remainingBalls > 0) {
        final remainingOvers = remainingBalls / 6.0;
        final rpo = remainingRuns / remainingOvers;
        footerText = "$currentBattingTeam NEED $remainingRuns MORE TO WIN FROM ${remainingOvers.toStringAsFixed(1)} OVERS AT ${rpo.toStringAsFixed(2)} RPO";
      }
    }

    return BroadcastGraphData(
      teamAName: firstInningsData?.teamName ?? currentBattingTeam,
      teamBName: isSecondInnings ? currentBattingTeam : currentBowlingTeam,
      teamACumulative: teamABallRuns,
      teamBCumulative: teamBBallRuns,
      maxOvers: maxOvers,
      footerText: footerText,
      at: at,
    );
  }

  // Pushes the "Runs per Over" bar chart to viewers - the exact same data
  // _buildGraphTab computes locally for the scorer's own GRAPH tab.
  void _broadcastRunsPerOver() {
    if (_broadcastId == null) return;
    _pendingOvers = _buildRunsPerOverData(at: DateTime.now());
    _pushLiveUpdate();
  }

  // Builds the Runs/Over bars against the CURRENT match state, keeping the
  // caller-supplied [at] timestamp - shared by _broadcastRunsPerOver (first
  // push) and _pushLiveUpdate's per-ball refresh (keeps an already-visible
  // card up to date) so the two never drift apart.
  BroadcastOversData _buildRunsPerOverData({required DateTime at}) {
    final bars = List<int>.from(overRunsHistory);
    final wicketBars = List<int>.from(overWicketsHistory);
    if (matchBalls % 6 != 0) {
      bars.add(currentOverRuns);
      wicketBars.add(currentOverWickets);
    }

    return BroadcastOversData(
      teamName: currentBattingTeam,
      overRuns: bars,
      overWickets: wicketBars,
      at: at,
    );
  }

  // Pushes the current Striker-vs-current-Bowler head-to-head to viewers -
  // same player_matchups data ComparePlayersScreen's "Player Battle" shows,
  // just for whoever's actually at the crease right now.
  Future<void> _broadcastPlayerBattle() async {
    if (_broadcastId == null) return;
    final batsman = await StorageService.findGlobalPlayerByExactName(striker.name);
    final bowler = await StorageService.findGlobalPlayerByExactName(currentBowler.name);
    if (batsman == null || bowler == null || !mounted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('need_both_players_career_data'))),
        );
      }
      return;
    }
    final matchup = await StorageService.loadMatchup(batsman.id, bowler.id);
    if (!mounted) return;
    _pendingBattle = BroadcastPlayerBattle(
      batsmanName: batsman.name,
      bowlerName: bowler.name,
      runs: matchup?.runs ?? 0,
      balls: matchup?.balls ?? 0,
      dismissals: matchup?.dismissals ?? 0,
      at: DateTime.now(),
    );
    if (_broadcastId != null) _pushLiveUpdate();
  }

  // Pushes ONE team's full squad to viewers - straight from squadBatting/
  // squadBowling, which are already sitting in memory (set at match start),
  // so this needs zero extra queries. [battingTeam] picks which of the two
  // squads/team-names to send. One-off timed push, same pattern as
  // _broadcastComparison/_broadcastRunsPerOver/_broadcastPlayerBattle above.
  // True while a Playing XI push is out resolving player photos - guards
  // against a double-tap firing two overlapping lookups for the same squad.
  bool _isBroadcastingPlayingXI = false;

  Future<void> _broadcastPlayingXI(bool battingTeam) async {
    if (_broadcastId == null || _isBroadcastingPlayingXI) return;
    final squad = battingTeam ? squadBatting : squadBowling;
    // Guard against silently pushing an empty squad to viewers - this is
    // what used to cause the "Playing XI" viewer card to show just the
    // header with a blank list, with no clue on the scorer's side about
    // why. Now the scorer gets an immediate, actionable warning instead.
    if (squad.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr('squad_empty_error').replaceFirst('%s', battingTeam ? currentBattingTeam : currentBowlingTeam),
          ),
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }

    setState(() => _isBroadcastingPlayingXI = true);
    // Look up each squad member's photo from the shared player registry by
    // exact name (same read-only lookup the PLAYERS tab uses for career
    // details) so the viewer card can show real faces where they exist.
    // Unregistered/still-default names (e.g. "Bat-Player 3") simply
    // resolve to null and the viewer card shows a placeholder for them -
    // this never creates registry rows, same as _openPlayerDetails.
    List<String?> photoUrls;
    try {
      final lookups = await Future.wait(
        squad.map((p) => StorageService.findGlobalPlayerByExactName(p.name)),
      );
      photoUrls = lookups.map((gp) => gp?.photoUrl).toList();
    } catch (e) {
      // Photo lookup failing shouldn't block the push itself - worst case
      // every slot just falls back to the placeholder silhouette.
      photoUrls = List<String?>.filled(squad.length, null);
    }
    if (!mounted) return;

    _pendingPlayingXI = BroadcastPlayingXI(
      teamName: battingTeam ? currentBattingTeam : currentBowlingTeam,
      names: squad.map((p) => p.name).toList(),
      photoUrls: photoUrls,
      roles: squad.map((p) => p.role).toList(),
      at: DateTime.now(),
    );
    _pushLiveUpdate();
    setState(() => _isBroadcastingPlayingXI = false);
  }

  // Pushes ONE team's full batting scorecard to viewers, styled as a
  // broadcast innings card (team name, every batter's runs/balls/
  // dismissal, extras, overs and total) - same one-off timed-push pattern
  // as _broadcastPlayingXI above. [battingTeam] picks which team's card:
  // true = the team currently at the crease (in-progress innings, straight
  // from activeBatsmenList/totalRuns/etc); false = the team currently
  // bowling, i.e. whichever team already finished batting this match, from
  // firstInningsData - there's no "in-progress" scorecard to show for a
  // team that hasn't had its innings yet, so that case is a warning
  // instead of an empty card going out.
  bool _isBroadcastingScorecard = false;

  Future<void> _broadcastScorecard(bool battingTeam) async {
    if (_broadcastId == null || _isBroadcastingScorecard) return;

    final String team;
    final List<Batsman> bats;
    final int runs;
    final int wkts;
    final String overs;
    final int extrasCount;
    final List<Player> fullSquad;

    if (battingTeam) {
      team = currentBattingTeam;
      bats = activeBatsmenList;
      runs = totalRuns;
      wkts = totalWickets;
      overs = "${matchBalls ~/ 6}.${matchBalls % 6}";
      extrasCount = extras;
      fullSquad = squadBatting;
    } else if (firstInningsData != null) {
      team = firstInningsData!.teamName;
      bats = firstInningsData!.batsmen;
      runs = firstInningsData!.totalRuns;
      wkts = firstInningsData!.totalWickets;
      overs = firstInningsData!.overs;
      extrasCount = firstInningsData!.extras;
      fullSquad = firstInningsData!.squad;
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('hasnt_batted_yet').replaceFirst('%s', currentBowlingTeam))),
      );
      return;
    }

    // Guard against pushing an empty scorecard (e.g. tapped right at the
    // very start of an innings, before a ball's been bowled) - same
    // "nothing to show yet" guard _broadcastPlayingXI uses for an empty squad.
    if (bats.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('hasnt_faced_ball_yet').replaceFirst('%s', team))),
      );
      return;
    }

    setState(() => _isBroadcastingScorecard = true);

    // Resolve the tournament's display name for the card's subtitle line
    // (purely decorative, same "nothing else depends on it" spirit as
    // widget.tournamentId's other use above) - null/not found just omits
    // the line on the viewer side, no error shown here.
    String? tournamentName;
    if (widget.tournamentId != null) {
      final tournaments = await StorageService.loadTournaments();
      for (final t in tournaments) {
        if (t.id == widget.tournamentId) {
          tournamentName = t.name;
          break;
        }
      }
    }

    _pendingScorecard = BroadcastScorecardData(
      teamName: team,
      totalRuns: runs,
      totalWickets: wkts,
      oversDisplay: overs,
      extras: extrasCount,
      batsmen: bats.map((b) => b.clone()).toList(),
      at: DateTime.now(),
      tournamentName: tournamentName,
      // Only the currently-batting team's card has a real striker; the
      // already-finished team's card (battingTeam: false, from
      // firstInningsData) has no one at the crease anymore.
      strikerId: battingTeam ? striker.id : null,
      // Same "who hasn't batted yet" computation _buildFullInningsTable
      // uses locally - here it's precomputed at push time (just names)
      // rather than sending the whole squad + recomputing on the viewer
      // side, since that's all the card needs to render "YET TO BAT" rows.
      yetToBat: fullSquad.where((p) => !bats.any((b) => b.id == p.id)).map((p) => p.name).toList(),
    );
    _pushLiveUpdate();
    setState(() => _isBroadcastingScorecard = false);
  }

  bool _isBroadcastingBowling = false;

  // Pushes the CURRENTLY FIELDING team's bowling figures (O/M/R/W/Econ per
  // bowler who's bowled this innings) - this is what the "bowling team"
  // button on the LIVE CONTROL tab now does (see _buildPlayersTab below).
  // It used to push that team's own (often not-yet-existing, first
  // innings) batting scorecard instead, which meant tapping it during the
  // first innings just showed a "hasn't batted yet" error - bowling
  // figures, unlike a batting scorecard, always exist for whichever team
  // is fielding right now, in EITHER innings, which is why this replaces
  // that behavior entirely rather than sitting alongside it.
  Future<void> _broadcastBowlingFigures() async {
    if (_broadcastId == null || _isBroadcastingBowling) return;

    // Guard against pushing an empty table (e.g. tapped right at the very
    // start of an innings, before a ball's been bowled) - same "nothing to
    // show yet" guard _broadcastScorecard/_broadcastPlayingXI use.
    if (activeBowlersList.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('hasnt_bowled_ball_yet').replaceFirst('%s', currentBowlingTeam))),
      );
      return;
    }

    setState(() => _isBroadcastingBowling = true);

    // Resolve the tournament's display name for the card's subtitle line -
    // same lookup _broadcastScorecard does; null/not found just omits the
    // line on the viewer side.
    String? tournamentName;
    if (widget.tournamentId != null) {
      final tournaments = await StorageService.loadTournaments();
      for (final t in tournaments) {
        if (t.id == widget.tournamentId) {
          tournamentName = t.name;
          break;
        }
      }
    }

    _pendingBowling = BroadcastBowlingData(
      teamName: currentBowlingTeam,
      totalRuns: totalRuns,
      totalWickets: totalWickets,
      oversDisplay: "${matchBalls ~/ 6}.${matchBalls % 6}",
      extras: extras,
      bowlers: activeBowlersList.map((b) => b.clone()).toList(),
      at: DateTime.now(),
      tournamentName: tournamentName,
    );
    _pushLiveUpdate();
    setState(() => _isBroadcastingBowling = false);
  }

  // Quick-cue buttons for whoever is CURRENTLY in the match (striker,
  // non-striker, current bowler), plus Graph/Compare - this is a broadcast
  // CONTROL panel: tapping any of these pushes that graphic out to
  // viewers' live screens (see the spotlight/graph/playerBattle fields on
  // LiveBroadcast), not a local navigation shortcut for the scorer.
  // ---- Design tokens for the LIVE CONTROL console -------------------------
  // Kept local to this tab so the rest of the scorer (scoring/scorecard/etc)
  // is untouched. One accent family (deep broadcast teal + amber) reused
  // everywhere instead of ad-hoc colors per widget.
  static const Color _consoleInk = Color(0xFF0B3B34); // near-black teal for headings
  static const Color _consoleTeal = Color(0xFF00695C);
  static const Color _consoleTealDeep = Color(0xFF004D40);
  static const Color _consoleAmber = Color(0xFFD97706);
  static const Color _consoleBg = Color(0xFFF3F6F5);
  static const Color _consoleLine = Color(0xFFE1E9E7);

  Widget _buildPlayersTab() {
    if (_broadcastId == null) {
      return Container(
        color: _consoleBg,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(color: _consoleTeal.withOpacity(0.08), shape: BoxShape.circle),
                  child: const Icon(Icons.podcasts_outlined, color: _consoleTeal, size: 28),
                ),
                const SizedBox(height: 14),
                Text(tr('not_broadcasting_yet'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: _consoleInk)),
                const SizedBox(height: 6),
                Text(tr('go_live_top_bar_hint'), textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade600, fontSize: 13, height: 1.4)),
              ],
            ),
          ),
        ),
      );
    }
    return Container(
      color: _consoleBg,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
        children: [
          // ---- ON AIR status strip -----------------------------------
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [_consoleTealDeep, _consoleTeal]),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(color: _consoleTeal.withOpacity(0.25), blurRadius: 10, offset: const Offset(0, 4))],
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(tr('on_air'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12, letterSpacing: 1.2)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text("$currentBattingTeam vs $currentBowlingTeam", overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
                Icon(Icons.sensors, color: Colors.white.withOpacity(0.85), size: 16),
              ],
            ),
          ),
          const SizedBox(height: 18),

          _consoleSectionHeader(icon: Icons.person_pin_circle_outlined, title: "Focus Player", subtitle: "Tap to push a career card live · long-press to open it yourself"),
          const SizedBox(height: 10),
          _consoleCard(
            child: Column(
              children: [
                _focusPlayerCard(name: striker.name, role: "Striker", icon: Icons.sports_cricket, color: const Color(0xFF16A34A)),
                Divider(height: 1, thickness: 1, color: _consoleLine, indent: 54),
                _focusPlayerCard(name: nonStriker.name, role: "Non-Striker", icon: Icons.sports_cricket, color: const Color(0xFF16A34A)),
                Divider(height: 1, thickness: 1, color: _consoleLine, indent: 54),
                _focusPlayerCard(name: currentBowler.name, role: "Bowler", icon: Icons.sports_baseball, color: _consoleAmber),
              ],
            ),
          ),

          const SizedBox(height: 22),
          _consoleSectionHeader(icon: Icons.dashboard_customize_outlined, title: "Broadcast Graphics", subtitle: "One-off cards shown to viewers for a few seconds"),
          const SizedBox(height: 10),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 3.4,
            children: [
              _consoleActionTile(icon: Icons.bar_chart_rounded, label: "Runs/Over", color: _consoleTeal, onPressed: _broadcastRunsPerOver),
              _consoleActionTile(icon: Icons.show_chart_rounded, label: "Compare", color: _consoleTeal, onPressed: _broadcastComparison),
              _consoleActionTile(icon: Icons.sports_kabaddi_rounded, label: "Battle", color: _consoleTeal, onPressed: _broadcastPlayerBattle),
              _consoleActionTile(icon: Icons.groups_rounded, label: "$currentBattingTeam XI", color: _consoleAmber, onPressed: () => _broadcastPlayingXI(true)),
              _consoleActionTile(icon: Icons.groups_rounded, label: "$currentBowlingTeam XI", color: _consoleAmber, onPressed: () => _broadcastPlayingXI(false)),
              _consoleActionTile(icon: Icons.receipt_long_rounded, label: "$currentBattingTeam Scorecard", color: _consoleTealDeep, onPressed: () => _broadcastScorecard(true)),
              _consoleActionTile(icon: Icons.sports_baseball_rounded, label: "$currentBowlingTeam Bowling", color: _consoleTealDeep, onPressed: () => _broadcastBowlingFigures()),
            ],
          ),

          const SizedBox(height: 22),
          _consoleSectionHeader(icon: Icons.text_fields_rounded, title: "Bottom Stat Line", subtitle: "Stays on screen below the batsmen until you change it"),
          const SizedBox(height: 10),
          _consoleCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(child: _statLineButton(mode: 'crr', label: 'CRR')),
                    const SizedBox(width: 8),
                    Expanded(child: _statLineButton(mode: 'rrr', label: 'RRR')),
                    const SizedBox(width: 8),
                    Expanded(child: _statLineButton(mode: 'need', label: 'Need')),
                  ],
                ),
                const SizedBox(height: 10),
                // Free-text stat line: type a message, then tap "Show" to
                // push it - same button-driven pattern as CRR/RRR/Need
                // above, so it only goes out to viewers once you actually
                // tap Show, not on every keystroke.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _statLineTextCtrl,
                        // Capped so a long message can't overflow/wrap
                        // awkwardly on the viewer's screen - that strip is
                        // a single fixed-height line (maxLines: 1,
                        // ellipsis) sized for a short phrase.
                        maxLength: 30,
                        // BUG FIX: this field's background (_consoleBg /
                        // a light teal tint) is always light, but no text
                        // color was set here - so it fell back to the
                        // app's default TextField text color, which
                        // resolves to white in this screen's theme. White
                        // text on a near-white/light background is
                        // effectively invisible while typing. Pin it to
                        // the console's own dark ink color instead, same
                        // as every other label in this panel.
                        style: const TextStyle(fontSize: 14, color: _consoleInk),
                        cursorColor: _consoleTeal,
                        decoration: InputDecoration(
                          hintText: tr('custom_message_hint'),
                          hintStyle: const TextStyle(color: Colors.black38),
                          isDense: true,
                          filled: true,
                          fillColor: _statLineMode == 'custom' ? _consoleTeal.withOpacity(0.08) : _consoleBg,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          counterText: "",
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: _consoleTeal, width: 1.5)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 46,
                      child: ElevatedButton(
                        onPressed: _showCustomStatLine,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _statLineMode == 'custom' ? _consoleTeal : _consoleBg,
                          foregroundColor: _statLineMode == 'custom' ? Colors.white : _consoleTeal,
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: _statLineMode == 'custom' ? BorderSide.none : const BorderSide(color: _consoleTeal)),
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                        ),
                        child: Text(tr('show_word'), style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Small caps-style section label used across the LIVE CONTROL console -
  // an icon chip + title + one-line subtitle, so every section reads the
  // same way instead of ad-hoc bold Text widgets.
  Widget _consoleSectionHeader({required IconData icon, required String title, required String subtitle}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          margin: const EdgeInsets.only(top: 1),
          decoration: BoxDecoration(color: _consoleTeal.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
          child: Icon(icon, size: 16, color: _consoleTeal),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5, color: _consoleInk, letterSpacing: 0.1)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(color: Colors.grey.shade600, fontSize: 11.5, height: 1.3)),
            ],
          ),
        ),
      ],
    );
  }

  // Flat white panel with a hairline border used to group related controls -
  // the console's basic building block (Focus Player list, Stat Line panel).
  Widget _consoleCard({required Widget child, EdgeInsetsGeometry padding = EdgeInsets.zero}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _consoleLine),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: Padding(padding: padding, child: child),
      ),
    );
  }

  // One tile in the 2x2 "Broadcast Graphics" grid - icon-left/label-right
  // on a tinted background, so all four push-actions (Runs/Over, Compare,
  // Battle, Playing XI) read as one console rather than plain outlined
  // buttons of varying widths.
  Widget _consoleActionTile({required IconData icon, required String label, required Color color, required VoidCallback onPressed}) {
    return Material(
      color: color.withOpacity(0.08),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onPressed,
        child: Container(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withOpacity(0.25))),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(7)),
                child: Icon(icon, color: Colors.white, size: 13),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(label, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11.5, color: color == _consoleAmber ? const Color(0xFF92400E) : _consoleTealDeep), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Selects which stat shows on viewers' screens below the two batsmen -
  // stays selected until a different one is tapped. Piggybacks the normal
  // setState -> _pushLiveUpdate flow, so no separate network call needed.
  void _setStatLine(String mode) {
    if (_statLineMode == mode) return;
    setState(() => _statLineMode = mode);
  }

  // Custom stat line "Show" button: pushes the typed text out immediately
  // (unlike CRR/RRR/Need, which just flip a mode and ride along on the next
  // ball's regular push, this has no "next ball" to ride on since the
  // scorer might tap Show without any new delivery happening) - so it needs
  // its own explicit _pushLiveUpdate() call, same as the Runs/Over/Compare/
  // Battle buttons above do.
  void _showCustomStatLine() {
    final text = _statLineTextCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _statLineCustomText = text;
      _statLineMode = 'custom';
    });
    if (_broadcastId == null) {
      // Not live yet - nothing to push. Without this, tapping Show here
      // silently does nothing network-wise, and the viewer (once the
      // broadcast does start) would show whatever the default (CRR) is
      // instead of this text, which looks like "Show doesn't work".
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('not_live_yet_snackbar'))),
      );
      return;
    }
    _pushLiveUpdate();
  }

  Widget _statLineButton({required String mode, required String label}) {
    final isActive = _statLineMode == mode;
    return SizedBox(
      height: 42,
      child: OutlinedButton(
        onPressed: () => _setStatLine(mode),
        style: OutlinedButton.styleFrom(
          backgroundColor: isActive ? _consoleTeal : _consoleBg,
          foregroundColor: isActive ? Colors.white : _consoleTeal,
          side: BorderSide(color: isActive ? _consoleTeal : _consoleLine),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: EdgeInsets.zero,
        ),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
      ),
    );
  }

  // A single row inside the "Focus Player" console card - flat (no own
  // shadow/border) since it now lives inside _consoleCard's white panel,
  // separated from its siblings by hairline Dividers instead.
  Widget _focusPlayerCard({required String name, required String role, required IconData icon, required Color color}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _fetchSpotlight(name, isBatter: role != "Bowler"),
        onLongPress: () => _openPlayerDetails(name),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              CircleAvatar(radius: 18, backgroundColor: color.withOpacity(0.12), child: Icon(icon, color: color, size: 18)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5, color: _consoleInk), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(role, style: TextStyle(color: Colors.grey.shade600, fontSize: 11.5)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(color: Colors.redAccent.withOpacity(0.1), shape: BoxShape.circle),
                child: const Icon(Icons.podcasts, color: Colors.redAccent, size: 15),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCommentaryTab() {
    return ListView.builder(
      itemCount: ballHistoryDisplay.length,
      itemBuilder: (context, index) {
        final text = ballHistoryDisplay[index];
        bool isOverEnd = text.startsWith("End");
        bool isWicket = text.contains("W") && !text.contains("WD");

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: isOverEnd ? Colors.blueGrey.shade50 : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade100),
          ),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: isWicket ? Colors.red : Colors.grey.shade200,
              radius: 14,
              child: isOverEnd
                ? const Icon(Icons.timer, size: 14, color: Colors.black54)
                : Text(text.split("-").last.trim().replaceAll(RegExp(r'[^0-9A-Z]'), ''), style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isWicket ? Colors.white : Colors.black)),
            ),
            title: Text(text, style: TextStyle(fontWeight: isOverEnd ? FontWeight.bold : FontWeight.w500, fontSize: 14)),
          ),
        );
      },
    );
  }

  Widget _buildActiveBatsman(Batsman b, bool isOnStrike, Function(String, String?) onEdit) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isOnStrike ? Colors.white : Colors.white.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
        border: isOnStrike ? Border.all(color: const Color(0xFF00695C), width: 1.5) : Border.all(color: Colors.transparent),
        boxShadow: isOnStrike ? [BoxShadow(color: Colors.teal.withOpacity(0.1), blurRadius: 4, offset: const Offset(0, 2))] : [],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(Icons.person, size: 17, color: isOnStrike ? const Color(0xFF00695C) : Colors.grey),
              const SizedBox(width: 6),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(b.name, style: TextStyle(fontSize: 13, fontWeight: isOnStrike ? FontWeight.bold : FontWeight.w500)),
                      if (isOnStrike) const Padding(
                        padding: EdgeInsets.only(left: 4.0),
                        child: Icon(Icons.star, size: 10, color: Colors.orange),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit, size: 12, color: Colors.grey),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                        onPressed: () async {
                          await _editPlayerNameDialog(Player(name: b.name, id: b.id));
                          onEdit(b.name, null);
                        },
                      )
                    ],
                  ),
                  Text("SR: ${b.sr}", style: const TextStyle(fontSize: 9, color: Colors.grey)),
                ],
              ),
            ],
          ),
          Text("${b.runs}(${b.balls})", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        ],
      ),
    );
  }

  Widget _statItem(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6.0),
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 9, color: Colors.grey, fontWeight: FontWeight.bold)),
          Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

// Draws two cumulative-runs-by-over lines (with dot markers at each
// completed over) on a shared runs/overs grid - the "worm" / Manhattan
// comparison chart. Kept as a plain CustomPainter (no chart package) so it
// has no extra pub dependency.
class _WormChartPainter extends CustomPainter {
  final List<int> teamACumulative;
  final List<int> teamBCumulative;
  final int maxOvers;
  final Color colorA;
  final Color colorB;

  _WormChartPainter({
    required this.teamACumulative,
    required this.teamBCumulative,
    required this.maxOvers,
    required this.colorA,
    required this.colorB,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 40.0;
    const bottomPad = 22.0;
    const topPad = 8.0;
    const rightPad = 8.0;

    final chartWidth = (size.width - leftPad - rightPad).clamp(1.0, double.infinity);
    final chartHeight = (size.height - topPad - bottomPad).clamp(1.0, double.infinity);
    final overSpan = maxOvers < 1 ? 1 : maxOvers;
    // Every entry is one delivery, not one over - so the x-axis has to
    // scale against the total number of balls in the innings, not the
    // number of overs, or the line would bunch up in the first ~1/6th
    // of the chart.
    final maxBalls = overSpan * 6;

    final highestRuns = [
      teamACumulative.isNotEmpty ? teamACumulative.last : 0,
      teamBCumulative.isNotEmpty ? teamBCumulative.last : 0,
      10,
    ].reduce((a, b) => a > b ? a : b);
    final axisMax = (((highestRuns * 1.1) / 20).ceil() * 20).clamp(20, 100000);

    final gridPaint = Paint()..color = Colors.grey.withOpacity(0.2)..strokeWidth = 1;
    final axisTextStyle = TextStyle(color: Colors.grey.shade600, fontSize: 10, fontWeight: FontWeight.w600);

    void paintText(String text, Offset offset) {
      final tp = TextPainter(text: TextSpan(text: text, style: axisTextStyle), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, offset);
    }

    // Horizontal grid lines + run labels (5 bands).
    for (int i = 0; i <= 4; i++) {
      final y = topPad + chartHeight - (chartHeight * i / 4);
      canvas.drawLine(Offset(leftPad, y), Offset(leftPad + chartWidth, y), gridPaint);
      final label = (axisMax * i / 4).round().toString();
      final tp = TextPainter(text: TextSpan(text: label, style: axisTextStyle), textDirection: TextDirection.ltr)..layout();
      paintText(label, Offset(leftPad - tp.width - 6, y - tp.height / 2));
    }

    // Over labels along the bottom.
    final overStep = overSpan <= 10 ? 1 : (overSpan / 5).ceil();
    for (int o = 0; o <= overSpan; o += overStep) {
      final x = leftPad + chartWidth * (o / overSpan);
      paintText("$o", Offset(x - 6, topPad + chartHeight + 4));
    }

    void drawLine(List<int> cumulative, Color color) {
      if (cumulative.isEmpty) return;
      final linePaint = Paint()
        ..color = color
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      final points = <Offset>[Offset(leftPad, topPad + chartHeight)];
      for (int i = 0; i < cumulative.length; i++) {
        final ball = i + 1;
        final x = leftPad + chartWidth * (ball / maxBalls).clamp(0.0, 1.0);
        final y = topPad + chartHeight - chartHeight * (cumulative[i] / axisMax).clamp(0.0, 1.0);
        points.add(Offset(x, y));
      }

      // Soft gradient fill under the line - reads much cleaner than a bare
      // line, and matches the broadcast-style worm chart viewers see.
      final fillPath = Path()..moveTo(points.first.dx, points.first.dy);
      for (final p in points.skip(1)) {
        fillPath.lineTo(p.dx, p.dy);
      }
      fillPath.lineTo(points.last.dx, topPad + chartHeight);
      fillPath.close();
      canvas.drawPath(
        fillPath,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color.withOpacity(0.22), color.withOpacity(0.0)],
          ).createShader(Rect.fromLTWH(leftPad, topPad, chartWidth, chartHeight)),
      );

      final linePath = Path()..moveTo(points.first.dx, points.first.dy);
      for (final p in points.skip(1)) {
        linePath.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(linePath, linePaint);

      // Glowing end-point marks the team's current score.
      final last = points.last;
      canvas.drawCircle(last, 6, Paint()..color = color.withOpacity(0.28)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
      canvas.drawCircle(last, 4, Paint()..color = Colors.white);
      canvas.drawCircle(last, 4, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2.2);
    }

    drawLine(teamACumulative, colorA);
    drawLine(teamBCumulative, colorB);
  }

  @override
  bool shouldRepaint(covariant _WormChartPainter oldDelegate) {
    return oldDelegate.teamACumulative.length != teamACumulative.length ||
        oldDelegate.teamBCumulative.length != teamBCumulative.length ||
        oldDelegate.maxOvers != maxOvers ||
        (teamACumulative.isNotEmpty && oldDelegate.teamACumulative.isNotEmpty && oldDelegate.teamACumulative.last != teamACumulative.last) ||
        (teamBCumulative.isNotEmpty && oldDelegate.teamBCumulative.isNotEmpty && oldDelegate.teamBCumulative.last != teamBCumulative.last);
  }
}