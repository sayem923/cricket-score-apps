import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../models/models.dart';

const PdfColor _teal = PdfColor.fromInt(0xFF00695C);
const PdfColor _lightTeal = PdfColor.fromInt(0xFFE0F2F1);
const PdfColor _grey = PdfColor.fromInt(0xFF757575);

/// Renders a full batting/bowling scorecard PDF for one completed match -
/// used by both the post-match result screen and Match History's "Download"
/// action (same builder, same layout, either place).
Future<Uint8List> buildScorecardPdf(MatchResultData result) async {
  final doc = pw.Document();

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      header: (context) => context.pageNumber == 1 ? _matchHeader(result) : pw.SizedBox(),
      footer: (context) => pw.Container(
        alignment: pw.Alignment.centerRight,
        margin: const pw.EdgeInsets.only(top: 8),
        child: pw.Text('Page ${context.pageNumber} of ${context.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: _grey)),
      ),
      build: (context) => [
        if (result.innings1 != null) ..._inningsSection(result.innings1!),
        if (result.innings2 != null) ..._inningsSection(result.innings2!),
      ],
    ),
  );

  return doc.save();
}

pw.Widget _matchHeader(MatchResultData result) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text('Match Scorecard', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: _teal)),
      pw.SizedBox(height: 4),
      pw.Text('${result.teamName1} vs ${result.teamName2}', style: const pw.TextStyle(fontSize: 13)),
      if (result.playedAt != null)
        pw.Text(
          '${result.playedAt!.day}/${result.playedAt!.month}/${result.playedAt!.year}',
          style: const pw.TextStyle(fontSize: 10, color: _grey),
        ),
      pw.SizedBox(height: 6),
      pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: pw.BoxDecoration(color: _lightTeal, borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4))),
        child: pw.Text(
          result.winner == 'Tie' ? 'Match Tied' : '${result.winner} won by ${result.margin}',
          style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: _teal),
        ),
      ),
      pw.SizedBox(height: 14),
    ],
  );
}

List<pw.Widget> _inningsSection(InningsHistory innings) {
  return [
    pw.Text(
      '${innings.teamName}  ${innings.totalRuns}/${innings.totalWickets}  (${innings.overs} ov)',
      style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
    ),
    pw.SizedBox(height: 6),
    _battingTable(innings.batsmen),
    pw.SizedBox(height: 4),
    pw.Text('Extras: ${innings.extras}', style: const pw.TextStyle(fontSize: 9, color: _grey)),
    pw.SizedBox(height: 12),
    pw.Text('Bowling', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: _teal)),
    pw.SizedBox(height: 4),
    _bowlingTable(innings.bowlers),
    pw.SizedBox(height: 18),
  ];
}

pw.Widget _battingTable(List<Batsman> batsmen) {
  return pw.Table(
    border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: PdfColors.grey300, width: 0.5)),
    columnWidths: const {
      0: pw.FlexColumnWidth(3.2),
      1: pw.FlexColumnWidth(2.4),
      2: pw.FlexColumnWidth(0.9),
      3: pw.FlexColumnWidth(0.9),
      4: pw.FlexColumnWidth(0.7),
      5: pw.FlexColumnWidth(0.7),
      6: pw.FlexColumnWidth(1.0),
    },
    children: [
      _rowHeader(['Batsman', 'Dismissal', 'R', 'B', '4s', '6s', 'SR']),
      for (final b in batsmen)
        _row([
          b.name,
          b.dismissal,
          '${b.runs}',
          '${b.balls}',
          '${b.fours}',
          '${b.sixes}',
          b.balls > 0 ? ((b.runs / b.balls) * 100).toStringAsFixed(1) : '-',
        ]),
    ],
  );
}

pw.Widget _bowlingTable(List<Bowler> bowlers) {
  return pw.Table(
    border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: PdfColors.grey300, width: 0.5)),
    columnWidths: const {
      0: pw.FlexColumnWidth(3.2),
      1: pw.FlexColumnWidth(1.2),
      2: pw.FlexColumnWidth(1.2),
      3: pw.FlexColumnWidth(1.2),
      4: pw.FlexColumnWidth(1.2),
      5: pw.FlexColumnWidth(1.2),
    },
    children: [
      _rowHeader(['Bowler', 'O', 'M', 'R', 'W', 'Econ']),
      for (final b in bowlers)
        _row([
          b.name,
          _oversDisplay(b.balls),
          '${b.maidens}',
          '${b.runs}',
          '${b.wickets}',
          b.balls > 0 ? (b.runs / (b.balls / 6)).toStringAsFixed(2) : '-',
        ]),
    ],
  );
}

String _oversDisplay(int balls) => '${balls ~/ 6}.${balls % 6}';

pw.TableRow _rowHeader(List<String> cells) {
  return pw.TableRow(
    decoration: const pw.BoxDecoration(color: _lightTeal),
    children: cells
        .map((c) => pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
              child: pw.Text(c, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: _teal)),
            ))
        .toList(),
  );
}

pw.TableRow _row(List<String> cells) {
  return pw.TableRow(
    children: cells
        .map((c) => pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: pw.Text(c, style: const pw.TextStyle(fontSize: 9)),
            ))
        .toList(),
  );
}
