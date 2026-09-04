import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../l10n/app_strings.dart';
import 'match_result_screen.dart';

class MatchDetailScreen extends StatelessWidget {
  final TournamentMatch match;
  const MatchDetailScreen({super.key, required this.match});

  @override
  Widget build(BuildContext context) {
    final data = match.matchData;
    if (data == null) {
      return Scaffold(
        appBar: AppBar(title: Text("${match.teamA} vs ${match.teamB}"), backgroundColor: const Color(0xFF00695C), foregroundColor: Colors.white),
        body: Center(child: Text(tr('match_not_started'))),
      );
    }
    return MatchResultScreen(data: data);
  }
}
