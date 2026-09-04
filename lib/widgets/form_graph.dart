import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/models.dart';

/// Small runs-per-match trend line, oldest match on the left. [performances]
/// should already be in chronological (oldest-first) order - callers
/// typically reverse StorageService.loadRecentPerformances' newest-first
/// list before passing it in here.
class FormGraph extends StatelessWidget {
  final List<MatchPerformance> performances;
  const FormGraph({super.key, required this.performances});

  @override
  Widget build(BuildContext context) {
    if (performances.length < 2) {
      // A single point isn't a trend - the numeric summary above this
      // widget already covers the one-match case, so just take up no
      // space rather than rendering a meaningless flat line.
      return const SizedBox.shrink();
    }

    final spots = <FlSpot>[
      for (int i = 0; i < performances.length; i++) FlSpot(i.toDouble(), performances[i].runs.toDouble()),
    ];
    final maxRuns = performances.map((p) => p.runs).fold<int>(0, (a, b) => a > b ? a : b);

    return SizedBox(
      height: 140,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: (maxRuns * 1.25).clamp(10, double.infinity),
          gridData: FlGridData(show: true, drawVerticalLine: false, horizontalInterval: (maxRuns / 3).clamp(5, double.infinity)),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(showTitles: true, reservedSize: 30, interval: (maxRuns / 3).clamp(5, double.infinity)),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 20,
                interval: 1,
                getTitlesWidget: (value, meta) {
                  final i = value.toInt();
                  if (i < 0 || i >= performances.length) return const SizedBox.shrink();
                  final d = performances[i].playedAt;
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('${d.day}/${d.month}', style: TextStyle(fontSize: 9, color: Colors.grey.shade500)),
                  );
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (spots) => spots.map((s) {
                final p = performances[s.x.toInt()];
                return LineTooltipItem(
                  '${p.runs} runs${p.opponentTeam != null ? '\nvs ${p.opponentTeam}' : ''}',
                  const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                );
              }).toList(),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              color: const Color(0xFF00695C),
              barWidth: 2.5,
              dotData: const FlDotData(show: true),
              belowBarData: BarAreaData(show: true, color: const Color(0xFF00695C).withOpacity(0.08)),
            ),
          ],
        ),
      ),
    );
  }
}
