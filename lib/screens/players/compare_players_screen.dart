import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../services/storage_service.dart';
import '../../l10n/app_strings.dart';
import '../../utils/extensions.dart';
import '../../widgets/player_autocomplete_field.dart';

/// Pick two registered players and see their career stats side by side,
/// plus how many times they've played together/against each other -
/// derived from `match_participants`, which only has rows for matches
/// synced since that table was introduced (see the SQL migration notes).
/// Matches synced before that won't count toward the head-to-head total.
class ComparePlayersScreen extends StatefulWidget {
  const ComparePlayersScreen({super.key});

  @override
  State<ComparePlayersScreen> createState() => _ComparePlayersScreenState();
}

class _ComparePlayersScreenState extends State<ComparePlayersScreen> {
  static const _teal = Color(0xFF00695C);

  final _controllerA = TextEditingController();
  final _controllerB = TextEditingController();
  GlobalPlayer? _playerA;
  GlobalPlayer? _playerB;

  bool _loadingResult = false;
  PlayerStat? _statA;
  PlayerStat? _statB;
  HeadToHead? _headToHead;
  MatchupDelta? _matchupAvsB; // A batting against B bowling
  MatchupDelta? _matchupBvsA; // B batting against A bowling

  @override
  void dispose() {
    _controllerA.dispose();
    _controllerB.dispose();
    super.dispose();
  }

  bool get _canCompare => _playerA != null && _playerB != null && _playerA!.id != _playerB!.id;

  Future<void> _compare() async {
    if (!_canCompare) return;
    setState(() => _loadingResult = true);
    final results = await Future.wait([
      StorageService.loadCareerStats(_playerA!.id, _playerA!.name),
      StorageService.loadCareerStats(_playerB!.id, _playerB!.name),
      StorageService.loadHeadToHead(_playerA!.id, _playerB!.id),
      StorageService.loadMatchup(_playerA!.id, _playerB!.id),
      StorageService.loadMatchup(_playerB!.id, _playerA!.id),
    ]);
    if (!mounted) return;
    setState(() {
      _statA = results[0] as PlayerStat?;
      _statB = results[1] as PlayerStat?;
      _headToHead = results[2] as HeadToHead;
      _matchupAvsB = results[3] as MatchupDelta?;
      _matchupBvsA = results[4] as MatchupDelta?;
      _loadingResult = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F5),
      appBar: AppBar(title: Text(tr('compare_players_title')), backgroundColor: _teal, foregroundColor: Colors.white),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: PlayerAutocompleteField(
                    controller: _controllerA,
                    labelText: tr('player_a_label'),
                    onExistingSelected: (p) => setState(() => _playerA = p),
                  ),
                ),
                const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('vs', style: TextStyle(fontWeight: FontWeight.bold))),
                Expanded(
                  child: PlayerAutocompleteField(
                    controller: _controllerB,
                    labelText: tr('player_b_label'),
                    onExistingSelected: (p) => setState(() => _playerB = p),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _teal, padding: const EdgeInsets.symmetric(vertical: 14)),
              onPressed: _canCompare ? _compare : null,
              child: Text(tr('compare')),
            ),
            if (_loadingResult) const Padding(padding: EdgeInsets.only(top: 32), child: Center(child: CircularProgressIndicator(color: _teal))),
            if (!_loadingResult && _statA != null && _statB != null) ...[
              const SizedBox(height: 24),
              _HeadToHeadCard(playerA: _playerA!, playerB: _playerB!, h2h: _headToHead!),
              if ((_matchupAvsB != null && _matchupAvsB!.balls > 0) || (_matchupBvsA != null && _matchupBvsA!.balls > 0)) ...[
                const SizedBox(height: 16),
                _PlayerBattleCard(
                  playerA: _playerA!,
                  playerB: _playerB!,
                  aBattingVsB: _matchupAvsB,
                  bBattingVsA: _matchupBvsA,
                ),
              ],
              const SizedBox(height: 16),
              _ComparisonTable(
                title: 'Batting',
                nameA: _playerA!.name,
                nameB: _playerB!.name,
                rows: [
                  ('Matches', '${_statA!.matches}', '${_statB!.matches}'),
                  ('Runs', '${_statA!.runs}', '${_statB!.runs}'),
                  ('Average', _statA!.avg < 0 ? '-' : _statA!.avg.toStringAsFixed(2), _statB!.avg < 0 ? '-' : _statB!.avg.toStringAsFixed(2)),
                  ('Strike Rate', _statA!.sr.toStringAsFixed(2), _statB!.sr.toStringAsFixed(2)),
                  ('Highest Score', '${_statA!.highestScore}', '${_statB!.highestScore}'),
                  ('100s / 50s', '${_statA!.hundreds}/${_statA!.fifties}', '${_statB!.hundreds}/${_statB!.fifties}'),
                ],
              ),
              const SizedBox(height: 16),
              _ComparisonTable(
                title: 'Bowling',
                nameA: _playerA!.name,
                nameB: _playerB!.name,
                rows: [
                  ('Wickets', '${_statA!.wickets}', '${_statB!.wickets}'),
                  ('Economy', _statA!.oversBowled > 0 ? _statA!.econ.toStringAsFixed(2) : '-', _statB!.oversBowled > 0 ? _statB!.econ.toStringAsFixed(2) : '-'),
                  ('Bowling Average', _statA!.wickets > 0 ? _statA!.bowlAvg.toStringAsFixed(2) : '-', _statB!.wickets > 0 ? _statB!.bowlAvg.toStringAsFixed(2) : '-'),
                  ('Best Bowling', _statA!.wickets > 0 ? _statA!.bestBowling : '-', _statB!.wickets > 0 ? _statB!.bestBowling : '-'),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HeadToHeadCard extends StatelessWidget {
  final GlobalPlayer playerA;
  final GlobalPlayer playerB;
  final HeadToHead h2h;

  const _HeadToHeadCard({required this.playerA, required this.playerB, required this.h2h});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.people_alt, size: 16, color: Color(0xFF00695C)),
              const SizedBox(width: 6),
              Text(tr('head_to_head'), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey.shade700)),
            ],
          ),
          const SizedBox(height: 10),
          if (h2h.opponentMatches == 0 && h2h.teammateMatches == 0)
            Text(
              "${playerA.name} and ${playerB.name} haven't played in the same synced match yet.",
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            )
          else ...[
            Text(
              'Faced each other in ${h2h.opponentMatches} ${h2h.opponentMatches == 1 ? 'match' : 'matches'}'
              '${h2h.teammateMatches > 0 ? ' (also teammates in ${h2h.teammateMatches})' : ''}.',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            if (h2h.opponentMatches > 0) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  _winStat(playerA.name, h2h.playerAWins, const Color(0xFF16A34A)),
                  const SizedBox(width: 8),
                  _winStat(playerB.name, h2h.playerBWins, const Color(0xFF0284C7)),
                  if (h2h.undecidedMatches > 0) ...[const SizedBox(width: 8), _winStat('Tied/No result', h2h.undecidedMatches, Colors.grey)],
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _winStat(String label, int count, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(10)),
        child: Column(
          children: [
            Text('$count', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: color)),
            Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: 10.5, color: Colors.grey.shade700), overflow: TextOverflow.ellipsis, maxLines: 1),
          ],
        ),
      ),
    );
  }
}

class _PlayerBattleCard extends StatelessWidget {
  final GlobalPlayer playerA;
  final GlobalPlayer playerB;
  final MatchupDelta? aBattingVsB; // A's record batting against B bowling
  final MatchupDelta? bBattingVsA; // B's record batting against A bowling

  const _PlayerBattleCard({required this.playerA, required this.playerB, required this.aBattingVsB, required this.bBattingVsA});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.sports_kabaddi, size: 16, color: Color(0xFF00695C)),
              const SizedBox(width: 6),
              Text(tr('player_battle'), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey.shade700)),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 10),
            child: Text(
              'Ball-by-ball only counts from matches played and synced after this feature was added.',
              style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500, fontStyle: FontStyle.italic),
            ),
          ),
          if (aBattingVsB != null && aBattingVsB!.balls > 0) _matchupRow(battingName: playerA.name, bowlingName: playerB.name, m: aBattingVsB!),
          if (aBattingVsB != null && aBattingVsB!.balls > 0 && bBattingVsA != null && bBattingVsA!.balls > 0) const Divider(height: 20),
          if (bBattingVsA != null && bBattingVsA!.balls > 0) _matchupRow(battingName: playerB.name, bowlingName: playerA.name, m: bBattingVsA!),
        ],
      ),
    );
  }

  Widget _matchupRow({required String battingName, required String bowlingName, required MatchupDelta m}) {
    final sr = m.balls > 0 ? (m.runs / m.balls) * 100 : 0.0;
    final avg = m.dismissals > 0 ? m.runs / m.dismissals : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$battingName vs $bowlingName', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 8),
        Row(
          children: [
            _battleStat('Runs', '${m.runs}'),
            _battleStat('Balls', '${m.balls}'),
            _battleStat('Dismissals', '${m.dismissals}'),
            _battleStat('Average', avg == null ? '-' : avg.toStringAsFixed(1)),
            _battleStat('SR', sr.toStringAsFixed(1)),
          ],
        ),
      ],
    );
  }

  Widget _battleStat(String label, String value) {
    return Expanded(
      child: Column(
        children: [
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF00695C))),
          Text(label, style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
        ],
      ),
    );
  }
}

class _ComparisonTable extends StatelessWidget {
  final String title;
  final String nameA;
  final String nameB;
  final List<(String, String, String)> rows;

  const _ComparisonTable({required this.title, required this.nameA, required this.nameB, required this.rows});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(color: Color(0xFFE0F2F1), borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
            child: Row(
              children: [
                Expanded(flex: 2, child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF00695C)))),
                Expanded(child: Text(nameA, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12), overflow: TextOverflow.ellipsis)),
                Expanded(child: Text(nameB, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12), overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
          ...rows.map((r) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Expanded(flex: 2, child: Text(r.$1, style: TextStyle(fontSize: 13, color: Colors.grey.shade700))),
                    Expanded(child: Text(r.$2, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
                    Expanded(child: Text(r.$3, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
                  ],
                ),
              )),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}
