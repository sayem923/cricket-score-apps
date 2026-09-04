import 'package:flutter/material.dart';
import '../../l10n/app_strings.dart';
import '../../services/onboarding_service.dart';

class _OnboardSlide {
  final IconData icon;
  final String titleKey;
  final String bodyKey;
  const _OnboardSlide({required this.icon, required this.titleKey, required this.bodyKey});
}

const _slides = [
  _OnboardSlide(icon: Icons.sports_cricket, titleKey: 'onboard_1_title', bodyKey: 'onboard_1_body'),
  _OnboardSlide(icon: Icons.emoji_events_outlined, titleKey: 'onboard_2_title', bodyKey: 'onboard_2_body'),
  _OnboardSlide(icon: Icons.leaderboard_outlined, titleKey: 'onboard_3_title', bodyKey: 'onboard_3_body'),
  _OnboardSlide(icon: Icons.podcasts, titleKey: 'onboard_4_title', bodyKey: 'onboard_4_body'),
];

/// First-launch walkthrough shown once, before [AuthGate]. Purely visual -
/// it doesn't touch auth state, so it works identically for someone about
/// to log in, sign up, or continue as guest. [OnboardingGate] in main.dart
/// decides whether this ever gets shown at all.
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onDone;
  const OnboardingScreen({super.key, required this.onDone});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pageController = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    await OnboardingService.markSeen();
    widget.onDone();
  }

  void _next() {
    if (_page == _slides.length - 1) {
      _finish();
      return;
    }
    _pageController.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _page == _slides.length - 1;
    return Scaffold(
      backgroundColor: const Color(0xFF00695C),
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 8, top: 4),
                child: TextButton(
                  onPressed: isLast ? null : _finish,
                  child: Text(
                    tr('skip_onboarding'),
                    style: TextStyle(color: Colors.white.withOpacity(isLast ? 0 : 0.8)),
                  ),
                ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _slides.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) {
                  final slide = _slides[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(slide.icon, size: 96, color: Colors.white),
                        const SizedBox(height: 32),
                        Text(
                          tr(slide.titleKey),
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          tr(slide.bodyKey),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 15, height: 1.5),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_slides.length, (i) {
                  final active = i == _page;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: active ? 22 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(active ? 1 : 0.4),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  );
                }),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _next,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF00695C),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: Text(
                    (isLast ? tr('get_started_onboarding') : tr('next_onboarding')).toUpperCase(),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}