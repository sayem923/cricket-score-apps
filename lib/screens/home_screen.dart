import 'package:flutter/material.dart';
import 'match/start_match_screen.dart';
import 'match/match_scorer_screen.dart';
import 'match/match_history_screen.dart';
import 'tournament/tournament_list_screen.dart';
import 'teams/teams_screen.dart';
import 'players/players_screen.dart';
import 'photos/photos_screen.dart';
import 'profile/profile_screen.dart';
import 'live/watch_live_screen.dart';
import '../services/session_service.dart';
import '../services/auth_service.dart';
import '../services/storage_service.dart';
import '../models/models.dart';
import '../utils/globals.dart';
import '../utils/extensions.dart';
import '../widgets/update_dialog.dart';
import '../widgets/sync_status_banner.dart';
import '../widgets/tournament_sync_status_banner.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_dimens.dart';
import '../l10n/app_strings.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  MatchDraft? _draft;
  bool _checkingDraft = true;
  String? _avatarUrl;
  String? _profileName;

  int _matchesCount = 0;
  int _teamsCount = 0;
  int _tournamentsCount = 0;

  @override
  void initState() {
    super.initState();
    _loadDraft();
    _loadProfile();
    _loadStats();
    _checkForUpdate();
  }

  // Runs once per app launch (HomeScreen is the single post-auth landing
  // point for both guests and logged-in users - see AuthGate). Silently
  // does nothing if the check fails or the app is already current.
  Future<void> _checkForUpdate() async {
    final info = await StorageService.checkForUpdate();
    if (info != null && mounted) {
      showUpdateDialog(context, info);
    }
  }

  Future<void> _loadProfile() async {
    if (AuthService.currentUser == null) return;
    final profile = await StorageService.loadProfile();
    if (!mounted) return;
    setState(() {
      _avatarUrl = profile?.avatarUrl;
      _profileName = profile?.name;
    });
  }

  Future<void> _loadStats() async {
    final quickMatches = await StorageService.loadQuickMatchHistory();
    int matches = quickMatches.where((m) => m.isComplete).length;

    if (!globalTournamentsLoaded) {
      globalTournaments = await StorageService.loadTournaments();
      globalTournamentsLoaded = true;
    }

    for (var t in globalTournaments) {
      matches += t.matches.where((m) => m.isCompleted).length;
    }

    final teams = await StorageService.loadTeams();

    if (!mounted) return;
    setState(() {
      _matchesCount = matches;
      _teamsCount = teams.length;
      _tournamentsCount = globalTournaments.length;
    });
  }

  Future<void> _loadDraft() async {
    final draft = await StorageService.loadMatchDraft();
    if (!mounted) return;
    setState(() {
      _draft = draft;
      _checkingDraft = false;
    });
  }

  Future<void> _resumeDraft() async {
    if (_draft == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => MatchScorerScreen(draft: _draft)),
    );
    _loadDraft();
  }

  Future<void> _discardDraft() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(tr('discard_match_title'), style: const TextStyle(color: AppColors.textPrimary)),
        content: Text(
          tr('discard_match_body'),
          style: AppTextStyles.bodySecondary,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('cancel').toUpperCase(), style: AppTextStyles.bodySecondary),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('discard').toUpperCase(), style: const TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await StorageService.clearMatchDraft();
    if (!mounted) return;
    setState(() => _draft = null);
  }

  void _exitGuestMode() {
    SessionService.isGuest.value = false;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _openAccount() async {
    if (AuthService.currentUser != null) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const ProfileScreen()),
      );
      _loadProfile();
    } else {
      _exitGuestMode();
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthService.currentUser;
    final isGuest = SessionService.isGuest.value;
    final greetingName = user != null ? (_profileName ?? AuthService.currentUserName ?? tr('cricket_fan')) : tr('guest');

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // --- Header Banner ---
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppColors.primaryGradientStart, AppColors.primaryGradientEnd],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl, AppSpacing.xxl, AppSpacing.xl, AppSpacing.xxl,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user != null ? tr('welcome_back') : tr('welcome'),
                          style: AppTextStyles.overline,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          greetingName,
                          style: AppTextStyles.h2,
                        ),
                      ],
                    ),
                    GestureDetector(
                      onTap: _openAccount,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: AppColors.primary, width: 1.5),
                        ),
                        child: CircleAvatar(
                          radius: 22,
                          backgroundColor: AppColors.primaryDark,
                          backgroundImage: _avatarUrl != null ? NetworkImage(_avatarUrl!) : null,
                          child: _avatarUrl == null
                              ? const Icon(Icons.person, color: AppColors.textPrimary, size: 24)
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Shows only when there's a locally-saved match still waiting
              // to reach the cloud (see SyncStatusBanner doc comment) - a
              // guest browsing normally, fully synced user etc. never see
              // this at all.
              const SyncStatusBanner(),

              // Same idea, but for tournament data specifically (#7 -
              // offline mode + auto-sync). Usually self-resolves via
              // ConnectivityService the moment the network returns - this
              // is mostly a visible "it's handled" confirmation plus a
              // manual fallback.
              const TournamentSyncStatusBanner(),

              const SizedBox(height: AppSpacing.lg),

              // --- Stats Overview ---
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(color: AppColors.border),
                    boxShadow: AppShadows.card,
                  ),
                  child: Row(
                    children: [
                      Expanded(child: _statColumn("$_matchesCount", tr('matches'))),
                      Container(width: 1, height: 32, color: AppColors.border),
                      Expanded(child: _statColumn("$_teamsCount", tr('teams'))),
                      Container(width: 1, height: 32, color: AppColors.border),
                      Expanded(child: _statColumn("$_tournamentsCount", tr('tournaments'))),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: AppSpacing.lg),

              // --- Unfinished Draft Notification ---
              if (!_checkingDraft && _draft != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      border: Border.all(color: AppColors.info.withOpacity(0.5)),
                    ),
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.history_toggle_off, color: AppColors.info, size: 20),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                "${tr('unfinished')}: ${_draft!.currentBattingTeam} vs ${_draft!.currentBowlingTeam} (${_draft!.totalRuns}/${_draft!.totalWickets})",
                                style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Row(
                          children: [
                            ElevatedButton.icon(
                              onPressed: _resumeDraft,
                              icon: const Icon(Icons.play_arrow_rounded, size: 18),
                              label: Text(tr('resume')),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.infoDark,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.md),
                            TextButton(
                              onPressed: _discardDraft,
                              child: Text(tr('discard'), style: const TextStyle(color: AppColors.errorLight)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

              if (!_checkingDraft && _draft != null) const SizedBox(height: AppSpacing.lg),

              // --- Guest Mode Banner ---
              if (isGuest)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.guestBannerBg,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      border: Border.all(color: AppColors.guestBannerBorder.withOpacity(0.4)),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline, size: 16, color: AppColors.warningLight),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            tr('guest_mode_banner'),
                            style: const TextStyle(fontSize: 12, color: AppColors.guestBannerText),
                          ),
                        ),
                        TextButton(
                          onPressed: _exitGuestMode,
                          child: Text(tr('sign_up'), style: const TextStyle(fontSize: 12, color: AppColors.warning)),
                        ),
                      ],
                    ),
                  ),
                ),

              if (isGuest) const SizedBox(height: AppSpacing.lg),

              // --- Action Grid Cards ---
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _featureCard(
                            tr('quick_match'),
                            Icons.sports_cricket,
                            AppColors.accentAmberBg,
                            AppColors.accentAmber,
                            () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (context) => const StartMatchScreen()),
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: _featureCard(
                            tr('tournament'),
                            Icons.emoji_events,
                            AppColors.accentEmeraldBg,
                            AppColors.accentEmerald,
                            () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (context) => const TournamentListScreen()),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: _featureCard(
                            tr('history'),
                            Icons.history,
                            AppColors.accentSapphireBg,
                            AppColors.accentSapphire,
                            () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (context) => const MatchHistoryScreen()),
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: _featureCard(
                            tr('teams'),
                            Icons.shield,
                            AppColors.accentIndigoBg,
                            AppColors.accentIndigo,
                            () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (context) => const TeamsScreen()),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: _featureCard(
                            tr('players'),
                            Icons.people,
                            AppColors.accentVioletBg,
                            AppColors.accentViolet,
                            () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (context) => const PlayersScreen()),
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: _featureCard(
                            tr('photos'),
                            Icons.photo_camera,
                            AppColors.accentRoseBg,
                            AppColors.accentRose,
                            () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (context) => const PhotosScreen()),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: _featureCard(
                            tr('watch_live'),
                            Icons.podcasts,
                            AppColors.accentRedBg,
                            AppColors.accentRed,
                            () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (context) => const WatchLiveScreen()),
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        const Expanded(child: SizedBox()),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xxl),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statColumn(String value, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: AppTextStyles.statValue),
        const SizedBox(height: 2),
        Text(label, style: AppTextStyles.statLabel),
      ],
    );
  }

  Widget _featureCard(String title, IconData icon, Color bg, Color iconColor, VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Container(
          height: 110,
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: iconColor.withOpacity(0.15)),
            boxShadow: AppShadows.cardSmall,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 22, color: iconColor),
              ),
              Text(title, style: AppTextStyles.subtitle),
            ],
          ),
        ),
      ),
    );
  }
}