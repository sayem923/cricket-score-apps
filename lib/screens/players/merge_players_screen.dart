import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../services/storage_service.dart';
import '../../l10n/app_strings.dart';
import '../../utils/extensions.dart';

/// Duplicate resolver: pick a primary player and one or more duplicates,
/// preview the combined totals, then merge. Irreversible - old ids become
/// aliases and stop appearing in search (see merge_players in
/// player_registry_schema.sql).
class MergePlayersScreen extends StatefulWidget {
  const MergePlayersScreen({super.key});

  @override
  State<MergePlayersScreen> createState() => _MergePlayersScreenState();
}

class _MergePlayersScreenState extends State<MergePlayersScreen> {
  GlobalPlayer? _primary;
  final Set<GlobalPlayer> _duplicates = {};
  PlayerStat? _primaryStats;
  final Map<String, PlayerStat> _duplicateStats = {};
  bool _merging = false;

  Future<void> _pickPrimary() async {
    final picked = await _searchAndPick(title: 'Choose the player to keep');
    if (picked == null) return;
    final stats = await StorageService.loadCareerStats(picked.id, picked.name);
    setState(() {
      _primary = picked;
      _primaryStats = stats;
      _duplicates.remove(picked);
      _duplicateStats.remove(picked.id);
    });
  }

  Future<void> _addDuplicate() async {
    final picked = await _searchAndPick(title: 'Choose a duplicate to merge away');
    if (picked == null || picked.id == _primary?.id) return;
    final stats = await StorageService.loadCareerStats(picked.id, picked.name);
    setState(() {
      _duplicates.add(picked);
      if (stats != null) _duplicateStats[picked.id] = stats;
    });
  }

  Future<GlobalPlayer?> _searchAndPick({required String title}) async {
    return showDialog<GlobalPlayer>(
      context: context,
      builder: (context) => _PlayerPickerDialog(title: title),
    );
  }

  PlayerStat get _combinedPreview {
    final combined = PlayerStat(name: _primary?.name ?? '');
    if (_primaryStats != null) combined.mergeWith(_primaryStats!);
    for (final s in _duplicateStats.values) {
      combined.mergeWith(s);
    }
    return combined;
  }

  Future<void> _confirmMerge() async {
    if (_primary == null || _duplicates.isEmpty) return;
    final typedController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final matches = typedController.text.trim() == _primary!.name;
          return AlertDialog(
            title: Text(tr('merge_players_confirm_title')),
            // Wrapped in SingleChildScrollView: the confirmation field is
            // autofocus:true, so the keyboard opens immediately - without
            // this the dialog had no room to shrink and overflowed.
            content: SingleChildScrollView(
              child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_duplicates.map((p) => '"${p.name}"').join(', ')} will be merged into '
                  '"${_primary!.name}". All stats will be combined and the duplicate names will '
                  "no longer appear separately. This can't be undone.",
                ),
                const SizedBox(height: 16),
                Text(tr('type_name_to_confirm').replaceFirst('%s', _primary!.name), style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                TextField(
                  controller: typedController,
                  autofocus: true,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                  onChanged: (_) => setDialogState(() {}),
                ),
              ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('cancel_word'))),
              TextButton(
                onPressed: matches ? () => Navigator.pop(context, true) : null,
                child: Text(tr('merge'), style: const TextStyle(color: Colors.red)),
              ),
            ],
          );
        },
      ),
    );
    if (confirmed != true) return;

    setState(() => _merging = true);
    try {
      await StorageService.mergeGlobalPlayers(
        primaryId: _primary!.id,
        duplicateIds: _duplicates.map((p) => p.id).toList(),
      );
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      // Surfaced as-is (not a generic "something went wrong") so a
      // non-admin blocked server-side sees exactly why: "Only admins can
      // merge players" from the merge_players_admin_gated RPC.
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr('merge_failed')),
          content: SingleChildScrollView(child: Text('$e')),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('ok')))],
        ),
      );
    } finally {
      if (mounted) setState(() => _merging = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final combined = (_primary != null && _duplicates.isNotEmpty) ? _combinedPreview : null;
    return Scaffold(
      appBar: AppBar(title: Text(tr('merge_duplicate_players_title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            tileColor: Colors.grey.shade100,
            title: Text(_primary?.name ?? tr('choose_player_to_keep')),
            subtitle: Text(tr('primary_kept')),
            trailing: const Icon(Icons.edit),
            onTap: _pickPrimary,
          ),
          const SizedBox(height: 12),
          ..._duplicates.map((p) => ListTile(
                title: Text(p.name),
                subtitle: Text(tr('duplicate_will_be_merged')),
                trailing: IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => setState(() {
                    _duplicates.remove(p);
                    _duplicateStats.remove(p.id);
                  }),
                ),
              )),
          OutlinedButton.icon(
            onPressed: _primary == null ? null : _addDuplicate,
            icon: const Icon(Icons.add),
            label: Text(tr('add_duplicate_to_merge')),
          ),
          if (combined != null) ...[
            const SizedBox(height: 24),
            Text(tr('combined_preview'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _PreviewRow('Runs', '${combined.runs}'),
            _PreviewRow('Innings', '${combined.innings}'),
            _PreviewRow('Wickets', '${combined.wickets}'),
            _PreviewRow('Fours / Sixes', '${combined.fours} / ${combined.sixes}'),
            _PreviewRow('Highest Score (best-of)', '${combined.highestScore}'),
            _PreviewRow('Best Bowling (best-of)', combined.bestBowling),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: (_primary != null && _duplicates.isNotEmpty && !_merging) ? _confirmMerge : null,
            child: _merging ? const CircularProgressIndicator() : Text(tr('merge')),
          ),
        ],
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  final String label;
  final String value;
  const _PreviewRow(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [Text(label), Text(value, style: const TextStyle(fontWeight: FontWeight.w600))],
        ),
      );
}

class _PlayerPickerDialog extends StatefulWidget {
  final String title;
  const _PlayerPickerDialog({required this.title});

  @override
  State<_PlayerPickerDialog> createState() => _PlayerPickerDialogState();
}

class _PlayerPickerDialogState extends State<_PlayerPickerDialog> {
  List<GlobalPlayer> _results = [];

  Future<void> _search(String query) async {
    final results = await StorageService.searchGlobalPlayers(query);
    if (mounted) setState(() => _results = results);
  }

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 320,
        height: 360,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: InputDecoration(labelText: tr('search_player')),
              onChanged: _search,
            ),
            Expanded(
              child: ListView.builder(
                itemCount: _results.length,
                itemBuilder: (context, index) {
                  final p = _results[index];
                  return ListTile(
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: const Color(0xFFE0F2F1),
                      backgroundImage: p.photoUrl != null ? NetworkImage(p.photoUrl!) : null,
                      child: p.photoUrl == null ? const Icon(Icons.person, size: 16, color: Color(0xFF00695C)) : null,
                    ),
                    title: Text(p.name),
                    onTap: () => Navigator.pop(context, p),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('cancel_word')))],
    );
  }
}
