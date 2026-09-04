import 'package:flutter/material.dart';
import '../models/models.dart';
import '../l10n/app_strings.dart';

/// Fixed-size, self-contained card used only as the source for
/// shareWidgetAsImage (#5 - share as PNG) - never shown directly in the
/// normal UI, so it doesn't reference Theme.of(context)/AppColors and
/// carries its own colors, matching share_image.dart's requirement that
/// the card work correctly when mounted briefly outside this screen's
/// real widget tree.
class LiveScoreShareCard extends StatelessWidget {
  final String battingTeam;
  final String bowlingTeam;
  final int runs;
  final int wickets;
  final String oversText;
  final int maxOvers;
  final String? chaseText;

  const LiveScoreShareCard({
    super.key,
    required this.battingTeam,
    required this.bowlingTeam,
    required this.runs,
    required this.wickets,
    required this.oversText,
    required this.maxOvers,
    this.chaseText,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 360,
      padding: const EdgeInsets.all(24),
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF00695C), Color(0xFF00332C)]),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.sports_cricket, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Text(tr('app_name'), style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
            ],
          ),
          const SizedBox(height: 20),
          Text(battingTeam, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text("$runs/$wickets", style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.w900, height: 1)),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text("($oversText/$maxOvers ov)", style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text("vs", style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 13)),
              const SizedBox(width: 8),
              Expanded(child: Text(bowlingTeam, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
          ),
          if (chaseText != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
              child: Text(chaseText!, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
            ),
          ],
        ],
      ),
    );
  }
}

/// Same idea as [LiveScoreShareCard], but for a finished match's full
/// scorecard - both innings' batting and bowling detail, not just the
/// team totals. Renders considerably taller than a phone screen; that's
/// fine since this is only ever captured as an image (see
/// shareWidgetAsImage), never displayed on-screen directly.
class MatchResultShareCard extends StatelessWidget {
  final String teamName1;
  final String innings1Score;
  final String teamName2;
  final String innings2Score;
  final bool isComplete;
  final String winner;
  final String margin;
  final String? manOfTheMatch;
  final InningsHistory? innings1;
  final InningsHistory? innings2;

  const MatchResultShareCard({
    super.key,
    required this.teamName1,
    required this.innings1Score,
    required this.teamName2,
    required this.innings2Score,
    required this.isComplete,
    required this.winner,
    required this.margin,
    this.manOfTheMatch,
    this.innings1,
    this.innings2,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 380,
      padding: const EdgeInsets.all(20),
      color: const Color(0xFF00332C),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.emoji_events_outlined, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Text(tr('app_name'), style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
            ],
          ),
          const SizedBox(height: 4),
          Text("$teamName1 vs $teamName2", style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          if (isComplete) ...[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.14), borderRadius: BorderRadius.circular(8)),
              child: Text(
                winner == "Tie" ? tr('match_tied') : "$winner ${tr('won_by').replaceFirst('%s', margin)}",
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
            if (manOfTheMatch != null && manOfTheMatch!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(tr('man_of_the_match').replaceFirst('%s', manOfTheMatch!), style: const TextStyle(color: Colors.amberAccent, fontSize: 12, fontWeight: FontWeight.w600)),
            ],
          ],
          if (innings1 != null) _inningsSection(innings1!, innings1Score),
          if (innings2 != null) _inningsSection(innings2!, innings2Score),
        ],
      ),
    );
  }

  Widget _inningsSection(InningsHistory innings, String scoreLine) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(innings.teamName, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
              Text(scoreLine, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 8),
          _tableHeaderRow([tr('col_batter'), tr('col_r'), tr('col_b'), tr('col_4s'), tr('col_6s')]),
          ...innings.batsmen.where((b) => b.balls > 0 || b.dismissal != "not out").map(
                (b) => _tableRow([b.name, "${b.runs}", "${b.balls}", "${b.fours}", "${b.sixes}"]),
              ),
          const SizedBox(height: 10),
          _tableHeaderRow([tr('col_bowler'), tr('col_overs_short'), tr('col_r'), tr('col_wkts')]),
          ...innings.bowlers.where((b) => b.balls > 0).map(
                (b) => _tableRow([b.name, "${(b.balls / 6).floor()}.${b.balls % 6}", "${b.runs}", "${b.wickets}"]),
              ),
        ],
      ),
    );
  }

  Widget _tableHeaderRow(List<String> labels) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(flex: 4, child: Text(labels[0], style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 11, fontWeight: FontWeight.w700))),
          for (final label in labels.skip(1))
            Expanded(child: Text(label, textAlign: TextAlign.right, style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 11, fontWeight: FontWeight.w700))),
        ],
      ),
    );
  }

  Widget _tableRow(List<String> values) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(flex: 4, child: Text(values[0], style: const TextStyle(color: Colors.white, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis)),
          for (final value in values.skip(1))
            Expanded(child: Text(value, textAlign: TextAlign.right, style: const TextStyle(color: Colors.white, fontSize: 12))),
        ],
      ),
    );
  }
}