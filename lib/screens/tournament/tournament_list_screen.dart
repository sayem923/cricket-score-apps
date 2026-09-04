import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../utils/globals.dart';
import '../../services/storage_service.dart';
import 'tournament_dashboard.dart';
import '../../l10n/app_strings.dart';

class TournamentListScreen extends StatefulWidget {
  const TournamentListScreen({super.key});

  @override
  State<TournamentListScreen> createState() => _TournamentListScreenState();
}

class _TournamentListScreenState extends State<TournamentListScreen> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadIfNeeded();
  }

  Future<void> _loadIfNeeded() async {
    // Only hit storage once per app session - globalTournaments already
    // reflects the latest state after that (kept as an in-memory cache,
    // written back to storage on every mutation).
    if (!globalTournamentsLoaded) {
      final loaded = await StorageService.loadTournaments();
      globalTournaments = loaded;
      globalTournamentsLoaded = true;
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  void _showCreateTournamentDialog() {
    TextEditingController nameCtrl = TextEditingController();
    int numberOfTeams = 2;
    List<TextEditingController> teamControllers = [TextEditingController(), TextEditingController()];

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(builder: (context, setStateDialog) {
          return AlertDialog(
            title: Text(tr('create_tournament')),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(controller: nameCtrl, decoration: InputDecoration(labelText: tr('tournament_name_label'))),
                    const SizedBox(height: 16),
                    Row(children: [
                      Text(tr('number_of_teams') + ' '),
                      DropdownButton<int>(
                        value: numberOfTeams,
                        items: List.generate(15, (index) => index + 2).map((e) => DropdownMenuItem(value: e, child: Text("$e"))).toList(),
                        onChanged: (val) {
                          setStateDialog(() {
                            numberOfTeams = val!;
                            if (teamControllers.length < numberOfTeams) {
                              for (int i = teamControllers.length; i < numberOfTeams; i++) teamControllers.add(TextEditingController());
                            } else {
                              teamControllers = teamControllers.sublist(0, numberOfTeams);
                            }
                          });
                        },
                      ),
                    ]),
                    const SizedBox(height: 10),
                    ...List.generate(numberOfTeams, (index) => Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: TextField(controller: teamControllers[index], decoration: InputDecoration(labelText: tr('team_n_name').replaceFirst('%s', '${index + 1}'), isDense: true)),
                    )),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('cancel').toUpperCase())),
              ElevatedButton(
                onPressed: () {
                  if (nameCtrl.text.isNotEmpty && teamControllers.every((c) => c.text.isNotEmpty)) {
                    setState(() {
                      globalTournaments.add(Tournament(name: nameCtrl.text, teams: teamControllers.map((c) => c.text).toList(), matches: []));
                    });
                    StorageService.saveTournaments(globalTournaments);
                    Navigator.pop(context);
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('fill_all_fields_teams'))));
                  }
                },
                child: Text(tr('create').toUpperCase()),
              )
            ],
          );
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('tournaments_title')), backgroundColor: const Color(0xFF00695C), foregroundColor: Colors.white),
      body: _loading
        ? const Center(child: CircularProgressIndicator())
        : globalTournaments.isEmpty
          ? Center(child: Text(tr('no_tournaments_yet'), style: TextStyle(color: Colors.grey[600])))
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: globalTournaments.length,
              itemBuilder: (context, index) => _buildTournamentItem(context, globalTournaments[index]),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showCreateTournamentDialog, icon: const Icon(Icons.add), label: Text(tr('create')), backgroundColor: const Color(0xFF00695C), foregroundColor: Colors.white,
      ),
    );
  }

  Widget _buildTournamentItem(BuildContext context, Tournament tournament) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: const CircleAvatar(backgroundColor: Color(0xFFE0F2F1), child: Icon(Icons.emoji_events, color: Color(0xFF00695C))),
        title: Text(tournament.name, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(tr('teams_matches_count').replaceFirst('%s', '${tournament.teams.length}').replaceFirst('%s', '${tournament.matches.length}')),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
        onTap: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (context) => TournamentDashboard(tournament: tournament)));
          // The dashboard mutates `tournament` in place and saves after each
          // change, but refresh the list view in case counts (e.g. match count) changed.
          if (mounted) setState(() {});
        },
      ),
    );
  }
}
