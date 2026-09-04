import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:printing/printing.dart';
import '../../models/models.dart';
import '../../utils/extensions.dart';
import '../../utils/pdf_scorecard.dart';
import '../../utils/share_image.dart';
import '../../widgets/download_scorecard_button.dart';
import '../../widgets/share_format_sheet.dart';
import '../../widgets/share_score_cards.dart';
import '../../l10n/app_strings.dart';

/// Shows the full scorecard for a completed match. Used both right after a
/// Quick Match finishes and when re-opening a match from history — so a
/// finished match's result is never just thrown away.
class MatchResultScreen extends StatelessWidget {
  final MatchResultData data;
  final bool isFreshResult;

  const MatchResultScreen({super.key, required this.data, this.isFreshResult = false});

  // Builds a plain-text final-result summary for the native share sheet
  // (#5 - Real-time score share). Deliberately short - team scores, the
  // result line, and Man of the Match if one was picked - since this is
  // meant for a WhatsApp/Messenger message, not a scorecard; the full
  // scorecard is still available as a PDF (see the PDF option in
  // _shareResult, and DownloadScorecardButton right next to it).
  String _buildResultShareText() {
    final buffer = StringBuffer();
    buffer.writeln("${data.teamName1} ${data.innings1Score}");
    buffer.writeln("${data.teamName2} ${data.innings2Score}");
    if (data.isComplete) {
      buffer.writeln(data.winner == "Tie" ? tr('match_tied') : "${data.winner} ${tr('won_by').replaceFirst('%s', data.margin)}");
      if (data.manOfTheMatch != null && data.manOfTheMatch!.isNotEmpty) {
        buffer.writeln(tr('man_of_the_match').replaceFirst('%s', data.manOfTheMatch!));
      }
    }
    return buffer.toString().trim();
  }

  Future<void> _shareResult(BuildContext context) async {
    showShareFormatSheet(
      context,
      includePdf: true,
      onSelect: (format) async {
        switch (format) {
          case ShareFormat.text:
            Share.share(_buildResultShareText(), subject: tr('app_name'));
            break;
          case ShareFormat.image:
            await shareWidgetAsImage(
              context,
              card: MatchResultShareCard(
                teamName1: data.teamName1,
                innings1Score: data.innings1Score,
                teamName2: data.teamName2,
                innings2Score: data.innings2Score,
                isComplete: data.isComplete,
                winner: data.winner,
                margin: data.margin,
                manOfTheMatch: data.manOfTheMatch,
                innings1: data.innings1,
                innings2: data.innings2,
              ),
              filename: 'match_result.png',
              text: tr('app_name'),
            );
            break;
          case ShareFormat.pdf:
            // Same PDF this match's DownloadScorecardButton produces -
            // reused here rather than duplicated, so the layout never
            // drifts between the two entry points.
            final bytes = await buildScorecardPdf(data);
            final safeNames = '${data.teamName1}_vs_${data.teamName2}'.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '');
            await Printing.sharePdf(bytes: bytes, filename: 'scorecard_$safeNames.pdf');
            break;
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("${data.teamName1} vs ${data.teamName2}", overflow: TextOverflow.ellipsis, maxLines: 1),
        backgroundColor: const Color(0xFF00695C),
        foregroundColor: Colors.white,
        automaticallyImplyLeading: !isFreshResult,
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: tr('share_result_tooltip'),
            onPressed: () => _shareResult(context),
          ),
          DownloadScorecardButton(result: data, compact: true),
          if (isFreshResult)
            TextButton(
              onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
              child: Text(tr('done').toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!data.isComplete)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Colors.orange.shade50, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.orange.shade200)),
                child: Row(children: [
                  Icon(Icons.info_outline, color: Colors.orange.shade800, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(tr('exited_early_notice'), style: TextStyle(color: Colors.orange.shade900, fontSize: 12))),
                ]),
              ),
            Center(child: Text(data.margin, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.green))),
            if (data.manOfTheMatch != null && data.manOfTheMatch!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(color: Colors.amber.shade50, borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.amber.shade300)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.star, color: Colors.amber.shade700, size: 18),
                      const SizedBox(width: 6),
                      Text(tr('man_of_the_match').replaceFirst('%s', '${data.manOfTheMatch}'), style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber.shade900, fontSize: 13)),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            if (data.innings1 != null)
              _buildInningsScorecard(data.teamName1, data.innings1Score, data.innings1!.overs, data.innings1!.batsmen, data.innings1!.bowlers, data.innings1!.squad, data.innings1!.extras),
            if (data.innings1 != null && data.innings1!.commentary.isNotEmpty)
              _buildCommentary(data.teamName1, data.innings1!.commentary),
            if (data.innings2 != null)
              _buildInningsScorecard(data.teamName2, data.innings2Score, data.innings2!.overs, data.innings2!.batsmen, data.innings2!.bowlers, data.innings2!.squad, data.innings2!.extras),
            if (data.innings2 != null && data.innings2!.commentary.isNotEmpty)
              _buildCommentary(data.teamName2, data.innings2!.commentary),
          ],
        ),
      ),
    );
  }

  Widget _buildCommentary(String teamName, List<String> commentary) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: ExpansionTile(
        title: Text(tr('ball_by_ball_title').replaceFirst('%s', teamName), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              itemCount: commentary.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(commentary[i], style: const TextStyle(fontSize: 13)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInningsScorecard(String teamName, String score, String overs, List<Batsman> batsmen, List<Bowler> bowlers, List<Player> squad, int extras) {
    List<Player> didNotBat = squad.where((p) => !batsmen.any((b) => b.id == p.id)).toList();
    return Card(margin: const EdgeInsets.only(bottom: 16), clipBehavior: Clip.antiAlias, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), child: Column(children: [
      Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), color: const Color(0xFF00695C), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(teamName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)), Text("$score ($overs)", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16))])),
      Container(color: Colors.grey.shade200, padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12), child: Row(children: [Expanded(flex: 4, child: Text(tr('col_batter'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))), Expanded(child: Text(tr('col_r'), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))), Expanded(child: Text(tr('col_b'), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))), Expanded(child: Text(tr('col_4s'), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))), Expanded(child: Text(tr('col_6s'), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))), Expanded(child: Text(tr('col_sr'), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)))])),
      ...batsmen.map((b) => Container(decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Colors.grey.shade100))), padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12), child: Row(children: [Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(b.name, style: const TextStyle(color: Color(0xFF1565C0), fontWeight: FontWeight.w600)), Text(b.dismissal, style: const TextStyle(color: Colors.grey, fontSize: 11))])), Expanded(child: Text("${b.runs}", textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold))), Expanded(child: Text("${b.balls}", textAlign: TextAlign.center)), Expanded(child: Text("${b.fours}", textAlign: TextAlign.center)), Expanded(child: Text("${b.sixes}", textAlign: TextAlign.center)), Expanded(child: Text(b.sr, textAlign: TextAlign.center))]))),
      Container(padding: const EdgeInsets.all(12), child: Row(children: [Text(tr('col_extras'), style: const TextStyle(fontWeight: FontWeight.bold)), const Spacer(), Text("$extras", style: const TextStyle(fontWeight: FontWeight.bold))])),
      Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), color: Colors.grey.shade50, child: Row(children: [Text(tr('col_total'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)), const Spacer(), Text("$score ($overs Ov)", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))])),
      if (didNotBat.isNotEmpty) Container(width: double.infinity, padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(tr('did_not_bat'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)), const SizedBox(height: 4), Wrap(spacing: 8, children: didNotBat.map((p) => Text(p.name, style: const TextStyle(color: Color(0xFF1565C0), fontSize: 12))).toList())])),
      Container(color: Colors.grey.shade200, padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12), child: Row(children: [Expanded(flex: 4, child: Text(tr('col_bowler'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))), Expanded(child: Text(tr('col_overs_short'), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))), Expanded(child: Text(tr('col_maidens_short'), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))), Expanded(child: Text(tr('col_r'), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))), Expanded(child: Text(tr('col_wkts'), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))), Expanded(child: Text(tr('col_eco'), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)))])),
      ...bowlers.map((b) { double economy = b.balls > 0 ? (b.runs / (b.balls / 6)) : 0.0; return Container(decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Colors.grey.shade100))), padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12), child: Row(children: [Expanded(flex: 4, child: Text(b.name, style: const TextStyle(color: Color(0xFF1565C0), fontWeight: FontWeight.w600))), Expanded(child: Text(b.oversDisplay, textAlign: TextAlign.center)), Expanded(child: Text("${b.maidens}", textAlign: TextAlign.center)), Expanded(child: Text("${b.runs}", textAlign: TextAlign.center)), Expanded(child: Text("${b.wickets}", textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold))), Expanded(child: Text(economy.toStringAsFixed(2), textAlign: TextAlign.center))])); }),
    ]));
  }
}