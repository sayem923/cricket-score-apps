import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../models/models.dart';
import '../../services/auth_service.dart';
import '../../services/session_service.dart';
import '../../services/storage_service.dart';
import '../../services/locale_service.dart';
import '../../l10n/app_strings.dart';
import '../onboarding/onboarding_screen.dart';
import 'edit_profile_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  UserProfile? _profile;
  bool _loading = true;
  String? _appVersion;

  @override
  void initState() {
    super.initState();
    _load();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _appVersion = info.version);
  }

  Future<void> _load() async {
    final profile = await StorageService.loadProfile();
    if (!mounted) return;
    setState(() {
      _profile = profile;
      _loading = false;
    });
  }

  Future<void> _editProfile() async {
    await Navigator.push(context, MaterialPageRoute(builder: (context) => EditProfileScreen(profile: _profile)));
    _load(); // refresh with whatever was saved
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('log_out_confirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('cancel').toUpperCase())),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('log_out').toUpperCase(), style: const TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed != true) return;
    await AuthService.signOut();
    SessionService.isGuest.value = false;
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthService.currentUser;
    final name = _profile?.name ?? AuthService.currentUserName ?? "Cricket Fan";
    final email = user?.email ?? "-";
    final phone = _profile?.phone;
    final avatarUrl = _profile?.avatarUrl;

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    const headerHeight = 150.0;
    const avatarRadius = 54.0;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.topCenter,
                children: [
                  Container(
                    height: headerHeight,
                    width: double.infinity,
                    color: const Color(0xFF00695C),
                    child: Row(
                      children: [
                        IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.pop(context)),
                        const Spacer(),
                        IconButton(icon: const Icon(Icons.edit_outlined, color: Colors.white), tooltip: "Edit Profile", onPressed: _editProfile),
                      ],
                    ),
                  ),
                  Positioned(
                    top: headerHeight - avatarRadius,
                    child: CircleAvatar(
                      radius: avatarRadius,
                      backgroundColor: Colors.white,
                      child: CircleAvatar(
                        radius: avatarRadius - 4,
                        backgroundColor: const Color(0xFFE0F2F1),
                        backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                        child: avatarUrl == null ? const Icon(Icons.person, size: 50, color: Color(0xFF00695C)) : null,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: avatarRadius + 12),
              Text(name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    _infoRow(tr('phone'), (phone != null && phone.isNotEmpty) ? phone : "-"),
                    const Divider(height: 24),
                    _infoRow(tr('mail'), email),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Container(height: 8, color: const Color(0xFFF5F5F5)),
              _actionTile(Icons.person_outline, tr('profile_details'), onTap: _editProfile, showChevron: true),
              const Divider(height: 1, indent: 56),
              // --- Language toggle ---
              // Rebuilds just this row (not the whole Profile screen) when
              // the language changes, since LocaleService.locale is a
              // ValueNotifier - toggling calls StorageService-style
              // shared_preferences persistence under the hood, so the
              // choice survives app restarts too.
              ValueListenableBuilder<String>(
                valueListenable: LocaleService.locale,
                builder: (context, code, _) {
                  final label = code == 'en' ? 'English' : 'বাংলা';
                  return _actionTile(
                    Icons.language,
                    tr('language'),
                    onTap: LocaleService.toggle,
                    trailingText: label,
                    showChevron: true,
                  );
                },
              ),
              const Divider(height: 1, indent: 56),
              _actionTile(
                Icons.play_circle_outline,
                tr('replay_tutorial'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    // Replaying doesn't touch OnboardingService's "seen"
                    // flag, so this is purely additive - it never changes
                    // what a fresh install shows on first launch.
                    builder: (context) => OnboardingScreen(onDone: () => Navigator.pop(context)),
                  ),
                ),
                showChevron: true,
              ),
              const Divider(height: 1, indent: 56),
              _actionTile(Icons.logout, tr('log_out'), onTap: _logout),
              // Temporary diagnostic tile - only appears once
              // _recordMatchParticipants has actually failed, so it's
              // invisible/no-op once head-to-head sync is confirmed
              // working. Remove this tile (and StorageService.
              // lastMatchParticipantsError) once that's confirmed.
              if (StorageService.lastMatchParticipantsError != null)
                _actionTile(
                  Icons.bug_report_outlined,
                  "Last sync error (debug)",
                  onTap: () => showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Last match-sync error'),
                      content: SingleChildScrollView(
                        child: SelectableText(StorageService.lastMatchParticipantsError ?? ''),
                      ),
                      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
                    ),
                  ),
                  showChevron: true,
                ),
              const SizedBox(height: 24),
              Center(
                child: Text(
                  _appVersion != null ? 'v$_appVersion' : '',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade400, letterSpacing: 0.5),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(color: Colors.grey[500], fontSize: 15)),
        Flexible(child: Text(value, textAlign: TextAlign.right, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
      ],
    );
  }

  Widget _actionTile(IconData icon, String label, {required VoidCallback onTap, bool showChevron = false, String? trailingText}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        child: Row(
          children: [
            Icon(icon, color: Colors.black87),
            const SizedBox(width: 18),
            Expanded(child: Text(label, style: const TextStyle(fontSize: 16, color: Colors.black87))),
            if (trailingText != null)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(trailingText, style: TextStyle(fontSize: 14, color: Colors.grey[500])),
              ),
            if (showChevron) Icon(Icons.chevron_right, color: Colors.grey[400]),
          ],
        ),
      ),
    );
  }
}