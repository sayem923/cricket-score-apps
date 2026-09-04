import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../services/storage_service.dart';
import '../../widgets/player_autocomplete_field.dart';
import '../../l10n/app_strings.dart';
import 'match_scorer_screen.dart';

class StartMatchScreen extends StatefulWidget {
  final String? initialTeamA;
  final String? initialTeamB;
  final Function(MatchResultData)? onMatchComplete;
  // Tournament mode only - forwarded straight through to MatchScorerScreen's
  // ball-by-ball crash-recovery autosave. See its doc comment for details.
  final Function(MatchResultData result, bool isOverBoundary)? onProgressUpdate;
  // Tournament mode only - forwarded straight through to MatchScorerScreen,
  // purely so "Go Live" can tag the broadcast with which tournament it's
  // part of (see LiveBroadcast.tournamentId).
  final String? tournamentId;

  const StartMatchScreen({super.key, this.initialTeamA, this.initialTeamB, this.onMatchComplete, this.onProgressUpdate, this.tournamentId});

  @override
  State<StartMatchScreen> createState() => _StartMatchScreenState();
}

class _StartMatchScreenState extends State<StartMatchScreen> {
  final TextEditingController _teamAController = TextEditingController();
  final TextEditingController _teamBController = TextEditingController();
  final TextEditingController _oversController = TextEditingController(text: "5");
  final TextEditingController _playersController = TextEditingController(text: "11");
   
  // Squad Lists
  List<Player> squadA = [];
  List<Player> squadB = [];
   
  // Selected Players
  Player? selectedStriker;
  Player? selectedNonStriker;
  Player? selectedBowler;

  List<String> _savedTeams = [];
  final Set<TextEditingController> _autocompleteListenersAttached = {};

  @override
  void initState() {
    super.initState();
    if (widget.initialTeamA != null) _teamAController.text = widget.initialTeamA!;
    if (widget.initialTeamB != null) _teamBController.text = widget.initialTeamB!;

    // Generate default squads initially
    _generateDefaultSquads();
    _loadSavedTeams();

    // Auto-load whichever team names are already sitting in the fields -
    // covers tournament mode (name passed in via widget.initialTeamA/B)
    // AND the plain "Quick Match" defaults ("India"/"Australia" prefilled
    // above): if the scorer reuses the same team names and never actually
    // retypes/reselects an already-correct field, onEditingComplete/
    // onSelected below would otherwise never fire for it, and the saved
    // squad would silently never load. _autoApplySavedSquad is a no-op
    // when there's nothing saved yet, so this is safe to always attempt.
    _autoApplySavedSquad(isTeamA: true);
    _autoApplySavedSquad(isTeamA: false);
  }

  Future<void> _loadSavedTeams() async {
    final teams = await StorageService.loadTeams();
    if (!mounted) return;
    setState(() => _savedTeams = teams);
  }
   
  void _generateDefaultSquads() {
    int count = int.tryParse(_playersController.text) ?? 11;
    squadA = List.generate(count, (i) => Player(name: "A-Player ${i+1}", id: "A$i"));
    squadB = List.generate(count, (i) => Player(name: "B-Player ${i+1}", id: "B$i"));
    
    // Set defaults
    if(squadA.length >= 2) {
      selectedStriker = squadA[0];
      selectedNonStriker = squadA[1];
    }
    if(squadB.isNotEmpty) {
      selectedBowler = squadB[0];
    }
  }
   
  // Fresh local ids only - a saved roster's ids from a PAST match don't
  // mean anything here, only the names do (same reasoning as
  // _generateDefaultSquads/_resizeSquad's "A$i"-style ids). Keeps this
  // squad's ids consistent with how every other squad in this screen is
  // built, so equality checks against selectedStriker/selectedNonStriker/
  // selectedBowler keep working normally afterwards.
  List<Player> _withFreshIds(List<Player> roster, String prefix) {
    return List.generate(
      roster.length,
      (i) => Player(name: roster[i].name, id: "${prefix}_saved_${DateTime.now().microsecondsSinceEpoch}_$i"),
    );
  }

  // Team name this squad was last auto-loaded for, so an unrelated
  // rebuild (e.g. typing overs) or a second onEditingComplete on the same
  // settled name doesn't keep silently stomping over names the scorer has
  // since hand-edited via "Manage Squad" for THIS match. Only a genuine
  // team-name change re-triggers the auto-load.
  String? _lastAutoLoadedTeamA;
  String? _lastAutoLoadedTeamB;

  // Silently applies that team's remembered squad (see
  // StorageService.saveTeamRoster, written automatically at the end of
  // every match) as soon as its name is confirmed - autocomplete
  // selection, or finishing typing it - instead of requiring a manual
  // "Load Saved Squad" tap. A player only drops out of that remembered
  // squad if the scorer themselves renames/removes them in some later
  // match (which re-saves the roster with that change); until then, the
  // same XI keeps coming back automatically for this team name.
  // Silently applies that team's remembered squad (see
  // StorageService.saveTeamRoster, written automatically at the end of
  // every match) as soon as its name is confirmed - autocomplete
  // selection, or finishing typing it. A player only drops out of that
  // remembered squad if the scorer themselves renames/removes them in
  // some later match (which re-saves the roster with that change); until
  // then, the same XI keeps coming back automatically for this team name.
  Future<void> _autoApplySavedSquad({required bool isTeamA}) async {
    final teamController = isTeamA ? _teamAController : _teamBController;
    final teamName = teamController.text.trim();
    if (teamName.isEmpty) return;
    final lastLoaded = isTeamA ? _lastAutoLoadedTeamA : _lastAutoLoadedTeamB;
    if (lastLoaded != null && lastLoaded.toLowerCase() == teamName.toLowerCase()) return;
    final roster = await StorageService.loadTeamRoster(teamName);
    if (!mounted) return;
    // No saved roster yet for this name (brand new team) - leave the
    // placeholder "A-Player 1" squad exactly as is, no interruption.
    if (roster == null || roster.isEmpty) return;
    setState(() {
      if (isTeamA) {
        _lastAutoLoadedTeamA = teamName;
        squadA = _withFreshIds(roster, "A");
        if (squadA.length >= 2) {
          selectedStriker = squadA[0];
          selectedNonStriker = squadA[1];
        } else {
          selectedStriker = squadA.isNotEmpty ? squadA[0] : null;
          selectedNonStriker = null;
        }
      } else {
        _lastAutoLoadedTeamB = teamName;
        squadB = _withFreshIds(roster, "B");
        selectedBowler = squadB.isNotEmpty ? squadB[0] : null;
      }
      // Keep "Players per Team" in sync so it isn't left showing a stale
      // count (e.g. still "11" after loading a saved 6-a-side squad).
      final loadedCount = isTeamA ? squadA.length : squadB.length;
      if (int.tryParse(_playersController.text) != loadedCount) {
        _playersController.text = "$loadedCount";
      }
    });
  }

  void _updateSquadSize() {
    int newCount = int.tryParse(_playersController.text) ?? 11;
    if (newCount <= 0) return;
    setState(() {
      _resizeSquad(squadA, newCount, "A");
      _resizeSquad(squadB, newCount, "B");
      // Re-point openers to valid players if the squad shrank past their index.
      if (!squadA.contains(selectedStriker)) selectedStriker = squadA.isNotEmpty ? squadA[0] : null;
      if (!squadA.contains(selectedNonStriker)) selectedNonStriker = squadA.length > 1 ? squadA[1] : null;
      if (!squadB.contains(selectedBowler)) selectedBowler = squadB.isNotEmpty ? squadB[0] : null;
    });
  }

  // Grows or shrinks a squad to [newCount] players without touching the
  // names/ids of players that already exist (previously any size change
  // wiped out every custom-edited name). [prefix] ("A"/"B") keeps default
  // names distinguishable between the two squads - see the note on
  // StorageService._isDefaultPlayerName for why that matters.
  void _resizeSquad(List<Player> squad, int newCount, String prefix) {
    if (squad.length < newCount) {
      for (int i = squad.length; i < newCount; i++) {
        squad.add(Player(name: "$prefix-Player ${i + 1}", id: "${prefix}_new_${DateTime.now().millisecondsSinceEpoch}_$i"));
      }
    } else if (squad.length > newCount) {
      squad.removeRange(newCount, squad.length);
    }
  }
   
  // Two DIFFERENT real people can genuinely share a name across the two
  // teams (e.g. two separate "Rahim"s) - since the shared registry can
  // only key on name, that has to be caught at squad-editing time and one
  // of them renamed distinctly, or they'd silently merge into "the same
  // player" once this match syncs. Case-insensitive to match how
  // StorageService.findOrCreateGlobalPlayer itself looks players up
  // (.ilike), and default-generated names ("A-Player 3" etc) are exempt -
  // those never reach the registry at all (see
  // StorageService._isDefaultPlayerName), so duplicates among them are
  // harmless.
  bool _isDuplicateNameInMatch(String name, Player excluding) {
    final normalized = name.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    for (final p in [...squadA, ...squadB]) {
      if (p == excluding) continue;
      if (p.name.trim().toLowerCase() == normalized) return true;
    }
    return false;
  }

  void _showSquadEditor(List<Player> squad, String teamName) {
    showDialog(context: context, builder: (context) => StatefulBuilder(builder: (context, setStateDialog) {
       return AlertDialog(
         title: Text(tr('manage_squad_title').replaceFirst('%s', teamName)),
         content: SizedBox(
           width: double.maxFinite,
           height: MediaQuery.of(context).size.height * 0.5,
           child: ListView.builder(
             itemCount: squad.length,
             itemBuilder: (context, index) {
               return ListTile(
                 title: Text(squad[index].name),
                 subtitle: (squad[index].role != null && squad[index].role!.isNotEmpty)
                     ? Text(squad[index].role!, style: const TextStyle(fontSize: 12, color: Colors.grey))
                     : null,
                 trailing: Row(
                   mainAxisSize: MainAxisSize.min,
                   children: [
                     IconButton(icon: const Icon(Icons.edit, size: 18), onPressed: () async {
                       TextEditingController ec = TextEditingController(text: squad[index].name);
                       String? selectedRole = squad[index].role;
                       final saved = await showDialog<bool>(
                         context: context,
                         builder: (ctx) => StatefulBuilder(builder: (ctx, setStateEdit) => AlertDialog(
                           title: Text(tr('edit_name')),
                           content: SingleChildScrollView(
                             child: Column(
                             mainAxisSize: MainAxisSize.min,
                             crossAxisAlignment: CrossAxisAlignment.start,
                             children: [
                               // Suggests existing registry names as the user types, purely
                               // to steer them away from typo'ing a fresh duplicate - the
                               // actual registry write only happens once this match syncs
                               // to the cloud (see StorageService.registerMatchPlayers),
                               // not here.
                               PlayerAutocompleteField(controller: ec),
                               const SizedBox(height: 12),
                               // Purely descriptive - shown as a tag under this player's
                               // photo on the broadcast "Playing XI" card (see
                               // BroadcastPlayingXI.roles / _PlayingXIPlayerTile). Optional:
                               // "None" leaves the card showing just the name, same as
                               // before this field existed.
                               DropdownButtonFormField<String?>(
                                 value: (selectedRole != null && kPlayerRoles.contains(selectedRole)) ? selectedRole : null,
                                 decoration: InputDecoration(labelText: tr('role_optional_label'), isDense: true),
                                 items: [
                                   DropdownMenuItem<String?>(value: null, child: Text(tr('none'))),
                                   ...kPlayerRoles.map((r) => DropdownMenuItem<String?>(value: r, child: Text(r))),
                                 ],
                                 onChanged: (v) => setStateEdit(() => selectedRole = v),
                               ),
                               // Two DIFFERENT real people can genuinely share a name (two
                               // different "Rahim"s on opposite teams) - since the shared
                               // registry can only key on name, that has to be caught here
                               // and one of them renamed distinctly, or they'd silently
                               // become "the same player" once this match syncs.
                               ValueListenableBuilder<TextEditingValue>(
                                 valueListenable: ec,
                                 builder: (context, value, _) {
                                   if (!_isDuplicateNameInMatch(value.text, squad[index])) return const SizedBox.shrink();
                                   return Padding(
                                     padding: const EdgeInsets.only(top: 8),
                                     child: Text(
                                       tr('duplicate_name_warning'),
                                       style: const TextStyle(color: Colors.red, fontSize: 12),
                                     ),
                                   );
                                 },
                               ),
                             ],
                             ),
                           ),
                           actions: [
                             TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel_word'))),
                             ValueListenableBuilder<TextEditingValue>(
                               valueListenable: ec,
                               builder: (context, value, _) {
                                 final blocked = value.text.trim().isEmpty || _isDuplicateNameInMatch(value.text, squad[index]);
                                 return TextButton(
                                   onPressed: blocked ? null : () => Navigator.pop(ctx, true),
                                   child: Text(tr('ok')),
                                 );
                               },
                             ),
                           ],
                         ),
                       ));
                       if (saved == true) {
                         setStateDialog(() {
                           squad[index].name = ec.text.trim();
                           squad[index].role = selectedRole;
                         });
                       }
                     }),
                     IconButton(icon: const Icon(Icons.delete, size: 18, color: Colors.red), onPressed: () {
                       setStateDialog(() => squad.removeAt(index));
                     }),
                   ],
                 ),
               );
             },
           ),
         ),
         actions: [
            TextButton(onPressed: () {
               setStateDialog(() => squad.add(Player(name: tr('new_player_default_name'), id: "${teamName}_${DateTime.now().millisecondsSinceEpoch}")));
            }, child: Text(tr('add_player_caps').toUpperCase())),
            TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('done_caps').toUpperCase())),
         ],
       );
    }));
  }

  Widget _teamField({required TextEditingController controller, required String label, required IconData icon, required bool readOnly, required bool isTeamA}) {
    if (readOnly || _savedTeams.isEmpty) {
      return TextField(
        controller: controller,
        readOnly: readOnly,
        decoration: InputDecoration(labelText: label, hintText: tr('enter_team_name_hint'), prefixIcon: Icon(icon)),
        // Auto-loads that team's remembered squad the moment a name is
        // typed and confirmed (Enter/Done) - see _autoApplySavedSquad.
        // Skipped for readOnly (tournament mode already auto-loads both
        // teams once in initState, since there's no field here to type
        // into).
        onEditingComplete: readOnly ? null : () => _autoApplySavedSquad(isTeamA: isTeamA),
      );
    }
    return Autocomplete<String>(
      initialValue: TextEditingValue(text: controller.text),
      optionsBuilder: (value) {
        if (value.text.isEmpty) return _savedTeams;
        return _savedTeams.where((t) => t.toLowerCase().contains(value.text.toLowerCase()));
      },
      onSelected: (sel) {
        controller.text = sel;
        // Picking an existing team from the dropdown is the most common
        // path to a name that actually HAS a saved squad, so auto-load
        // right on selection rather than waiting for a separate submit.
        _autoApplySavedSquad(isTeamA: isTeamA);
      },
      fieldViewBuilder: (context, fieldController, focusNode, onFieldSubmitted) {
        if (_autocompleteListenersAttached.add(fieldController)) {
          fieldController.addListener(() => controller.text = fieldController.text);
        }
        return TextField(
          controller: fieldController,
          focusNode: focusNode,
          decoration: InputDecoration(labelText: label, hintText: tr('enter_team_name_hint'), prefixIcon: Icon(icon)),
          onEditingComplete: () {
            onFieldSubmitted();
            _autoApplySavedSquad(isTeamA: isTeamA);
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    bool isTournamentMode = widget.initialTeamA != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('new_match_setup_title')),
        backgroundColor: const Color(0xFF00695C),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr('team_match_info'), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: _teamField(controller: _teamAController, label: tr('batting_team_label'), icon: Icons.sports_cricket, readOnly: isTournamentMode, isTeamA: true)),
                const SizedBox(width: 16),
                Expanded(child: _teamField(controller: _teamBController, label: tr('bowling_team_label'), icon: Icons.sports_baseball, readOnly: isTournamentMode, isTeamA: false)),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: TextField(controller: _oversController, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: tr('overs_label'), prefixIcon: const Icon(Icons.timer)))),
                const SizedBox(width: 16),
                Expanded(child: TextField(controller: _playersController, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: tr('players_per_team_label'), prefixIcon: const Icon(Icons.group)), onChanged: (v) => _updateSquadSize())),
              ],
            ),
             
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                  ElevatedButton(onPressed: () => _showSquadEditor(squadA, tr('batting_team_label')), child: Text(tr('batting_squad_btn'))),
                  ElevatedButton(onPressed: () => _showSquadEditor(squadB, tr('bowling_team_label')), child: Text(tr('bowling_squad_btn'))),
              ],
            ),
            const SizedBox(height: 32),
            Text(tr('opening_players'), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
            const SizedBox(height: 16),
             
            DropdownButtonFormField<Player>(
              value: selectedStriker,
              decoration: InputDecoration(labelText: tr('striker_label'), prefixIcon: const Icon(Icons.person)),
              items: squadA.map((p) => DropdownMenuItem(value: p, child: Text(p.name))).toList(),
              onChanged: (v) => setState(() => selectedStriker = v),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<Player>(
              value: selectedNonStriker,
              decoration: InputDecoration(labelText: tr('non_striker_label'), prefixIcon: const Icon(Icons.person_outline)),
              items: squadA.map((p) => DropdownMenuItem(value: p, child: Text(p.name))).toList(),
              onChanged: (v) => setState(() => selectedNonStriker = v),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<Player>(
              value: selectedBowler,
              decoration: InputDecoration(labelText: tr('opening_bowler_label'), prefixIcon: const Icon(Icons.sports)),
              items: squadB.map((p) => DropdownMenuItem(value: p, child: Text(p.name))).toList(),
              onChanged: (v) => setState(() => selectedBowler = v),
            ),

            const SizedBox(height: 40),
            ElevatedButton(
              onPressed: () {
                // Team name fields no longer default to "India"/"Australia"
                // (see change above) - now that blank is possible, guard
                // against starting a match with an unnamed team instead of
                // silently proceeding.
                if (_teamAController.text.trim().isEmpty || _teamBController.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('enter_both_team_names'))));
                  return;
                }
                // BUG FIX: both teams could be given the exact same name
                // (e.g. "India" batting vs "India" bowling), which then
                // corrupted everything downstream that keys off team name
                // (saved squads, stats, tournament tables, the live
                // scorecard). Compared case-insensitively + trimmed so
                // "India" vs "india " is still caught as a duplicate.
                if (_teamAController.text.trim().toLowerCase() == _teamBController.text.trim().toLowerCase()) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('teams_cant_have_same_name'))));
                  return;
                }
                if (selectedStriker == null || selectedNonStriker == null || selectedBowler == null) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('select_all_openers'))));
                  return;
                }
                if (selectedStriker == selectedNonStriker) {
                   ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('striker_nonstriker_cant_be_same'))));
                   return;
                }

                StorageService.addTeamIfNew(_teamAController.text);
                StorageService.addTeamIfNew(_teamBController.text);

                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (context) => MatchScorerScreen(
                      teamA: _teamAController.text,
                      teamB: _teamBController.text,
                      maxOvers: int.tryParse(_oversController.text) ?? 5,
                      playersPerTeam: squadA.length,
                      strikerName: selectedStriker!.name,
                      nonStrikerName: selectedNonStriker!.name,
                      bowlerName: selectedBowler!.name,
                       
                      // PASSING SQUADS
                      initialSquadA: squadA,
                      initialSquadB: squadB,
                       
                      onMatchComplete: widget.onMatchComplete,
                      onProgressUpdate: widget.onProgressUpdate,
                      tournamentId: widget.tournamentId,
                    ),
                  ),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00695C),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(tr('start_match_caps').toUpperCase()),
            ),
          ],
        ),
      ),
    );
  }
}