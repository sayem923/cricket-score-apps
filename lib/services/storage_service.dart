import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/models.dart';
import '../utils/extensions.dart';
import 'session_service.dart';

/// Persistence layer backed by Supabase (Postgres), scoped per logged-in
/// user via `user_id` (auth.uid()) - NOT a device id. Rules:
///
///  - Guest mode NEVER touches Supabase at all - everything (tournaments AND
///    quick matches) lives only in local shared_preferences on the device.
///  - Logged-in users: Tournament matches auto-save to the cloud on every
///    change (see saveTournaments, called from the tournament screens).
///  - Logged-in users: Quick matches are saved locally first and ONLY
///    reach the cloud when the person explicitly taps "Save to Cloud" on a
///    Match History item (or "Sync All") - never automatically.
///
/// DB shape (see SQL provided separately - RLS keyed on auth.uid() = user_id):
///   tournaments   (id text, user_id uuid, data jsonb, created_at, updated_at)
///   quick_matches (id text, user_id uuid, data jsonb, played_at)
class StorageService {
  static const _localTournamentsKey = 'cricket_scorer_local_tournaments_v1';
  static const _pendingQuickMatchesKey = 'cricket_scorer_pending_quick_matches_v1';
  static const _matchDraftKey = 'cricket_scorer_match_draft_v1';
  static const _savedTeamsKey = 'cricket_scorer_saved_teams_v1';
  // Maps team name -> that team's saved squad (List<Player> as JSON), so
  // "Load usual squad" on the next match with the same team name has
  // something to draw from even offline/guest, same as _savedTeamsKey does
  // for the plain name list. See saveTeamRoster/loadTeamRoster.
  static const _teamRostersKey = 'cricket_scorer_team_rosters_v1';
  // BUG FIX: the roster cache above used to be one single device-wide key,
  // not scoped to who was logged in. On a shared device, logging out of
  // Account A and into Account B meant Account B's "Load usual squad"
  // could silently return Account A's saved players the moment a team
  // name happened to match - a real data-leak between accounts on the
  // same phone. Every read/write of the roster cache now goes through
  // this account-scoped key instead: each logged-in account gets its own
  // bucket (by user id), and guest mode gets one shared bucket, matching
  // how guest data already works everywhere else in this file (device-
  // local, not account-specific, since there's no account to scope it to).
  static String get _scopedTeamRostersKey =>
      _isGuest ? '${_teamRostersKey}_guest' : '${_teamRostersKey}_${_userId ?? 'guest'}';
  // Set when a cloud saveTournaments() attempt fails while logged in (bad/
  // no network) so the change had to fall back to local-only. Cleared the
  // moment a later saveTournaments() call actually reaches the cloud - see
  // syncPendingTournaments, which ConnectivityService calls automatically
  // the moment the device comes back online. Deliberately tournament-only:
  // quick matches intentionally stay manual-sync-only (see class doc).
  static const _pendingTournamentSyncKey = 'cricket_scorer_pending_tournament_sync_v1';

  static SupabaseClient get _client => Supabase.instance.client;
  static bool get _isGuest => SessionService.isGuest.value;
  static String? get _userId => _client.auth.currentUser?.id;
  static bool get _hasCloudAccess => !_isGuest && _userId != null;

  // --- Tournaments (auto-saved to cloud when logged in) ---

  static Future<List<Tournament>> loadTournaments() async {
    if (!_hasCloudAccess) return _loadLocalTournaments();
    try {
      final rows = await _client.from('tournaments').select().eq('user_id', _userId!).order('created_at');
      return (rows as List).map((r) => Tournament.fromJson(r['data'] as Map<String, dynamic>)).toList();
    } catch (e, st) {
      debugPrint('[StorageService] loadTournaments failed: $e');
      debugPrint('$st');
      return [];
    }
  }

  static Future<bool> saveTournaments(List<Tournament> tournaments) async {
    if (tournaments.isEmpty) return true;
    if (!_hasCloudAccess) {
      await _saveLocalTournaments(tournaments);
      return true;
    }
    try {
      final rows = tournaments
          .map((t) => {
                'id': t.id,
                'user_id': _userId,
                'data': t.toJson(),
                'updated_at': DateTime.now().toIso8601String(),
              })
          .toList();
      await _client.from('tournaments').upsert(rows, onConflict: 'id');
      await _clearPendingTournamentSync();
      return true;
    } catch (e, st) {
      debugPrint('[StorageService] saveTournaments failed: $e');
      debugPrint('$st');
      // Cloud push failed (most likely offline/flaky network) - fall back
      // to a local save so the change isn't silently lost, and flag it so
      // ConnectivityService retries automatically once back online (or the
      // person can trigger TournamentSyncStatusBanner's manual retry).
      await _saveLocalTournaments(tournaments);
      await _markPendingTournamentSync();
      return false;
    }
  }

  static Future<void> _markPendingTournamentSync() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_pendingTournamentSyncKey, true);
  }

  static Future<void> _clearPendingTournamentSync() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingTournamentSyncKey);
  }

  /// Whether there's local tournament data waiting to reach the cloud.
  /// Always false for guests (nothing ever syncs) and for a logged-in
  /// person with nothing pending.
  static Future<bool> hasPendingTournamentSync() async {
    if (!_hasCloudAccess) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_pendingTournamentSyncKey) ?? false;
  }

  /// Retries pushing the locally-saved tournaments to the cloud. Called
  /// automatically by ConnectivityService the moment the device regains
  /// network, and also wired to TournamentSyncStatusBanner's manual "Sync
  /// Now" button as a fallback. Safe to call speculatively - it's a no-op
  /// for guests and whenever nothing is actually pending.
  static Future<bool> syncPendingTournaments() async {
    if (!await hasPendingTournamentSync()) return true;
    final local = await _loadLocalTournaments();
    if (local.isEmpty) {
      await _clearPendingTournamentSync();
      return true;
    }
    return saveTournaments(local);
  }

  static Future<List<Tournament>> _loadLocalTournaments() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_localTournamentsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final List decoded = jsonDecode(raw);
      return decoded.map((e) => Tournament.fromJson(e)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveLocalTournaments(List<Tournament> tournaments) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localTournamentsKey, jsonEncode(tournaments.map((t) => t.toJson()).toList()));
  }

  /// Local-only, never touches the cloud - used for the ball-by-ball
  /// crash-recovery autosave during tournament scoring (see
  /// MatchScorerScreen.onProgressUpdate), so an app kill mid-over doesn't
  /// lose progress without hitting the network on every single ball. The
  /// real saveTournaments (with cloud sync for logged-in users) still runs
  /// at the normal checkpoints - match finished, exited incomplete, and
  /// once per completed over as a periodic safety net.
  static Future<void> saveTournamentsLocalOnly(List<Tournament> tournaments) async {
    await _saveLocalTournaments(tournaments);
  }

  // --- Quick match history (local-first, manual cloud sync) ---

  /// Cloud rows (only for logged-in users) + local rows not yet synced,
  /// merged and de-duplicated by id. Guest mode returns purely local rows.
  static Future<List<MatchResultData>> loadQuickMatchHistory() async {
    final pending = await _loadPendingQuickMatches();
    if (!_hasCloudAccess) {
      final list = List<MatchResultData>.from(pending);
      list.sort((a, b) => (b.playedAt ?? DateTime(0)).compareTo(a.playedAt ?? DateTime(0)));
      return list;
    }
    final cloud = await _loadCloudQuickMatches();
    final pendingIds = pending.map((m) => m.id).toSet();
    // Local pending data is always at least as fresh as the cloud copy (the
    // cloud is only ever written by an explicit "Save to Cloud"/"Sync All"
    // action) - so on an id collision, the pending entry wins.
    final merged = [...pending, ...cloud.where((m) => !pendingIds.contains(m.id))];
    merged.sort((a, b) => (b.playedAt ?? DateTime(0)).compareTo(a.playedAt ?? DateTime(0)));
    return merged;
  }

  /// IDs of matches still sitting only in the local queue (not yet synced to
  /// the cloud). Used by the UI to show the "Save to Cloud" button.
  static Future<Set<String>> pendingQuickMatchIds() async {
    final pending = await _loadPendingQuickMatches();
    return pending.map((m) => m.id).toSet();
  }

  static Future<List<MatchResultData>> _loadCloudQuickMatches() async {
    if (!_hasCloudAccess) return [];
    try {
      final rows = await _client
          .from('quick_matches')
          .select()
          .eq('user_id', _userId!)
          .order('played_at', ascending: false)
          .limit(50);
      return (rows as List).map((r) => MatchResultData.fromJson(r['data'] as Map<String, dynamic>)).toList();
    } catch (e, st) {
      debugPrint('[StorageService] loadQuickMatchHistory (cloud) failed: $e');
      debugPrint('$st');
      return [];
    }
  }

  /// Quick matches ALWAYS save locally first, regardless of guest/logged-in
  /// state - the cloud copy is only created when the person explicitly asks
  /// for it (see retryQuickMatchSync / syncPendingQuickMatches), never here.
  static Future<void> addQuickMatchToHistory(MatchResultData result) async {
    await _queuePendingQuickMatch(result);
  }

  static Future<String?> _insertQuickMatchToCloudDetailed(MatchResultData result) async {
    if (!_hasCloudAccess) return "Sign up or log in to save matches to the cloud.";
    try {
      await _client.from('quick_matches').upsert({
        'id': result.id,
        'user_id': _userId,
        'data': result.toJson(),
        'played_at': (result.playedAt ?? DateTime.now()).toIso8601String(),
      }, onConflict: 'id');
      // Only now - once the match is actually confirmed synced to the cloud
      // - do its players touch the shared global registry. A match that
      // never gets synced (still sitting in the local pending queue, guest
      // mode, exited-early draft, etc.) must never create or update global
      // player rows.
      if (result.isComplete) {
        await registerMatchPlayers(result);
      }
      return null;
    } catch (e, st) {
      debugPrint('[StorageService] insert quick_matches failed: $e');
      debugPrint('$st');
      return e.toString();
    }
  }

  static Future<List<MatchResultData>> _loadPendingQuickMatches() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingQuickMatchesKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final List decoded = jsonDecode(raw);
      return decoded.map((e) => MatchResultData.fromJson(e)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _savePendingQuickMatches(List<MatchResultData> pending) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingQuickMatchesKey, jsonEncode(pending.map((m) => m.toJson()).toList()));
  }

  static Future<void> _queuePendingQuickMatch(MatchResultData result) async {
    final pending = await _loadPendingQuickMatches();
    // Replace, don't skip: this id may belong to an "Incomplete" match being
    // updated (either finished via Continue, or exited-incomplete again with
    // newer progress) - in both cases the newer data must win.
    pending.removeWhere((m) => m.id == result.id);
    pending.insert(0, result);
    await _savePendingQuickMatches(pending);
  }

  /// Retries every locally-queued match (the "Sync All" action). No-op for
  /// guests. Returns how many were successfully synced.
  static Future<int> syncPendingQuickMatches() async {
    if (!_hasCloudAccess) return 0;
    final pending = await _loadPendingQuickMatches();
    if (pending.isEmpty) return 0;

    int syncedCount = 0;
    final stillPending = <MatchResultData>[];
    for (final match in pending) {
      final error = await _insertQuickMatchToCloudDetailed(match);
      if (error == null) {
        syncedCount++;
      } else {
        stillPending.add(match);
      }
    }
    await _savePendingQuickMatches(stillPending);
    return syncedCount;
  }

  /// Manually pushes ONE match to the cloud (the per-item "Save to Cloud"
  /// button). Returns null on success, or an error message on failure -
  /// including "not logged in" for guests, so the UI can show exactly why.
  static Future<String?> retryQuickMatchSync(MatchResultData result) async {
    final error = await _insertQuickMatchToCloudDetailed(result);
    if (error == null) {
      final pending = await _loadPendingQuickMatches();
      pending.removeWhere((m) => m.id == result.id);
      await _savePendingQuickMatches(pending);
    }
    return error;
  }

  /// Deletes a match from history entirely: removes it from the local
  /// pending queue, and - if it had already been synced - also removes the
  /// matching row from the cloud so it doesn't reappear on next load.
  static Future<void> deleteQuickMatch(String id) async {
    final pending = await _loadPendingQuickMatches();
    pending.removeWhere((m) => m.id == id);
    await _savePendingQuickMatches(pending);

    if (_hasCloudAccess) {
      try {
        await _client.from('quick_matches').delete().eq('id', id).eq('user_id', _userId!);
      } catch (e, st) {
        debugPrint('[StorageService] deleteQuickMatch (cloud) failed: $e');
        debugPrint('$st');
      }
    }
  }

  // --- In-progress match draft (local-only, survives the app process being
  // killed - e.g. swiped away from recent apps - not just a normal exit) ---

  static Future<void> saveMatchDraft(MatchDraft draft) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_matchDraftKey, jsonEncode(draft.toJson()));
  }

  static Future<MatchDraft?> loadMatchDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_matchDraftKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return MatchDraft.fromJson(jsonDecode(raw));
    } catch (e, st) {
      debugPrint('[StorageService] loadMatchDraft failed: $e');
      debugPrint('$st');
      return null;
    }
  }

  static Future<void> clearMatchDraft() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_matchDraftKey);
  }

  // --- Saved team names (Teams page + Quick Match autocomplete) ---
  // Logged-in users: synced to the `teams` table (see the SQL provided
  // separately to create it) - a real per-row table rather than a JSON blob,
  // since a team name has no internal structure worth nesting. A local
  // mirror is still kept for guests and as an offline fallback.

  static Future<List<String>> _loadLocalTeams() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_savedTeamsKey) ?? [];
  }

  static Future<void> _saveLocalTeams(List<String> teams) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_savedTeamsKey, teams);
  }

  static Future<List<String>> loadTeams() async {
    if (!_hasCloudAccess) return _loadLocalTeams();
    try {
      final rows = await _client.from('teams').select().eq('user_id', _userId!).order('created_at');
      final names = (rows as List).map((r) => r['name'] as String).toList();
      await _saveLocalTeams(names); // keep the local mirror fresh too
      return names;
    } catch (e, st) {
      debugPrint('[StorageService] loadTeams (cloud) failed: $e');
      debugPrint('$st');
      return _loadLocalTeams();
    }
  }

  /// Adds a name to the saved roster if it isn't already there (case-
  /// insensitive) - called whenever a match starts, so the list grows
  /// naturally from use as well as from the Teams page's manual "Add".
  static Future<void> addTeamIfNew(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final existing = await loadTeams();
    if (existing.any((t) => t.toLowerCase() == trimmed.toLowerCase())) return;

    if (_hasCloudAccess) {
      try {
        await _client.from('teams').insert({
          'id': '${DateTime.now().microsecondsSinceEpoch}',
          'user_id': _userId,
          'name': trimmed,
          'created_at': DateTime.now().toIso8601String(),
        });
      } catch (e, st) {
        debugPrint('[StorageService] addTeamIfNew (cloud) failed: $e');
        debugPrint('$st');
      }
    }
    final local = await _loadLocalTeams();
    if (!local.any((t) => t.toLowerCase() == trimmed.toLowerCase())) {
      local.add(trimmed);
      await _saveLocalTeams(local);
    }
  }

  static Future<void> deleteTeam(String name) async {
    if (_hasCloudAccess) {
      try {
        await _client.from('teams').delete().eq('user_id', _userId!).eq('name', name);
      } catch (e, st) {
        debugPrint('[StorageService] deleteTeam (cloud) failed: $e');
        debugPrint('$st');
      }
    }
    final local = await _loadLocalTeams();
    local.removeWhere((t) => t == name);
    await _saveLocalTeams(local);
    // The name list and its roster are separate keys - dropping a team from
    // the list should drop its remembered squad too, or a re-added team of
    // the same name would silently resurrect an old, possibly stale roster.
    final rosters = await _loadLocalTeamRosters();
    if (rosters.remove(name) != null) await _saveLocalTeamRosters(rosters);
  }

  static Future<Map<String, dynamic>> _loadLocalTeamRosters() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_scopedTeamRostersKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static Future<void> _saveLocalTeamRosters(Map<String, dynamic> rosters) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_scopedTeamRostersKey, jsonEncode(rosters));
  }

  /// Remembers [squad] as team [teamName]'s usual XI, so the next match
  /// started with that same team name can offer it back instead of
  /// starting from blank "A-Player 1" placeholders. Called automatically
  /// once a match finishes (see MatchScorerScreen._finishMatchAndSave) -
  /// there's no separate "save roster" button, it just always remembers
  /// whatever XI a team most recently finished a match with. Cheap best-
  /// effort like the other autosaves in this file - not worth failing the
  /// whole match-finish flow over.
  static Future<void> saveTeamRoster(String teamName, List<Player> squad) async {
    final trimmed = teamName.trim();
    if (trimmed.isEmpty || squad.isEmpty) return;
    final playersJson = squad.map((p) => p.toJson()).toList();
    // BUG FIX: rosters are now keyed by lowercase name (both here and in
    // loadTeamRoster) - typing "Dhaka Tigers" one match and "dhaka tigers"
    // or "DHAKA TIGERS" the next used to be treated as two unrelated
    // teams, since the key was the exact-case trimmed string. Team NAMES
    // themselves were already deduped case-insensitively (see
    // addTeamIfNew/loadTeams); the roster lookup just hadn't matched that.

    // Local save happens FIRST and unconditionally - see the comment this
    // replaced for why: it must not be gated behind a slow/hanging network
    // call, or closing the app while that call is in flight loses the
    // roster entirely, even though the match itself saved fine.
    final rosters = await _loadLocalTeamRosters();
    rosters[trimmed.toLowerCase()] = playersJson;
    await _saveLocalTeamRosters(rosters);

    // Guarantees a `teams` row exists for this name to attach the roster
    // to - a no-op if it's already there (see addTeamIfNew).
    await addTeamIfNew(trimmed);
    if (_hasCloudAccess) {
      try {
        // ilike (case-insensitive) instead of eq, matching the
        // case-insensitive dedup already used for team names elsewhere.
        await _client.from('teams').update({'players': playersJson}).eq('user_id', _userId!).ilike('name', trimmed);
      } catch (e, st) {
        debugPrint('[StorageService] saveTeamRoster (cloud) failed: $e');
        debugPrint('$st');
      }
    }
  }

  /// The squad [teamName] last finished a match with, or null if this team
  /// has never completed one (brand new team, or one only ever used for
  /// an in-progress/abandoned match). Used by StartMatchScreen to offer
  /// "load usual squad" instead of forcing a fresh typed-out XI every time.
  static Future<List<Player>?> loadTeamRoster(String teamName) async {
    final trimmed = teamName.trim();
    if (trimmed.isEmpty) return null;
    final key = trimmed.toLowerCase();

    if (_hasCloudAccess) {
      try {
        // ilike (case-insensitive), matching saveTeamRoster - otherwise a
        // roster saved under "Dhaka Tigers" would silently miss a later
        // load for "dhaka tigers".
        final row = await _client.from('teams').select('players').eq('user_id', _userId!).ilike('name', trimmed).maybeSingle();
        final raw = row?['players'] as List?;
        if (raw != null && raw.isNotEmpty) {
          // Keep the local mirror fresh too, same as loadTeams does for names.
          final rosters = await _loadLocalTeamRosters();
          rosters[key] = raw;
          await _saveLocalTeamRosters(rosters);
          return raw.map((p) => Player.fromJson(p as Map<String, dynamic>)).toList();
        }
      } catch (e, st) {
        debugPrint('[StorageService] loadTeamRoster (cloud) failed: $e');
        debugPrint('$st');
      }
    }
    final rosters = await _loadLocalTeamRosters();
    final raw = rosters[key] as List?;
    if (raw == null || raw.isEmpty) return null;
    return raw.map((p) => Player.fromJson(p as Map<String, dynamic>)).toList();
  }

  // --- Photos page ---
  // Cloud-only (no local/guest fallback - a photo is a real file, not a
  // small convenience value like a team name). Files live in the `photos`
  // Storage bucket under `<user_id>/<filename>`; the `photos` table just
  // holds metadata pointing at them. See the SQL provided separately to
  // create the bucket, table, and their RLS policies.

  static Future<String?> uploadPhoto(Uint8List bytes, String fileExt, {String? caption}) async {
    if (!_hasCloudAccess) return "Log in to save photos to your account.";
    try {
      final id = '${DateTime.now().microsecondsSinceEpoch}';
      final path = '$_userId/$id.$fileExt';
      await _client.storage.from('photos').uploadBinary(path, bytes);
      await _client.from('photos').insert({
        'id': id,
        'user_id': _userId,
        'storage_path': path,
        'caption': caption,
        'created_at': DateTime.now().toIso8601String(),
      });
      return null;
    } catch (e, st) {
      debugPrint('[StorageService] uploadPhoto failed: $e');
      debugPrint('$st');
      return "Upload failed: $e";
    }
  }

  static Future<List<PhotoEntry>> loadPhotos() async {
    if (!_hasCloudAccess) return [];
    try {
      final rows = await _client.from('photos').select().eq('user_id', _userId!).order('created_at', ascending: false);
      return (rows as List).map((r) {
        final path = r['storage_path'] as String;
        return PhotoEntry(
          id: r['id'],
          url: _client.storage.from('photos').getPublicUrl(path),
          storagePath: path,
          caption: r['caption'],
          createdAt: DateTime.parse(r['created_at']),
        );
      }).toList();
    } catch (e, st) {
      debugPrint('[StorageService] loadPhotos failed: $e');
      debugPrint('$st');
      return [];
    }
  }

  static Future<void> deletePhoto(PhotoEntry photo) async {
    if (!_hasCloudAccess) return;
    try {
      await _client.storage.from('photos').remove([photo.storagePath]);
      await _client.from('photos').delete().eq('id', photo.id).eq('user_id', _userId!);
    } catch (e, st) {
      debugPrint('[StorageService] deletePhoto failed: $e');
      debugPrint('$st');
    }
  }

  /// Profile picture - reuses the same `photos` Storage bucket/RLS (path
  /// still starts with the user's own folder, so no new bucket is needed
  /// for the file itself) but at a fixed filename per user, and the URL is
  /// recorded in the `profiles` table rather than the `photos` table, since
  /// it's not a gallery photo. upsert:true means re-uploading replaces the
  /// old avatar at the same path.
  static Future<String?> uploadAvatar(Uint8List bytes, String fileExt) async {
    if (!_hasCloudAccess) return null;
    try {
      final path = '$_userId/avatar.$fileExt';
      await _client.storage.from('photos').uploadBinary(path, bytes, fileOptions: const FileOptions(upsert: true));
      // Cache-bust so the new avatar shows immediately instead of a stale
      // cached image at the same URL.
      return '${_client.storage.from('photos').getPublicUrl(path)}?t=${DateTime.now().millisecondsSinceEpoch}';
    } catch (e, st) {
      debugPrint('[StorageService] uploadAvatar failed: $e');
      debugPrint('$st');
      return null;
    }
  }

  // --- Profile page (name/phone/bio/avatar) ---
  // Backed by the `profiles` table (see the SQL provided separately) -
  // one row per user, id = auth.uid(). Cloud-only, same as Photos - there's
  // no meaningful "guest profile" since a guest has no account for it to
  // attach to.

  /// Whether the signed-in account is a registry admin (`profiles.is_admin`).
  /// This is a UX convenience only - it hides the merge entry point for
  /// non-admins so they don't tap into a 403. It is NOT the security
  /// boundary: that lives in the `merge_players_admin_gated` RPC itself
  /// (see mergeGlobalPlayers below), which re-checks admin status on the
  /// server no matter what the client sends.
  static Future<bool> isCurrentUserAdmin() async {
    if (!_hasCloudAccess) return false;
    try {
      final row = await _client.from('profiles').select('is_admin').eq('id', _userId!).maybeSingle();
      return row?['is_admin'] == true;
    } catch (e, st) {
      debugPrint('[StorageService] isCurrentUserAdmin failed: $e');
      debugPrint('$st');
      return false;
    }
  }

  static Future<UserProfile?> loadProfile() async {
    if (!_hasCloudAccess) return null;
    try {
      final row = await _client.from('profiles').select().eq('id', _userId!).maybeSingle();
      if (row == null) return null;
      return UserProfile(name: row['name'], phone: row['phone'], bio: row['bio'], avatarUrl: row['avatar_url']);
    } catch (e, st) {
      debugPrint('[StorageService] loadProfile failed: $e');
      debugPrint('$st');
      return null;
    }
  }

  /// Upserts the profile row - null means "leave unchanged" for that field
  /// (an existing row is merged, not replaced), same convention as
  /// AuthService.updateProfile used to have. Returns null on success, or an
  /// error message.
  static Future<String?> saveProfile({String? name, String? phone, String? bio, String? avatarUrl}) async {
    if (!_hasCloudAccess) return "Log in to save your profile.";
    try {
      final existing = await _client.from('profiles').select().eq('id', _userId!).maybeSingle();
      final data = <String, dynamic>{
        'id': _userId,
        'name': name ?? existing?['name'],
        'phone': phone ?? existing?['phone'],
        'bio': bio ?? existing?['bio'],
        'avatar_url': avatarUrl ?? existing?['avatar_url'],
        'updated_at': DateTime.now().toIso8601String(),
      };
      await _client.from('profiles').upsert(data, onConflict: 'id');
      return null;
    } catch (e, st) {
      debugPrint('[StorageService] saveProfile failed: $e');
      debugPrint('$st');
      return "Save failed: $e";
    }
  }

  // --- Watch Live (live_matches table) ---
  // Deliberately does NOT require the viewer to be logged in - a live match
  // is meant to be shared with anyone who has the code. Only starting/
  // updating/ending a broadcast requires the scorer's own account.

  static Future<String?> startLiveBroadcast(LiveBroadcast broadcast) async {
    if (!_hasCloudAccess) return "Log in to go live.";
    try {
      await _client.from('live_matches').insert({
        'id': broadcast.id,
        'user_id': _userId,
        'team_a': broadcast.teamA,
        'team_b': broadcast.teamB,
        'data': broadcast.toJson(),
        'video_url': broadcast.videoUrl,
        'updated_at': DateTime.now().toIso8601String(),
      });
      return null;
    } catch (e, st) {
      debugPrint('[StorageService] startLiveBroadcast failed: $e');
      debugPrint('$st');
      return "Couldn't go live: $e";
    }
  }

  // Holds whatever the MOST RECENT call to updateLiveBroadcast passed in
  // that hasn't been sent to the network yet.
  static LiveBroadcast? _pendingLiveBroadcast;
  // Non-null while a request to live_matches is actually in flight.
  static bool _liveBroadcastSendInFlight = false;

  /// Fire-and-forget on purpose (called after every ball while live) - a
  /// dropped update just means the viewer sees the next one a moment later,
  /// not worth blocking/erroring the scorer's UI over.
  ///
  /// BUG FIX (viewer showing a stale over score, e.g. "7" when the over
  /// actually finished on "9"): this used to fire an independent HTTP
  /// request on every single ball with no ordering guarantee between them.
  /// A quick burst of taps (several runs scored in fast succession) could
  /// have request N-1 (an EARLIER, smaller running total) finish AFTER
  /// request N (the latest, correct total) purely because of network
  /// timing - whichever response reaches Supabase last simply overwrites
  /// the row, so the viewer could end up looking at older data than what
  /// was actually just scored. Now only ONE request to live_matches is ever
  /// in flight at a time: new calls just update [_pendingLiveBroadcast] and
  /// return immediately, and whichever request is in flight sends the
  /// latest pending snapshot next (skipping any intermediate ones) the
  /// moment it completes. That guarantees the row always ends up reflecting
  /// the most recent state, in order, with no race - and it's cheaper too,
  /// since a fast burst of balls collapses into one send instead of one
  /// request per ball.
  static void updateLiveBroadcast(LiveBroadcast broadcast) {
    if (!_hasCloudAccess) return;
    _pendingLiveBroadcast = broadcast;
    if (_liveBroadcastSendInFlight) return;
    _sendNextPendingLiveBroadcast();
  }

  static void _sendNextPendingLiveBroadcast() {
    final broadcast = _pendingLiveBroadcast;
    if (broadcast == null) return;
    _pendingLiveBroadcast = null;
    _liveBroadcastSendInFlight = true;
    _client.from('live_matches').update({
      'data': broadcast.toJson(),
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('id', broadcast.id).eq('user_id', _userId!).then(
      (_) {},
      onError: (e, st) {
        debugPrint('[StorageService] updateLiveBroadcast failed: $e');
      },
    ).whenComplete(() {
      _liveBroadcastSendInFlight = false;
      // Another (newer) update may have come in while this one was in
      // flight - send it now instead of waiting for the next ball.
      _sendNextPendingLiveBroadcast();
    });
  }

  static Future<void> endLiveBroadcast(String broadcastId) async {
    if (!_hasCloudAccess) return;
    try {
      await _client.from('live_matches').delete().eq('id', broadcastId).eq('user_id', _userId!);
    } catch (e, st) {
      debugPrint('[StorageService] endLiveBroadcast failed: $e');
      debugPrint('$st');
    }
  }

  /// Read-only lookup by broadcast code - works for anyone, logged in or
  /// not, per the public select policy on live_matches.
  static Future<LiveBroadcast?> fetchLiveBroadcast(String broadcastId) async {
    try {
      final row = await _client.from('live_matches').select().eq('id', broadcastId.trim().toUpperCase()).maybeSingle();
      if (row == null) return null;
      return LiveBroadcast.fromRow(row);
    } catch (e, st) {
      debugPrint('[StorageService] fetchLiveBroadcast failed: $e');
      debugPrint('$st');
      return null;
    }
  }

  // ---------------------------------------------------------------------
  // Global player registry (see player_registry_schema.sql)
  // Cross-account, public-read - not scoped by _userId like everything
  // above. Guests are skipped entirely: their matches are device-local
  // and never contribute to (or read from) the shared registry.
  // ---------------------------------------------------------------------

  /// Public search - works for any account, no user_id filter. Empty
  /// query returns the most recent players (used for the autocomplete's
  /// initial dropdown and the Players screen's default list).
  static Future<List<GlobalPlayer>> searchGlobalPlayers(String query) async {
    try {
      var q = _client.from('players').select().filter('merged_into', 'is', null);
      final trimmed = query.trim();
      if (trimmed.isNotEmpty) {
        q = q.ilike('canonical_name', '%$trimmed%');
      }
      final rows = await q.order('canonical_name').limit(30);
      return (rows as List).map((r) => GlobalPlayer.fromJson(r)).toList();
    } catch (e, st) {
      debugPrint('[StorageService] searchGlobalPlayers failed: $e');
      debugPrint('$st');
      return [];
    }
  }

  /// Read-only exact-name lookup (never creates a row, unlike
  /// findOrCreateGlobalPlayer) - for the "new batter/bowler" live-viewer
  /// spotlight card below, where showing nothing for an unregistered/
  /// default-named player is the correct behavior, not a reason to create
  /// one just because the scorer happened to look them up.
  static Future<GlobalPlayer?> findGlobalPlayerByExactName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    try {
      final row = await _client.from('players').select().ilike('canonical_name', trimmed).filter('merged_into', 'is', null).maybeSingle();
      if (row == null) return null;
      return GlobalPlayer.fromJson(row);
    } catch (e, st) {
      debugPrint('[StorageService] findGlobalPlayerByExactName failed: $e');
      debugPrint('$st');
      return null;
    }
  }

  /// Everything the live-viewer "new batter/bowler" spotlight card needs,
  /// in one lookup: resolves the name to a registry entry (if one exists -
  /// still-default-named or never-played players correctly resolve to
  /// null here, same as everywhere else) and pulls their career stats.
  /// Called once by the SCORER when a new batter/bowler is confirmed, then
  /// the result rides along on the next regular broadcast update - never
  /// queried directly by viewers, so it costs nothing extra per-viewer.
  static Future<({GlobalPlayer player, PlayerStat stat})?> loadSpotlightCard(String name) async {
    if (!_hasCloudAccess) return null;
    final player = await findGlobalPlayerByExactName(name);
    if (player == null) return null;
    final stat = await loadCareerStats(player.id, player.name);
    if (stat == null || stat.matches == 0) return null;
    return (player: player, stat: stat);
  }

  /// Returns the id of an existing player with this exact name if one
  /// exists, otherwise creates a new global player and returns its id.
  /// Callers should always go through this (never insert into `players`
  /// directly) so typos-of-an-existing-name don't silently fork into a
  /// second row - the name check happens server-side, atomically enough
  /// for this app's scale.
  static Future<String?> findOrCreateGlobalPlayer(String name) async {
    if (!_hasCloudAccess) return null; // guests don't touch the shared registry
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    try {
      final existing = await _client
          .from('players')
          .select('id')
          .ilike('canonical_name', trimmed)
          .filter('merged_into', 'is', null)
          .maybeSingle();
      if (existing != null) return existing['id'] as String;

      final inserted = await _client
          .from('players')
          .insert({'canonical_name': trimmed, 'created_by': _userId})
          .select('id')
          .single();
      return inserted['id'] as String;
    } catch (e, st) {
      debugPrint('[StorageService] findOrCreateGlobalPlayer failed: $e');
      debugPrint('$st');
      return null;
    }
  }

  /// Uploads/replaces a global player's profile photo and records its URL
  /// on the `players` row. Shares the same `photos` Storage bucket as the
  /// account avatar/gallery (no new bucket needed), but under a `players/`
  /// prefix since these files aren't owned by a single user's folder - any
  /// logged-in account can add or fix a photo for a shared registry entry,
  /// same as they can already edit its name via merge. Requires the
  /// bucket's storage policy to allow authenticated writes under
  /// `players/*` (not just `$_userId/*`) and a `photo_url text` column on
  /// `players` - see the note in player_registry_schema.sql.
  /// Returns (url: ..., error: null) on success, or (url: null, error: ...)
  /// on failure - the real Supabase error, not a generic message, so a
  /// policy/RLS misconfiguration is diagnosable straight from the app's
  /// snackbar.
  static Future<({String? url, String? error})> uploadPlayerPhoto(String playerId, Uint8List bytes, String fileExt) async {
    if (!_hasCloudAccess) return (url: null, error: "Log in to upload a player photo.");
    try {
      final path = 'players/$playerId.$fileExt';
      await _client.storage.from('photos').uploadBinary(path, bytes, fileOptions: const FileOptions(upsert: true));
      // Cache-bust so the new photo shows immediately instead of a stale
      // cached image at the same URL.
      final url = '${_client.storage.from('photos').getPublicUrl(path)}?t=${DateTime.now().millisecondsSinceEpoch}';
      await _client.from('players').update({'photo_url': url}).eq('id', playerId);
      return (url: url, error: null);
    } catch (e, st) {
      debugPrint('[StorageService] uploadPlayerPhoto failed: $e');
      debugPrint('$st');
      return (url: null, error: e.toString());
    }
  }

  /// Full lifetime career stats for the Player Detail screen.
  static Future<PlayerStat?> loadCareerStats(String playerId, String name) async {
    try {
      final row = await _client.from('player_career_stats').select().eq('player_id', playerId).maybeSingle();
      if (row == null) return null;
      return PlayerStatFromCareerRow.fromCareerRow(name, row);
    } catch (e, st) {
      debugPrint('[StorageService] loadCareerStats failed: $e');
      debugPrint('$st');
      return null;
    }
  }

  /// Call once a match finishes (quick match or tournament match), right
  /// alongside wherever the local per-Tournament `playerStats` map gets
  /// updated. [deltas] must be keyed by the GLOBAL player id (from the
  /// autocomplete selection / findOrCreateGlobalPlayer), not the per-match
  /// squad id, and should hold just that match's numbers (not running
  /// totals) - the increment_player_stats RPC adds them on atomically,
  /// so two accounts finishing matches at the same moment can't clobber
  /// each other's update.
  static Future<void> pushCareerStatDeltas(Map<String, PlayerStat> deltas) async {
    if (!_hasCloudAccess) return;
    for (final entry in deltas.entries) {
      try {
        await _client.rpc('increment_player_stats', params: {
          'p_player_id': entry.key,
          'delta': entry.value.toJson(),
        });
      } catch (e, st) {
        debugPrint('[StorageService] pushCareerStatDeltas failed for ${entry.key}: $e');
        debugPrint('$st');
      }
    }
  }

  /// The single place a match's players actually reach the shared global
  /// registry. Deliberately NOT called from the squad editor or "Start
  /// Match" - only from the moment a match itself is confirmed synced to
  /// the cloud (quick match "Save to Cloud"/"Sync All", or a tournament
  /// match completing, since tournaments auto-sync). A match that's still
  /// only local (guest mode, unsynced quick match, exited-early draft)
  /// must not create or update any global player row.
  ///
  /// Resolves each participant's squad-local name to a global player id
  /// (creating the row if it's a genuinely new name), then pushes that
  /// match's stat contribution keyed by the resolved global id. Also
  /// records full-squad match participation (see _recordMatchParticipants)
  /// for head-to-head lookups - covers bench players too, not just those
  /// with a batting/bowling line.
  /// Matches every squad-name pattern this codebase auto-generates when
  /// the person hasn't renamed a player yet: "A-Player 3"/"B-Player 3"
  /// (start_match_screen defaults/resize), "Bat-Player 3"/"Bowl-Player 3"
  /// (match_scorer_screen's own fallback defaults), and "New Player" (the
  /// squad editor's "+ Add Player" button). If a new default-name pattern
  /// is ever added elsewhere, it needs to be reflected here too or it'll
  /// start leaking placeholder names into the shared registry again.
  static final RegExp _defaultPlayerNamePattern = RegExp(r'^(A|B|Bat|Bowl)-Player \d+$');
  static bool _isDefaultPlayerName(String name) => name == 'New Player' || _defaultPlayerNamePattern.hasMatch(name);

  static Future<void> registerMatchPlayers(MatchResultData result, {String? tournamentId}) async {
    if (!_hasCloudAccess) return;
    final deltas = result.computePlayerStatDeltas();

    // MatchResultData.fullSquad is never actually populated by the scorer
    // screen (it's always an empty list at match completion) - the real
    // source of truth for "everyone in this match" is each innings' own
    // squad list, which IS the full batting-team roster at the time that
    // innings was recorded (not just allBatsmen/allBowlers, which only
    // covers players who actually batted/bowled).
    final allParticipants = <Player>[
      ...?result.innings1?.squad,
      ...?result.innings2?.squad,
    ];

    final Map<String, String> localToGlobalId = {};
    for (final p in allParticipants) {
      // Still an auto-generated placeholder ("A-Player 3", "New Player")
      // that nobody actually typed a real name over - never let this
      // reach the shared registry. Unlike a real name, unrelated players
      // across unrelated matches would otherwise all collapse into the
      // same "Player 3" row (which is exactly the collision that caused
      // the ON CONFLICT crash this replaced). The match itself still
      // scores and saves completely normally either way - this only
      // affects whether that particular squad slot gets career-stat/
      // head-to-head tracking.
      if (_isDefaultPlayerName(p.name)) continue;
      final globalId = await findOrCreateGlobalPlayer(p.name);
      if (globalId != null) localToGlobalId[p.id] = globalId;
    }
    if (localToGlobalId.isEmpty) return;

    if (deltas.isNotEmpty) {
      final byGlobalId = <String, PlayerStat>{
        for (final entry in deltas.entries)
          if (localToGlobalId.containsKey(entry.key)) localToGlobalId[entry.key]!: entry.value,
      };
      if (byGlobalId.isNotEmpty) {
        // Detect newly-crossed badges BEFORE pushing (needs the pre-match
        // totals to diff against), but only record/notify once the push
        // itself has actually succeeded - a milestone notification for
        // stats that didn't really save would be worse than no
        // notification at all.
        final newlyEarned = await _detectNewMilestones(byGlobalId);
        await pushCareerStatDeltas(byGlobalId);
        if (newlyEarned.isNotEmpty) await _recordMilestones(newlyEarned);
      }
    }

    await _recordMatchParticipants(result, localToGlobalId);
    await _pushMatchupDeltas(result, localToGlobalId);
    await _recordMatchPerformances(result, localToGlobalId, tournamentId: tournamentId);
  }

  /// One row per (match, player) with that specific match's batting/bowling
  /// line - powers PlayerDetailScreen's "Recent Matches" list and form
  /// graph. Distinct from player_career_stats (lifetime totals) and
  /// player_matchups (vs one specific opponent) - this is "what did they
  /// do in THIS match". Sourced from allBatsmen/allBowlers (same as
  /// MatchResultStatDeltas.computePlayerStatDeltas), not fullSquad.
  static Future<void> _recordMatchPerformances(MatchResultData result, Map<String, String> localToGlobalId, {String? tournamentId}) async {
    final innings1 = result.innings1;
    final innings2 = result.innings2;
    final innings1Ids = innings1?.squad.map((p) => p.id).toSet() ?? <String>{};
    final innings2Ids = innings2?.squad.map((p) => p.id).toSet() ?? <String>{};

    String? opponentFor(String localId) {
      if (innings1Ids.contains(localId)) return innings2?.teamName;
      if (innings2Ids.contains(localId)) return innings1?.teamName;
      return null;
    }

    final playedAtIso = (result.playedAt ?? DateTime.now()).toIso8601String();
    final rows = <String, Map<String, dynamic>>{};

    for (final b in result.allBatsmen) {
      final globalId = localToGlobalId[b.id];
      if (globalId == null) continue;
      rows[globalId] = {
        'match_id': result.id,
        'player_id': globalId,
        'played_at': playedAtIso,
        'opponent_team': opponentFor(b.id),
        'runs': b.runs,
        'balls': b.balls,
        'fours': b.fours,
        'sixes': b.sixes,
        'dismissal': b.dismissal,
        'tournament_id': tournamentId,
      };
    }
    for (final bowl in result.allBowlers) {
      final globalId = localToGlobalId[bowl.id];
      if (globalId == null) continue;
      final existing = rows[globalId] ??
          {
            'match_id': result.id,
            'player_id': globalId,
            'played_at': playedAtIso,
            'opponent_team': opponentFor(bowl.id),
            'tournament_id': tournamentId,
          };
      existing['wickets'] = bowl.wickets;
      existing['runs_conceded'] = bowl.runs;
      existing['overs_bowled'] = bowl.balls / 6.0;
      rows[globalId] = existing;
    }

    if (rows.isEmpty) return;
    try {
      await _client.from('player_match_performances').upsert(rows.values.toList(), onConflict: 'match_id,player_id');
    } catch (e, st) {
      debugPrint('[StorageService] _recordMatchPerformances failed: $e');
      debugPrint('$st');
    }
  }

  /// Sum of fours/sixes across every COMPLETED, synced match recorded so
  /// far for [tournamentId] (via player_match_performances.tournament_id).
  /// A public RPC (works for logged-out live viewers too), and
  /// aggregate-only by design - it doesn't leak any per-player or
  /// per-match detail, just two totals. Call this ONCE per live-viewing
  /// session (not on every poll) and add the live match's own running
  /// LiveBroadcast.matchFours/matchSixes on top - the current in-progress
  /// match has no row here yet, so there's no double-counting.
  static Future<({int fours, int sixes})> loadTournamentBoundaryTotals(String tournamentId) async {
    try {
      final row = await _client.rpc('tournament_boundary_totals', params: {'p_tournament_id': tournamentId}).maybeSingle();
      if (row == null) return (fours: 0, sixes: 0);
      return (fours: (row['total_fours'] as num?)?.toInt() ?? 0, sixes: (row['total_sixes'] as num?)?.toInt() ?? 0);
    } catch (e, st) {
      debugPrint('[StorageService] loadTournamentBoundaryTotals failed: $e');
      debugPrint('$st');
      return (fours: 0, sixes: 0);
    }
  }

  /// Most recent matches first - powers the "Recent Matches" list and form
  /// graph (callers typically reverse this to chronological order for the
  /// graph's left-to-right timeline).
  static Future<List<MatchPerformance>> loadRecentPerformances(String playerId, {int limit = 10}) async {
    if (!_hasCloudAccess) return [];
    try {
      final rows = await _client.from('player_match_performances').select().eq('player_id', playerId).order('played_at', ascending: false).limit(limit);
      return rows.map<MatchPerformance>((r) => MatchPerformance.fromJson(r)).toList();
    } catch (e, st) {
      debugPrint('[StorageService] loadRecentPerformances failed: $e');
      debugPrint('$st');
      return [];
    }
  }

  /// For each (globalPlayerId -> delta), fetches that player's CURRENT
  /// career stat, works out what their total would become after this
  /// match's delta is applied (PlayerStatMerge.mergeWith already handles
  /// "max, don't sum" for highest-score/best-bowling correctly), and diffs
  /// PlayerBadges.earnedBadges before vs after. Returns only the labels
  /// that are new - i.e. actually crossed a threshold this match, not
  /// every badge the player currently holds.
  static Future<List<(String playerId, String playerName, String badgeLabel)>> _detectNewMilestones(Map<String, PlayerStat> byGlobalId) async {
    final newlyEarned = <(String, String, String)>[];
    for (final entry in byGlobalId.entries) {
      final playerId = entry.key;
      final delta = entry.value;
      final before = await loadCareerStats(playerId, delta.name) ?? PlayerStat(name: delta.name);
      final beforeBadges = before.earnedBadges.map((b) => b.label).toSet();

      final after = PlayerStat(name: delta.name)..mergeWith(before)..mergeWith(delta);
      final afterBadges = after.earnedBadges;

      for (final badge in afterBadges) {
        if (!beforeBadges.contains(badge.label)) {
          newlyEarned.add((playerId, delta.name, badge.label));
        }
      }
    }
    return newlyEarned;
  }

  static Future<void> _recordMilestones(List<(String playerId, String playerName, String badgeLabel)> milestones) async {
    try {
      await _client.from('player_milestones').insert([
        for (final m in milestones) {'player_id': m.$1, 'player_name': m.$2, 'badge_label': m.$3},
      ]);
    } catch (e, st) {
      debugPrint('[StorageService] _recordMilestones failed: $e');
      debugPrint('$st');
    }
  }

  /// Feed for the in-app notification bell - most recent milestones first.
  static Future<List<Milestone>> loadRecentMilestones({int limit = 50}) async {
    if (!_hasCloudAccess) return [];
    try {
      final rows = await _client.from('player_milestones').select().order('created_at', ascending: false).limit(limit);
      return rows.map<Milestone>((r) => Milestone.fromJson(r)).toList();
    } catch (e, st) {
      debugPrint('[StorageService] loadRecentMilestones failed: $e');
      debugPrint('$st');
      return [];
    }
  }

  static const _lastSeenMilestoneKey = 'last_seen_milestone_at';

  /// How many milestones have appeared since this device last opened the
  /// notification feed - purely a local, per-device "unread" count (no
  /// server-side read-tracking table needed for this).
  static Future<int> countUnseenMilestones() async {
    final milestones = await loadRecentMilestones();
    if (milestones.isEmpty) return 0;
    final prefs = await SharedPreferences.getInstance();
    final lastSeenMillis = prefs.getInt(_lastSeenMilestoneKey);
    if (lastSeenMillis == null) return milestones.length;
    final lastSeen = DateTime.fromMillisecondsSinceEpoch(lastSeenMillis);
    return milestones.where((m) => m.createdAt.isAfter(lastSeen)).length;
  }

  // BUG FIX: this used to stamp DateTime.now() - the DEVICE's clock - as
  // "seen up to here". Milestone.createdAt, though, is a server-generated
  // Supabase timestamp. Any clock skew on the device (common on
  // emulators, or a phone with the wrong time/timezone) meant the device's
  // "now" could be earlier than a milestone's server timestamp even
  // though the person had just looked right at it - so it kept counting
  // as unseen forever, no matter how many times the feed was opened.
  // Stamping the LATEST MILESTONE'S OWN server timestamp instead means
  // countUnseenMilestones only ever compares server time to server time -
  // the device's clock is never involved, so there's nothing for it to
  // be skewed against.
  static Future<void> markMilestonesSeen({DateTime? latestMilestoneAt}) async {
    final prefs = await SharedPreferences.getInstance();
    final stamp = latestMilestoneAt ?? DateTime.now();
    await prefs.setInt(_lastSeenMilestoneKey, stamp.millisecondsSinceEpoch);
  }

  /// Pushes this match's ball-by-ball batter-vs-bowler totals to
  /// `player_matchups`, remapping the local squad ids in
  /// computeMatchupDeltas() to global registry ids the same way stats and
  /// participation do. Both players in a pair need a resolved global id -
  /// a pair involving a still-default-named player (see
  /// _isDefaultPlayerName) is simply skipped, same as everywhere else.
  static Future<void> _pushMatchupDeltas(MatchResultData result, Map<String, String> localToGlobalId) async {
    final deltas = result.computeMatchupDeltas();
    if (deltas.isEmpty) return;

    for (final entry in deltas.entries) {
      final batsmanGlobalId = localToGlobalId[entry.key.$1];
      final bowlerGlobalId = localToGlobalId[entry.key.$2];
      if (batsmanGlobalId == null || bowlerGlobalId == null) continue;

      try {
        await _client.rpc('increment_player_matchup', params: {
          'p_batsman_id': batsmanGlobalId,
          'p_bowler_id': bowlerGlobalId,
          'p_runs': entry.value.runs,
          'p_balls': entry.value.balls,
          'p_dismissals': entry.value.dismissals,
        });
      } catch (e, st) {
        debugPrint('[StorageService] _pushMatchupDeltas failed for $batsmanGlobalId vs $bowlerGlobalId: $e');
        debugPrint('$st');
      }
    }
  }

  /// One player's batting record against one specific bowler (runs/balls/
  /// dismissals when [batsmanId] faced [bowlerId]) - call it again with the
  /// two ids swapped to get the reverse direction (when the bowler batted
  /// against this batsman-turned-bowler), since a cricket matchup is
  /// directional and these are two entirely separate rows.
  static Future<MatchupDelta?> loadMatchup(String batsmanId, String bowlerId) async {
    if (!_hasCloudAccess) return null;
    try {
      final row = await _client.from('player_matchups').select().eq('batsman_id', batsmanId).eq('bowler_id', bowlerId).maybeSingle();
      if (row == null) return null;
      return MatchupDelta()
        ..runs = row['runs'] ?? 0
        ..balls = row['balls'] ?? 0
        ..dismissals = row['dismissals'] ?? 0;
    } catch (e, st) {
      debugPrint('[StorageService] loadMatchup failed: $e');
      debugPrint('$st');
      return null;
    }
  }

  /// One row per (match, player): which team they played for and whether
  /// that team won - powers loadHeadToHead below. Team is derived from
  /// InningsHistory (Player itself carries no team field) by matching each
  /// squad-local id against innings1.squad / innings2.squad.
  static Future<void> _recordMatchParticipants(MatchResultData result, Map<String, String> localToGlobalId) async {
    final innings1 = result.innings1;
    final innings2 = result.innings2;
    if (innings1 == null || innings2 == null) {
      lastMatchParticipantsError = 'Skipped: innings1 or innings2 was null on this match result.';
      return;
    }

    final innings1Ids = innings1.squad.map((p) => p.id).toSet();
    final innings2Ids = innings2.squad.map((p) => p.id).toSet();

    final rows = <Map<String, dynamic>>[];
    // Two DIFFERENT local squad ids can resolve to the SAME global player
    // id - most commonly when both squads still have unrenamed default
    // names ("Player 1" in Team A and "Player 1" in Team B both match the
    // same registry row, since lookup is by name only, not by name+team).
    // A single upsert can't touch the same (match_id, player_id) row twice
    // (Postgres rejects it outright - "ON CONFLICT DO UPDATE command
    // cannot affect row a second time"), so guard against it here rather
    // than let the whole match's sync fail on it.
    final seenGlobalIds = <String>{};
    for (final entry in localToGlobalId.entries) {
      String? teamName;
      if (innings1Ids.contains(entry.key)) {
        teamName = innings1.teamName;
      } else if (innings2Ids.contains(entry.key)) {
        teamName = innings2.teamName;
      }
      if (teamName == null) continue; // squad member who never appears in either innings' squad list
      if (!seenGlobalIds.add(entry.value)) continue; // already added this global player for this match

      rows.add({
        'match_id': result.id,
        'player_id': entry.value,
        'team_name': teamName,
        // result.winner is the winning team's name, or "Tie" - never
        // truly "won" for either side on a tie, so leave it null rather
        // than guessing.
        'won': result.winner == 'Tie' ? null : teamName == result.winner,
      });
    }
    if (rows.isEmpty) {
      lastMatchParticipantsError = 'Skipped: no squad player id matched either innings squad list.';
      return;
    }

    try {
      await _client.from('match_participants').upsert(rows, onConflict: 'match_id,player_id');
      lastMatchParticipantsError = null;
    } catch (e, st) {
      debugPrint('[StorageService] _recordMatchParticipants failed: $e');
      debugPrint('$st');
      // No console access on-device, so this is also surfaced directly in
      // the app (Profile screen has a "Last sync error" debug row) - a
      // temporary diagnostic aid, not meant to stay long-term.
      lastMatchParticipantsError = e.toString();
    }
  }

  /// Diagnostic-only: the most recent exception from
  /// _recordMatchParticipants, or null if the last attempt succeeded (or
  /// none has run yet). Shown on the Profile screen so a real error is
  /// readable on-device without a debug console. Remove once head-to-head
  /// sync is confirmed reliable.
  static String? lastMatchParticipantsError;

  /// How many times two global players have appeared in the same synced
  /// match, split into "faced each other" (opposite team_name) vs
  /// "teammates" (same team_name) - plus a simple win tally for the
  /// opposing matches. Pulled as two flat queries and joined client-side
  /// on match_id rather than a single SQL self-join, since that keeps this
  /// working without needing a bespoke RPC.
  static Future<HeadToHead> loadHeadToHead(String playerIdA, String playerIdB) async {
    if (!_hasCloudAccess) return HeadToHead.empty();
    try {
      final rowsA = await _client.from('match_participants').select().eq('player_id', playerIdA);
      final rowsB = await _client.from('match_participants').select().eq('player_id', playerIdB);
      final byMatchB = {for (final r in rowsB) r['match_id'] as String: r};

      int opponentMatches = 0, teammateMatches = 0, aWins = 0, bWins = 0;
      for (final rowA in rowsA) {
        final rowB = byMatchB[rowA['match_id']];
        if (rowB == null) continue;
        if (rowA['team_name'] == rowB['team_name']) {
          teammateMatches++;
        } else {
          opponentMatches++;
          if (rowA['won'] == true) aWins++;
          if (rowB['won'] == true) bWins++;
        }
      }
      return HeadToHead(opponentMatches: opponentMatches, teammateMatches: teammateMatches, playerAWins: aWins, playerBWins: bWins);
    } catch (e, st) {
      debugPrint('[StorageService] loadHeadToHead failed: $e');
      debugPrint('$st');
      return HeadToHead.empty();
    }
  }

  /// Merges [duplicateIds] into [primaryId]: sums Total Runs/Innings/
  /// Wickets/Boundaries, keeps the better Highest Score and Best Bowling
  /// (best-of, not summed - see merge_players in player_registry_schema.sql),
  /// and leaves an alias so old references still resolve. Irreversible.
  /// Calls the *admin-gated* wrapper, not the raw `merge_players` function
  /// - the wrapper re-checks `profiles.is_admin` on the server before doing
  /// anything (and logs the merge to `player_merge_log`), so this can't be
  /// bypassed by a non-admin calling the REST API directly even if they
  /// never go through this Flutter code path. See the SQL migration notes
  /// for the exact server-side setup.
  static Future<void> mergeGlobalPlayers({required String primaryId, required List<String> duplicateIds}) async {
    if (duplicateIds.contains(primaryId)) {
      throw ArgumentError("Primary player can't also be in the duplicates list");
    }
    await _client.rpc('merge_players_admin_gated', params: {
      'p_primary_id': primaryId,
      'p_duplicate_ids': duplicateIds,
    });
  }

  /// Calls the admin-gated wrapper - re-checks `profiles.is_admin` on the
  /// server (same pattern as mergeGlobalPlayers above) and logs to
  /// `player_delete_log` before permanently removing the player's
  /// career-stats row, every match_participants row, and the player row
  /// itself. Irreversible - the caller (PlayersScreen) is responsible for
  /// the typed-name confirmation step before this is ever invoked.
  static Future<void> deletePlayer(String playerId) async {
    await _client.rpc('delete_player_admin_gated', params: {'p_player_id': playerId});
  }

  /// Top players by [metric] ('runs' or 'wickets'), for the Leaderboard
  /// screen. Deliberately a two-step fetch (career stats, then the
  /// matching `players` rows) instead of a single PostgREST embed/join -
  /// that would depend on a foreign-key relationship being configured
  /// between `player_career_stats.player_id` and `players.id`, which this
  /// codebase can't confirm is set up. Two plain queries always work.
  /// Excludes merged-away duplicate names and anyone with 0 matches.
  static Future<List<({GlobalPlayer player, PlayerStat stat})>> loadLeaderboard({
    required String metric,
    int limit = 50,
  }) async {
    if (!_hasCloudAccess) return [];
    try {
      // Over-fetch since some rows get dropped below (merged duplicates,
      // 0-match rows) - without this a leaderboard could come back
      // short of `limit` even when enough qualifying players exist.
      final statRows = await _client.from('player_career_stats').select().order(metric, ascending: false).limit(limit * 2);
      if (statRows.isEmpty) return [];

      final ids = statRows.map((r) => r['player_id'] as String).toList();
      final playerRows = await _client.from('players').select().inFilter('id', ids);
      final playersById = {for (final p in playerRows) p['id'] as String: GlobalPlayer.fromJson(p)};

      final result = <({GlobalPlayer player, PlayerStat stat})>[];
      for (final row in statRows) {
        final player = playersById[row['player_id']];
        if (player == null || player.mergedInto != null) continue;
        final stat = PlayerStatFromCareerRow.fromCareerRow(player.name, row);
        if (stat.matches == 0) continue;
        result.add((player: player, stat: stat));
        if (result.length >= limit) break;
      }
      return result;
    } catch (e, st) {
      debugPrint('[StorageService] loadLeaderboard failed: $e');
      debugPrint('$st');
      return [];
    }
  }

  /// Checks the `app_config` table (one row per platform: 'android'/'ios')
  /// against the installed app's version. Returns null when the installed
  /// version is already current, so callers can just do
  /// `if (info != null) showUpdateDialog(info)` without a separate
  /// "is there an update" check. Works for guests too (this table has a
  /// public-read policy, unlike everything else in this file) since an
  /// out-of-date app is exactly the kind of thing a guest needs to know
  /// about as much as a logged-in user.
  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      final platform = Platform.isIOS ? 'ios' : 'android';
      final info = await PackageInfo.fromPlatform();
      final row = await _client.from('app_config').select().eq('platform', platform).maybeSingle();
      if (row == null) return null;

      final latest = row['latest_version'] as String;
      final minRequired = row['min_required_version'] as String? ?? latest;
      final current = info.version;

      if (!_isVersionNewer(latest, current)) return null;

      return UpdateInfo(
        currentVersion: current,
        latestVersion: latest,
        mandatory: _isVersionNewer(minRequired, current),
        storeUrl: row['store_url'] as String,
        message: row['update_message'] as String?,
      );
    } catch (e, st) {
      // Never let a version-check failure block app startup.
      debugPrint('[StorageService] checkForUpdate failed: $e');
      debugPrint('$st');
      return null;
    }
  }

  /// Dotted-version compare (handles "1.4" vs "1.4.0" vs "1.10.0" correctly
  /// - straight string comparison would wrongly say "1.10.0" < "1.4.0").
  static bool _isVersionNewer(String a, String b) {
    final pa = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final pb = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    for (int i = 0; i < (pa.length > pb.length ? pa.length : pb.length); i++) {
      final va = i < pa.length ? pa[i] : 0;
      final vb = i < pb.length ? pb[i] : 0;
      if (va != vb) return va > vb;
    }
    return false;
  }
}