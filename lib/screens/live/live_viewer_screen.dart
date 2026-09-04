import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import '../../models/models.dart';
import '../../services/storage_service.dart';
import '../../utils/extensions.dart';
import '../../l10n/app_strings.dart';
import 'facebook_video_player.dart';
import 'video_source_detector.dart';
import 'web_iframe_stub.dart' if (dart.library.html) 'web_iframe_web.dart';

class LiveViewerScreen extends StatefulWidget {
  final String broadcastId;
  const LiveViewerScreen({super.key, required this.broadcastId});

  @override
  State<LiveViewerScreen> createState() => _LiveViewerScreenState();
}

class _LiveViewerScreenState extends State<LiveViewerScreen> {
  LiveBroadcast? _broadcast;
  bool _ended = false;
  Timer? _pollTimer;
  YoutubePlayerController? _ytController;
  String? _loadedVideoId;
  bool _muted = false;
  bool _isPaused = false;
  // true = video fills/crops the screen (no black bars); false = video
  // shows in full (native 16:9), letterboxed if the screen is a
  // different ratio. The scorecard bar tracks whichever the video is
  // doing, so it always lines up with the video's actual visible edges.
  bool _videoCover = true;
  String? _embedUrl;

  VideoSourceType _sourceType = VideoSourceType.unsupported;
  final ValueNotifier<bool> _mutedNotifier = ValueNotifier<bool>(false);
  // GlobalKey so the underlying video player (YouTube WebView / Facebook
  // player) keeps its element identity - and doesn't get torn down and
  // reloaded (the blank-flash bug) - even though the fit/cover toggle
  // rebuilds different wrapper widgets above it.
  final GlobalKey _videoElementKey = GlobalKey();
  String? _facebookUrl;

  bool _showControls = true;
  Timer? _hideControlsTimer;

  int? _lastTotalWickets;
  int? _lastExtras;
  String? _lastBallId; 
  String? _splashText;
  String? _splashSubtitle;
  Color _splashColor = Colors.green;
  List<Color> _splashGradient = [Colors.green, Colors.teal];
  bool _showSplash = false;
  Timer? _splashTimer;

  int _tournamentFoursBefore = 0;
  int _tournamentSixesBefore = 0;
  String? _fetchedBoundariesForTournamentId;

  DateTime? _lastShownSpotlightAt;
  SpotlightCard? _visibleSpotlight;

  DateTime? _lastShownGraphAt;
  BroadcastGraphData? _visibleGraph;
  DateTime? _lastShownOversAt;
  BroadcastOversData? _visibleOvers;
  DateTime? _lastShownBattleAt;
  BroadcastPlayerBattle? _visibleBattle;
  DateTime? _lastShownPlayingXIAt;
  BroadcastPlayingXI? _visiblePlayingXI;
  DateTime? _lastShownScorecardAt;
  BroadcastScorecardData? _visibleScorecard;
  DateTime? _lastShownBowlingAt;
  BroadcastBowlingData? _visibleBowling;

  // Only one of the six broadcast overlays above (spotlight/graph/overs/
  // battle/playingXI/scorecard/bowling) is ever visible at once - showing a
  // new one cancels whichever was showing (see _showBroadcastOverlay) and
  // restarts this single shared timer, so two quick button taps on the
  // scorer's side can never leave two cards visible - and overlapping - on
  // the viewer's screen.
  Timer? _overlayTimer;

  // True while a full-screen broadcast card (graph/overs/battle/playingXI/
  // scorecard/bowling) is up - drives the scorecard's slide-away/slide-back
  // animation.
  bool get _hasFullScreenOverlay =>
      _visibleGraph != null || _visibleOvers != null || _visibleBattle != null || _visiblePlayingXI != null || _visibleScorecard != null || _visibleBowling != null;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _refresh();
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) => _refresh());
    _startHideControlsTimer();
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _pollTimer?.cancel();
    _hideControlsTimer?.cancel();
    _splashTimer?.cancel();
    _overlayTimer?.cancel();
    _ytController?.dispose();
    _mutedNotifier.dispose();
    super.dispose();
  }

  void _startHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() => _showControls = false);
      }
    });
  }

  void _toggleControlsVisibility() {
    setState(() => _showControls = !_showControls);
    if (_showControls) {
      _startHideControlsTimer();
    }
  }

  void _triggerSplash(String text, Color primaryColor, List<Color> gradient, {String? subtitle}) {
    _splashTimer?.cancel();

    setState(() {
      _showSplash = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {
          _splashText = text;
          _splashSubtitle = subtitle;
          _splashColor = primaryColor;
          _splashGradient = gradient;
          _showSplash = true;
        });

        _splashTimer = Timer(const Duration(milliseconds: 2200), () {
          if (mounted) {
            setState(() => _showSplash = false);
          }
        });
      }
    });
  }

  // Shows exactly one broadcast overlay (spotlight/graph/overs/battle) at a
  // time: clears whatever the other three fields currently hold, applies
  // this one via [show], and schedules [hide] on the single shared timer.
  // This is what stops two quick scorer button-taps from leaving two cards
  // visible - and stacked on top of each other - on the viewer's screen.
  void _showBroadcastOverlay({
    required VoidCallback show,
    required VoidCallback hide,
    required Duration duration,
  }) {
    _overlayTimer?.cancel();
    setState(() {
      _visibleSpotlight = null;
      _visibleGraph = null;
      _visibleOvers = null;
      _visibleBattle = null;
      _visiblePlayingXI = null;
      _visibleScorecard = null;
      _visibleBowling = null;
      show();
    });
    _overlayTimer = Timer(duration, () {
      if (mounted) setState(hide);
    });
  }

  Future<void> _refresh() async {
    final broadcast = await StorageService.fetchLiveBroadcast(widget.broadcastId);
    if (!mounted) return;
    if (broadcast == null) {
      setState(() => _ended = true);
      _pollTimer?.cancel();
      return;
    }

    if (broadcast.tournamentId != null && _fetchedBoundariesForTournamentId != broadcast.tournamentId) {
      _fetchedBoundariesForTournamentId = broadcast.tournamentId;
      final totals = await StorageService.loadTournamentBoundaryTotals(broadcast.tournamentId!);
      if (!mounted) return;
      _tournamentFoursBefore = totals.fours;
      _tournamentSixesBefore = totals.sixes;
    }

    if (broadcast.spotlight != null && broadcast.spotlight!.at != _lastShownSpotlightAt) {
      _lastShownSpotlightAt = broadcast.spotlight!.at;
      _showBroadcastOverlay(
        show: () => _visibleSpotlight = broadcast.spotlight,
        hide: () => _visibleSpotlight = null,
        duration: const Duration(seconds: 8),
      );
    }

    if (broadcast.graph != null && broadcast.graph!.at != _lastShownGraphAt) {
      _lastShownGraphAt = broadcast.graph!.at;
      _showBroadcastOverlay(
        show: () => _visibleGraph = broadcast.graph,
        hide: () => _visibleGraph = null,
        duration: const Duration(seconds: 10),
      );
    } else if (broadcast.graph != null && _visibleGraph != null && broadcast.graph!.at == _lastShownGraphAt) {
      // Same card still on screen, but the scorer keeps refreshing its
      // ball-by-ball arrays under the same [at] (see _pushLiveUpdate) -
      // pick up the newer data on every poll so the worm actually moves
      // instead of staying frozen at whatever it looked like the moment
      // "Compare" was tapped. setState directly (not _showBroadcastOverlay)
      // so this never restarts the entrance animation or the auto-hide timer.
      setState(() => _visibleGraph = broadcast.graph);
    }

    if (broadcast.overs != null && broadcast.overs!.at != _lastShownOversAt) {
      _lastShownOversAt = broadcast.overs!.at;
      _showBroadcastOverlay(
        show: () => _visibleOvers = broadcast.overs,
        hide: () => _visibleOvers = null,
        duration: const Duration(seconds: 10),
      );
    } else if (broadcast.overs != null && _visibleOvers != null && broadcast.overs!.at == _lastShownOversAt) {
      // Same card still on screen, but the scorer keeps refreshing its bars
      // under the same [at] (see _pushLiveUpdate's _buildRunsPerOverData
      // call) - pick up the newer data on every poll so the bars actually
      // move instead of staying frozen at whatever they looked like the
      // moment "Runs/Over" was tapped. setState directly (not
      // _showBroadcastOverlay) so this never restarts the entrance
      // animation or the auto-hide timer - same pattern as the Comparison
      // graph above.
      setState(() => _visibleOvers = broadcast.overs);
    }

    if (broadcast.playerBattle != null && broadcast.playerBattle!.at != _lastShownBattleAt) {
      _lastShownBattleAt = broadcast.playerBattle!.at;
      _showBroadcastOverlay(
        show: () => _visibleBattle = broadcast.playerBattle,
        hide: () => _visibleBattle = null,
        duration: const Duration(seconds: 8),
      );
    }

    if (broadcast.playingXI != null && broadcast.playingXI!.at != _lastShownPlayingXIAt) {
      _lastShownPlayingXIAt = broadcast.playingXI!.at;
      _showBroadcastOverlay(
        show: () => _visiblePlayingXI = broadcast.playingXI,
        hide: () => _visiblePlayingXI = null,
        duration: const Duration(seconds: 10),
      );
    }

    if (broadcast.scorecard != null && broadcast.scorecard!.at != _lastShownScorecardAt) {
      _lastShownScorecardAt = broadcast.scorecard!.at;
      _showBroadcastOverlay(
        show: () => _visibleScorecard = broadcast.scorecard,
        hide: () => _visibleScorecard = null,
        duration: const Duration(seconds: 10),
      );
    }

    if (broadcast.bowling != null && broadcast.bowling!.at != _lastShownBowlingAt) {
      _lastShownBowlingAt = broadcast.bowling!.at;
      _showBroadcastOverlay(
        show: () => _visibleBowling = broadcast.bowling,
        hide: () => _visibleBowling = null,
        duration: const Duration(seconds: 10),
      );
    }

    final latestBallLabel = broadcast.recentBalls.isNotEmpty ? broadcast.recentBalls.first.trim().toUpperCase() : '';
    final currentBallIdentifier = "${broadcast.matchBalls}_${broadcast.recentBalls.length}_$latestBallLabel";

    if (_lastBallId != null && _lastBallId != currentBallIdentifier) {
      final wicketDiff = broadcast.totalWickets - (_lastTotalWickets ?? broadcast.totalWickets);
      final extrasDiff = broadcast.extras - (_lastExtras ?? broadcast.extras);
      final isTournament = broadcast.tournamentId != null;

      if (wicketDiff > 0) {
        _triggerSplash(
          "OUT!",
          const Color(0xFFDC2626),
          [const Color(0xFF991B1B), const Color(0xFFEF4444)],
        );
      } else if (extrasDiff > 0 && latestBallLabel.contains('NB')) {
        _triggerSplash(
          "NO BALL!",
          const Color(0xFFD97706),
          [const Color(0xFF92400E), const Color(0xFFF59E0B)],
        );
      } else if (latestBallLabel == '6' || latestBallLabel == '6B') {
        final total = _tournamentSixesBefore + broadcast.matchSixes;
        _triggerSplash(
          "SIX!",
          const Color(0xFF2563EB),
          [const Color(0xFF1E3A8A), const Color(0xFF3B82F6)],
          subtitle: isTournament ? "Tournament 6s: $total" : "Match 6s: ${broadcast.matchSixes}",
        );
      } else if (latestBallLabel == '4' || latestBallLabel == '4B') {
        final total = _tournamentFoursBefore + broadcast.matchFours;
        _triggerSplash(
          "FOUR!",
          const Color(0xFF16A34A),
          [const Color(0xFF14532D), const Color(0xFF22C55E)],
          subtitle: isTournament ? "Tournament 4s: $total" : "Match 4s: ${broadcast.matchFours}",
        );
      }
    }

    _lastBallId = currentBallIdentifier;
    _lastTotalWickets = broadcast.totalWickets;
    _lastExtras = broadcast.extras;

    setState(() => _broadcast = broadcast);

    if (broadcast.videoUrl != null && broadcast.videoUrl!.isNotEmpty) {
      final sourceInfo = detectVideoSource(broadcast.videoUrl!);
      _sourceType = sourceInfo.type;

      if (sourceInfo.type == VideoSourceType.youtube) {
        final videoId = sourceInfo.id;
        if (videoId != null && videoId != _loadedVideoId) {
          _loadedVideoId = videoId;
          if (kIsWeb) {
            _setupWebEmbed(videoId);
          } else {
            _setupYoutubePlayer(videoId);
          }
        }
      } else if (sourceInfo.type == VideoSourceType.facebook) {
        if (_facebookUrl != broadcast.videoUrl!) {
          _facebookUrl = broadcast.videoUrl!;
          if (kIsWeb) {
            final embedUrl = buildFacebookEmbedUrl(_facebookUrl!, _muted);
            if (mounted) setState(() => _embedUrl = embedUrl);
          } else {
            if (mounted) setState(() {});
          }
        }
      }
    }
  }

  void _setupWebEmbed(String videoId) {
    final mute = _muted ? 1 : 0;
    final url = 'https://www.youtube.com/embed/$videoId'
        '?autoplay=1&mute=$mute&controls=0&playsinline=1&rel=0&modestbranding=1'
        '&iv_load_policy=3&disablekb=1&fs=0&cc_load_policy=0&enablejsapi=1';
    if (mounted) setState(() => _embedUrl = url);
  }

  void _setupYoutubePlayer(String videoId) {
    _ytController?.dispose();
    _ytController = YoutubePlayerController(
      initialVideoId: videoId,
      flags: const YoutubePlayerFlags(
        autoPlay: true,
        mute: false,
        hideControls: true,
        controlsVisibleAtStart: false,
        enableCaption: false,
        isLive: true,
        forceHD: false,
      ),
    );

    _ytController!.addListener(() {
      // Auto-recovers from buffering stalls by resuming playback - but
      // must not fight an intentional pause (_isPaused), or the pause
      // button pauses for an instant and then immediately un-pauses.
      if (mounted && !_isPaused && _ytController!.value.isReady && !_ytController!.value.isPlaying) {
        _ytController!.play();
      }
    });

    if (mounted) setState(() {});
  }

  void _toggleMute() {
    _startHideControlsTimer();
    setState(() => _muted = !_muted);
    _mutedNotifier.value = _muted;

    if (_sourceType == VideoSourceType.facebook && kIsWeb && _facebookUrl != null) {
      final embedUrl = buildFacebookEmbedUrl(_facebookUrl!, _muted);
      setState(() => _embedUrl = embedUrl);
    } else if (kIsWeb) {
      if (_loadedVideoId != null) _setupWebEmbed(_loadedVideoId!);
    } else if (_ytController != null) {
      if (_muted) {
        _ytController!.mute();
      } else {
        _ytController!.unMute();
      }
    }
  }

  void _togglePlayPause() {
    _startHideControlsTimer();
    setState(() => _isPaused = !_isPaused);
    if (!kIsWeb && _ytController != null) {
      if (_isPaused) {
        _ytController!.pause();
      } else {
        _ytController!.play();
      }
    }
    // Web iframe and Facebook (via WebView) playback controls aren't wired
    // up here - pausing there would need a postMessage/JS bridge like the
    // mute toggle already has for Facebook. Native YouTube is the common
    // case this button is for.
  }

  void _toggleVideoFit() {
    _startHideControlsTimer();
    setState(() => _videoCover = !_videoCover);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _ended
          ? SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    "This live match has ended.",
                    style: TextStyle(color: Colors.grey[400], fontSize: 16),
                  ),
                ),
              ),
            )
          : _broadcast == null
              ? const Center(child: CircularProgressIndicator())
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final isWebDesktop = kIsWeb && constraints.maxWidth > 700;

                    // Where the video's actual visible edges land, so the
                    // scorecard (and nothing else) can be aligned to them
                    // instead of the raw screen edges. In "cover" mode the
                    // video already fills the screen, so this is zero; in
                    // "fit" mode the video always matches full height (see
                    // _CoverFit) and only ever pillarboxes left/right, so
                    // there's no bottom inset to account for either.
                    const videoAspect = 16 / 9;
                    double videoLeftInset = 0, videoRightInset = 0;
                    if (!_videoCover && !kIsWeb) {
                      final videoW = constraints.maxHeight * videoAspect;
                      videoLeftInset = (constraints.maxWidth - videoW) / 2;
                      if (videoLeftInset < 0) videoLeftInset = 0;
                      videoRightInset = videoLeftInset;
                    }

                    final videoChild = _sourceType == VideoSourceType.facebook
                        ? (kIsWeb
                            ? (_embedUrl != null
                                ? buildWebIframe(_embedUrl!)
                                : const Center(child: CircularProgressIndicator(color: Colors.white)))
                            : (_facebookUrl != null
                                ? FacebookVideoPlayer(
                                    videoUrl: _facebookUrl!,
                                    mutedListenable: _mutedNotifier,
                                  )
                                : const Center(child: CircularProgressIndicator(color: Colors.white))))
                        : (kIsWeb
                            ? (_embedUrl != null
                                ? buildWebIframe(_embedUrl!)
                                : const Center(child: CircularProgressIndicator(color: Colors.white)))
                            : (_ytController != null
                                ? YoutubePlayer(
                                    controller: _ytController!,
                                    showVideoProgressIndicator: false,
                                    onReady: () => _ytController?.play(),
                                  )
                                : const Center(child: CircularProgressIndicator(color: Colors.white))));

                    // Web iframe already has its own crop trick baked in
                    // (see web_iframe_web.dart) - the cover/fit toggle only
                    // applies to the native players. The video widget itself
                    // is wrapped in a GlobalKey (KeyedSubtree) so it keeps
                    // its element/state - and the native player underneath
                    // never gets torn down and reloaded (the blank-flash
                    // bug) - regardless of how the wrapper shape around it
                    // changes when toggling fit/cover.
                    final keyedVideoChild = KeyedSubtree(key: _videoElementKey, child: videoChild);
                    final fittedVideoChild = kIsWeb
                        ? keyedVideoChild
                        : _CoverFit(
                            aspectRatio: videoAspect,
                            fit: _videoCover ? BoxFit.cover : BoxFit.contain,
                            child: keyedVideoChild,
                          );

                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _toggleControlsVisibility,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Positioned.fill(
                            child: fittedVideoChild,
                          ),

                          Positioned.fill(
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeOut,
                              opacity: _showSplash ? 1.0 : 0.0,
                              child: IgnorePointer(
                                child: Stack(
                                  children: [
                                    if (_showSplash)
                                      BackdropFilter(
                                        filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
                                        child: Container(color: Colors.black.withOpacity(0.35)),
                                      ),
                                    Center(
                                      child: AnimatedScale(
                                        scale: _showSplash ? 1.0 : 0.3,
                                        duration: const Duration(milliseconds: 450),
                                        curve: Curves.elasticOut,
                                        child: AnimatedRotation(
                                          turns: _showSplash ? 0 : -0.03,
                                          duration: const Duration(milliseconds: 400),
                                          curve: Curves.easeOutBack,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 50, vertical: 12),
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                colors: _splashGradient,
                                                begin: Alignment.topLeft,
                                                end: Alignment.bottomRight,
                                              ),
                                              borderRadius: BorderRadius.circular(16),
                                              border: Border.all(
                                                color: Colors.white.withOpacity(0.8),
                                                width: 2.5,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: _splashColor.withOpacity(0.9),
                                                  blurRadius: 40,
                                                  spreadRadius: 15,
                                                ),
                                                const BoxShadow(
                                                  color: Colors.black87,
                                                  blurRadius: 20,
                                                  offset: Offset(0, 10),
                                                )
                                              ],
                                            ),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  "LIVE EVENT",
                                                  style: TextStyle(
                                                    color: Colors.white.withOpacity(0.9),
                                                    fontSize: isWebDesktop ? 14 : 10,
                                                    fontWeight: FontWeight.w800,
                                                    letterSpacing: 4.0,
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  _splashText ?? "",
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontSize: isWebDesktop ? 76 : 52,
                                                    fontWeight: FontWeight.w900,
                                                    letterSpacing: 8.0,
                                                    fontStyle: FontStyle.italic,
                                                    shadows: const [
                                                      Shadow(
                                                        offset: Offset(3, 4),
                                                        blurRadius: 12,
                                                        color: Colors.black87,
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                if (_splashSubtitle != null) ...[
                                                  const SizedBox(height: 6),
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                                    decoration: BoxDecoration(
                                                      color: Colors.black.withOpacity(0.25),
                                                      borderRadius: BorderRadius.circular(12),
                                                    ),
                                                    child: Text(
                                                      _splashSubtitle!,
                                                      style: TextStyle(
                                                        color: Colors.white.withOpacity(0.95),
                                                        fontSize: isWebDesktop ? 15 : 11,
                                                        fontWeight: FontWeight.w700,
                                                        letterSpacing: 0.6,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),

                          if (_broadcast!.isFreeHit)
                            Positioned(
                              top: 12,
                              left: 0,
                              right: 0,
                              child: IgnorePointer(
                                child: Center(
                                  child: AnimatedOpacity(
                                    duration: const Duration(milliseconds: 250),
                                    opacity: _broadcast!.isFreeHit ? 1.0 : 0.0,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFEA580C),
                                        borderRadius: BorderRadius.circular(20),
                                        boxShadow: [BoxShadow(color: const Color(0xFFEA580C).withOpacity(0.6), blurRadius: 16, spreadRadius: 2)],
                                        border: Border.all(color: Colors.white.withOpacity(0.8), width: 1.5),
                                      ),
                                      child: const Text(
                                        "FREE HIT",
                                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 14, letterSpacing: 2.0),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),

                          if (_visibleSpotlight != null)
                            Positioned(
                              top: 60,
                              left: 0,
                              right: 0,
                              child: IgnorePointer(
                                child: Center(
                                  child: _BroadcastEntrance(
                                    key: ValueKey('spotlight-${_visibleSpotlight!.at}'),
                                    child: _SpotlightCardView(card: _visibleSpotlight!),
                                  ),
                                ),
                              ),
                            ),

                          // FULL-SCREEN BROADCAST CARDS - Runs/Over, Compare
                          // and Battle take over the whole video area (dark
                          // backdrop + centered, enlarged card) instead of
                          // floating as a small strip. The scorecard bar
                          // below animates itself out of the way for as
                          // long as any one of these three is showing (see
                          // _hasFullScreenOverlay), then slides back once
                          // the shared timer clears it.
                          if (_visibleGraph != null)
                            _FullScreenBroadcastOverlay(
                              key: ValueKey('graph-${_visibleGraph!.at}'),
                              leftInset: videoLeftInset,
                              rightInset: videoRightInset,
                              child: _BroadcastGraphView(data: _visibleGraph!),
                            ),

                          if (_visibleOvers != null)
                            _FullScreenBroadcastOverlay(
                              key: ValueKey('overs-${_visibleOvers!.at}'),
                              leftInset: videoLeftInset,
                              rightInset: videoRightInset,
                              child: _BroadcastOversView(
                                data: _visibleOvers!,
                                totalRuns: _broadcast!.totalRuns,
                                totalWickets: _broadcast!.totalWickets,
                              ),
                            ),

                          if (_visibleBattle != null)
                            _FullScreenBroadcastOverlay(
                              key: ValueKey('battle-${_visibleBattle!.at}'),
                              leftInset: videoLeftInset,
                              rightInset: videoRightInset,
                              child: _PlayerBattleView(battle: _visibleBattle!),
                            ),

                          if (_visiblePlayingXI != null)
                            _FullScreenBroadcastOverlay(
                              key: ValueKey('playingxi-${_visiblePlayingXI!.at}'),
                              leftInset: videoLeftInset,
                              rightInset: videoRightInset,
                              child: _PlayingXIView(data: _visiblePlayingXI!),
                            ),

                          if (_visibleScorecard != null)
                            _FullScreenBroadcastOverlay(
                              key: ValueKey('scorecard-${_visibleScorecard!.at}'),
                              leftInset: videoLeftInset,
                              rightInset: videoRightInset,
                              child: _ScorecardBroadcastView(data: _visibleScorecard!),
                            ),

                          if (_visibleBowling != null)
                            _FullScreenBroadcastOverlay(
                              key: ValueKey('bowling-${_visibleBowling!.at}'),
                              leftInset: videoLeftInset,
                              rightInset: videoRightInset,
                              child: _BowlingBroadcastView(data: _visibleBowling!),
                            ),

                          // SCORECARD OVERLAY - aligned to the video's own
                          // visible edges (videoLeftInset/RightInset/
                          // BottomInset), not the raw screen edges, so it
                          // still lines up with the video when "fit" mode
                          // is letterboxing it. Slides down and fades out
                          // while a full-screen broadcast card (above) is
                          // active, then slides back once it clears.
                          Positioned(
                            left: videoLeftInset,
                            right: videoRightInset,
                            bottom: isWebDesktop ? 28 : 10,
                            child: IgnorePointer(
                              ignoring: _hasFullScreenOverlay,
                              child: AnimatedSlide(
                                duration: const Duration(milliseconds: 350),
                                curve: Curves.easeInOut,
                                offset: _hasFullScreenOverlay ? const Offset(0, 0.6) : Offset.zero,
                                child: AnimatedOpacity(
                                  duration: const Duration(milliseconds: 300),
                                  opacity: _hasFullScreenOverlay ? 0.0 : 1.0,
                                  child: SafeArea(
                                    top: false,
                                    left: false,
                                    right: false,
                                    child: Padding(
                                      padding: EdgeInsets.symmetric(horizontal: isWebDesktop ? 40 : 0),
                                      child: _buildBroadcastBar(_broadcast!),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),

                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: AnimatedOpacity(
                              opacity: _showControls ? 1.0 : 0.0,
                              duration: const Duration(milliseconds: 250),
                              child: IgnorePointer(
                                ignoring: !_showControls,
                                child: SafeArea(
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: isWebDesktop ? 32.0 : 16.0,
                                      vertical: isWebDesktop ? 16.0 : 8.0,
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        _circleIconButton(
                                          icon: Icons.arrow_back,
                                          onTap: () => Navigator.of(context).pop(),
                                        ),
                                        Row(
                                          children: [
                                            _circleIconButton(
                                              icon: _isPaused ? Icons.play_arrow : Icons.pause,
                                              onTap: _togglePlayPause,
                                            ),
                                            const SizedBox(width: 10),
                                            _circleIconButton(
                                              icon: _videoCover ? Icons.fit_screen : Icons.crop_free,
                                              onTap: _toggleVideoFit,
                                            ),
                                            const SizedBox(width: 10),
                                            _circleIconButton(
                                              icon: _muted ? Icons.volume_off : Icons.volume_up,
                                              onTap: _toggleMute,
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }

  Widget _circleIconButton({required IconData icon, required VoidCallback onTap}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(icon, color: Colors.white, size: 20),
        onPressed: onTap,
        splashRadius: 20,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        padding: EdgeInsets.zero,
      ),
    );
  }

  // --- SCORECARD OVERLAY ---
  Widget _buildBroadcastBar(LiveBroadcast b) {
    final overs = "${b.matchBalls ~/ 6}.${b.matchBalls % 6}";
    final crr = b.matchBalls > 0 ? (b.totalRuns / (b.matchBalls / 6.0)) : 0.0;
    final battingTeam = b.isSecondInnings ? b.teamB : b.teamA;
    final bowlingTeam = b.isSecondInnings ? b.teamA : b.teamB;

    final remainingRuns = b.targetScore - b.totalRuns;
    final remainingBalls = (b.maxOvers * 6) - b.matchBalls;
    final rrr = (b.isSecondInnings && !b.isMatchOver && remainingBalls > 0)
        ? (remainingRuns / (remainingBalls / 6.0))
        : null;

    if (b.isMatchOver) {
      return Container(
        width: double.infinity,
        color: const Color(0xFF0B0F1C),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              "${battingTeam.toUpperCase()} v ${bowlingTeam.toUpperCase()}  |  ",
              style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold),
            ),
            Flexible(
              child: Text(
                b.matchStatus,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.greenAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      );
    }

    String statLabel;
    String statValue;
    // Scorer-controlled - see LiveBroadcast.statLineMode. RRR/NEED only
    // mean anything once the target is known (2nd innings), so those fall
    // back to CRR otherwise. 'custom' (a free-typed message) is allowed in
    // either innings, as long as the scorer actually typed something -
    // otherwise fall back the same way RRR/NEED do.
    final hasCustomText = (b.statLineCustomText ?? '').trim().isNotEmpty;
    final effectiveMode = (b.statLineMode == 'custom' && hasCustomText)
        ? 'custom'
        : (b.isSecondInnings ? b.statLineMode : 'crr');
    switch (effectiveMode) {
      case 'custom':
        statLabel = "";
        statValue = b.statLineCustomText!.trim();
        break;
      case 'rrr':
        statLabel = "REQUIRED RATE";
        statValue = rrr != null ? rrr.toStringAsFixed(2) : "-";
        break;
      case 'need':
        statLabel = "NEED";
        statValue = (rrr != null) ? "$remainingRuns RUNS OFF $remainingBalls BALLS" : "-";
        break;
      case 'crr':
      default:
        statLabel = "CURRENT RATE";
        statValue = crr.toStringAsFixed(2);
        break;
    }
    // Custom messages read as one plain line - no "LABEL: " prefix, since
    // there's no fixed label for free text the scorer typed themselves.
    final statLineDisplay = effectiveMode == 'custom' ? statValue : "$statLabel: $statValue";

    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Color(0xFF0B0F1C),
        border: Border(top: BorderSide(color: Color(0xFF1F2937), width: 0.5)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // BATTING TEAM + SCORE + TARGET/OVERS
          SizedBox(
            width: 120,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  battingTeam.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                    height: 1.0,
                    letterSpacing: 0.2,
                  ),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              "${b.totalRuns}-${b.totalWickets}",
                              style: const TextStyle(
                                color: Color(0xFF4ADE80),
                                fontWeight: FontWeight.w900,
                                fontSize: 18,
                                height: 1.0,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (b.isSecondInnings)
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Text(
                                        "TARGET ",
                                        style: TextStyle(color: Colors.white54, fontSize: 7.5, fontWeight: FontWeight.w700, height: 1.1),
                                      ),
                                      Text(
                                        "${b.targetScore}",
                                        style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w900, height: 1.1),
                                      ),
                                    ],
                                  ),
                                Text(
                                  "OVERS $overs",
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white54, fontSize: 9.5, fontWeight: FontWeight.w700, height: 1.1),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          
          // MIDDLE SECTION: BATSMAN CAPSULE PILL + scorer-controlled stat line
          Expanded(
            flex: 3,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _battingPill(
                  nonStriker: b.nonStriker,
                  nonStrikerRuns: b.nonStrikerRuns,
                  nonStrikerBalls: b.nonStrikerBalls,
                  striker: b.striker,
                  strikerRuns: b.strikerRuns,
                  strikerBalls: b.strikerBalls,
                ),
                const SizedBox(height: 1),
                Text(
                  statLineDisplay,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 8.5, fontWeight: FontWeight.w800, letterSpacing: 0.2, height: 1.1),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),

          // BOWLING TEAM + BOWLER FIGURES + OVER BALLS
          SizedBox(
            width: 120,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  bowlingTeam.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                    height: 1.0,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 1),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        b.bowler.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Color(0xFF4ADE80), fontWeight: FontWeight.w800, fontSize: 9.5, height: 1.1),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      "${b.bowlerWickets}-${b.bowlerRuns}",
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 9.5, height: 1.1),
                    ),
                    const SizedBox(width: 3),
                    Text(
                      overs,
                      style: const TextStyle(color: Colors.white54, fontSize: 8.5, fontWeight: FontWeight.w700, height: 1.1),
                    ),
                  ],
                ),
                const SizedBox(height: 1),
                _buildOverBalls(b.recentBalls, b.matchBalls),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _battingPill({
    required String nonStriker,
    required int nonStrikerRuns,
    required int nonStrikerBalls,
    required String striker,
    required int strikerRuns,
    required int strikerBalls,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Container(
        height: 22,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white24, width: 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 48,
              child: Container(
                color: const Color(0xFF131B38),
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.only(left: 10, right: 6),
                child: _pillPlayerText(
                  name: nonStriker,
                  runs: nonStrikerRuns,
                  balls: nonStrikerBalls,
                  isStriker: false,
                  textColor: Colors.white,
                ),
              ),
            ),
            Expanded(
              flex: 52,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF16A34A), Color(0xFF4ADE80)],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                ),
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(left: 6, right: 10),
                child: _pillPlayerText(
                  name: striker,
                  runs: strikerRuns,
                  balls: strikerBalls,
                  isStriker: true,
                  textColor: Colors.black,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pillPlayerText({
    required String name,
    required int runs,
    required int balls,
    required bool isStriker,
    required Color textColor,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        if (isStriker) ...[
          Icon(Icons.play_arrow_rounded, size: 12, color: textColor),
          const SizedBox(width: 1),
        ],
        Flexible(
          child: Text(
            name.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: textColor, fontWeight: FontWeight.w800, fontSize: 11.5),
          ),
        ),
        const SizedBox(width: 16),
        Text(
          "$runs",
          style: TextStyle(color: textColor, fontWeight: FontWeight.w900, fontSize: 13.5),
        ),
        const SizedBox(width: 1),
        Text(
          "($balls)",
          style: TextStyle(color: textColor.withOpacity(0.75), fontWeight: FontWeight.w700, fontSize: 9.5),
        ),
      ],
    );
  }

  // --- OVER BALLS: OVERS FINISHED -> BLANK & 0 (DOT) SHOWN ---
  Widget _buildOverBalls(List<String> recentBalls, int totalMatchBalls) {
    final currentOverBallsCount = totalMatchBalls % 6;
    
    List<String> currentOverBalls = [];
    if (currentOverBallsCount > 0 && recentBalls.isNotEmpty) {
      currentOverBalls = recentBalls.take(currentOverBallsCount).toList().reversed.toList();
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(6, (index) {
        if (index < currentOverBalls.length) {
          return Padding(
            padding: const EdgeInsets.only(left: 2.0),
            child: _ballChip(currentOverBalls[index]),
          );
        } else {
          return Container(
            width: 11,
            height: 11,
            margin: const EdgeInsets.only(left: 2.0),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withOpacity(0.25), width: 1),
            ),
          );
        }
      }),
    );
  }

  Widget _ballChip(String label) {
    final raw = label.trim().toUpperCase();
    Color bg = Colors.transparent;
    Color border = Colors.white.withOpacity(0.35);
    Color textColor = Colors.white70;
    bool filled = false;
    String displayLabel = raw;

    if (raw == "W") {
      bg = const Color(0xFFD97706);
      filled = true;
      textColor = Colors.black;
    } else if (raw == "4" || raw == "6") {
      bg = const Color(0xFF16A34A);
      filled = true;
      textColor = Colors.white;
    } else if (raw.contains("NB")) {
      bg = const Color(0xFFEA580C);
      filled = true;
      textColor = Colors.white;
    } else if (raw.contains("WD")) {
      textColor = Colors.white60;
    } else if (raw == "0" || raw == ".") {
      displayLabel = "0"; // 0 (dot) khelle clear '0' dekhabe
      textColor = Colors.white70;
    }

    return Container(
      width: 11,
      height: 11,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? bg : Colors.transparent,
        border: filled ? null : Border.all(color: border, width: 1),
      ),
      child: Text(
        displayLabel,
        style: TextStyle(
          color: textColor,
          fontSize: 6,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

// Full-screen host for the Runs/Over, Compare and Battle broadcast cards:
// a dimming backdrop fades in over the whole video area while the card
// itself scales/fades in on top, centered. Used instead of a small
// floating strip so the card reads clearly even from across a room, the
// way the scorer's "push to viewers' screens" buttons are meant to.
class _FullScreenBroadcastOverlay extends StatelessWidget {
  final Widget child;
  // Kept for call-site compatibility but intentionally ignored - see below.
  final double leftInset;
  final double rightInset;
  const _FullScreenBroadcastOverlay({super.key, required this.child, this.leftInset = 0, this.rightInset = 0});

  @override
  Widget build(BuildContext context) {
    // Confine the dark backdrop + card to the video's own visible width in
    // "fit"/contain mode (leftInset/rightInset), same as the scorecard bar -
    // so the card's width shrinks along with the video instead of spanning
    // the blank pillarbox margins on either side.
    return Positioned(
      left: leftInset,
      right: rightInset,
      top: 0,
      bottom: 0,
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 450),
          curve: Curves.linear,
          builder: (context, t, _) {
            final fade = Curves.easeOut.transform(t).clamp(0.0, 1.0);
            final scale = 0.88 + 0.12 * Curves.easeOutBack.transform(t);
            return Container(
              color: Colors.black.withOpacity(0.7 * fade),
              alignment: Alignment.center,
              child: Opacity(
                opacity: fade,
                child: Transform.scale(
                  scale: scale,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: child,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _BroadcastEntrance extends StatelessWidget {
  final Widget child;
  const _BroadcastEntrance({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 500),
      curve: Curves.linear,
      builder: (context, t, child) {
        final opacity = Curves.easeOut.transform(t).clamp(0.0, 1.0);
        final scale = 0.82 + 0.18 * Curves.easeOutBack.transform(t);
        return Opacity(
          opacity: opacity,
          child: Transform.scale(scale: scale, child: child),
        );
      },
      child: child,
    );
  }
}

class _SpotlightCardView extends StatelessWidget {
  final SpotlightCard card;
  const _SpotlightCardView({required this.card});

  @override
  Widget build(BuildContext context) {
    final roleColor = card.isBatter ? const Color(0xFF16A34A) : const Color(0xFFD97706);
    return Container(
      width: 220,
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withOpacity(0.88), Colors.black.withOpacity(0.75)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: roleColor.withOpacity(0.7), width: 1.5),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.45), blurRadius: 18, offset: const Offset(0, 6))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: roleColor, width: 2)),
            child: CircleAvatar(
              radius: 40,
              backgroundColor: Colors.white.withOpacity(0.12),
              backgroundImage: card.photoUrl != null ? NetworkImage(card.photoUrl!) : null,
              child: card.photoUrl == null ? const Icon(Icons.person, color: Colors.white70, size: 40) : null,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: roleColor, borderRadius: BorderRadius.circular(4)),
            child: Text(
              card.isBatter ? 'NOW BATTING' : 'NOW BOWLING',
              style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 0.8),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            card.name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Container(height: 1, color: Colors.white.withOpacity(0.15)),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: card.isBatter
                ? [
                    _statColumn('${card.matches}', 'Matches'),
                    _statColumn('${card.primaryValue}', 'Runs'),
                    _statColumn(card.average?.toStringAsFixed(1) ?? '-', 'Avg'),
                  ]
                : [
                    _statColumn('${card.matches}', 'Matches'),
                    _statColumn('${card.primaryValue}', 'Wkts'),
                    _statColumn(card.secondaryRate?.toStringAsFixed(1) ?? '-', 'Econ'),
                  ],
          ),
          const SizedBox(height: 10),
          Text(
            '${card.tertiaryLabel}: ${card.tertiaryValue}',
            style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 11.5, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _statColumn(String value, String label) {
    return Column(
      children: [
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 10)),
      ],
    );
  }
}

class _BroadcastGraphView extends StatelessWidget {
  static const _colorA = Color(0xFF38BDF8);
  static const _colorB = Color(0xFFFBBF24);

  final BroadcastGraphData data;
  const _BroadcastGraphView({required this.data});

  @override
  Widget build(BuildContext context) {
    final scoreA = data.teamACumulative.isNotEmpty ? data.teamACumulative.last : 0;
    final scoreB = data.teamBCumulative.isNotEmpty ? data.teamBCumulative.last : 0;
    // FittedBox(scaleDown) fixes the 2nd-innings bottom overflow: once a
    // target/chase message shows up, data.footerText is no longer null and
    // adds an extra row's worth of height to this card. On shorter
    // landscape screens that pushed the card past the available height and
    // clipped its bottom edge. scaleDown only shrinks the card (as a whole,
    // proportionally) when it doesn't fit - it never enlarges it, so 1st
    // innings (no footer, already fits) renders at the exact same size as
    // before.
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          // Light gap above/below just this card (top/bottom edges of the
          // black overlay backdrop). Increase/decrease this number to
          // adjust the gap - only affects the Compare card, not the
          // Runs/Over or other overlay cards.
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: ConstrainedBox(
      // Caps the card's width so it no longer stretches edge-to-edge on
      // wide/landscape screens - it now shrinks to this max and stays
      // centered (the parent _FullScreenBroadcastOverlay already centers
      // its child). Lower this number for an even narrower card.
      constraints: const BoxConstraints(maxWidth: 600),
      child: Container(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.14)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 28, offset: const Offset(0, 10))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('scoring_comparison_caps').toUpperCase(), style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.6)),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _scoreChip(_colorA, data.teamAName, scoreA),
              _scoreChip(_colorB, data.teamBName, scoreB),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 200,
            width: double.infinity,
            child: CustomPaint(
              painter: _WormPainter(a: data.teamACumulative, b: data.teamBCumulative, maxOvers: data.maxOvers, colorA: _colorA, colorB: _colorB),
            ),
          ),
          if (data.footerText != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.08), borderRadius: BorderRadius.circular(8)),
              child: Text(
                data.footerText!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700, letterSpacing: 0.3),
              ),
            ),
          ],
        ],
      ),
      ),
        ),
      ),
      ),
    );
  }

  Widget _scoreChip(Color color, String name, int score) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle, boxShadow: [BoxShadow(color: color.withOpacity(0.6), blurRadius: 6)])),
        const SizedBox(width: 7),
        Text(name, style: const TextStyle(color: Colors.white, fontSize: 14.5, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(width: 7),
        Text('$score', style: TextStyle(color: color, fontSize: 17, fontWeight: FontWeight.w900)),
      ],
    );
  }
}

// Stateful so it can auto-scroll to the latest over on first build and
// whenever a new over lands - the axis reads left-to-right in normal
// chronological order (over 1 leftmost, latest rightmost, matching how
// this chart is read everywhere else in the app) and the viewer never has
// to manually swipe to see the latest bar. Previously this used
// `reverse: true` on the ListView with index 0 = oldest over, which is
// backwards: reverse:true anchors the RESTING scroll position on index 0,
// so it kept the OLDEST over in view by default and put the latest one
// off to the side needing a manual scroll - the opposite of what a live
// viewer wants to see.
class _BroadcastOversView extends StatefulWidget {
  final BroadcastOversData data;
  // Live total, shown in the header score pill (e.g. "124 for 9") - pulled
  // straight from the enclosing LiveBroadcast rather than stored on
  // BroadcastOversData itself, so this stays in sync with the score even
  // while this card is sitting on screen for its full display duration.
  final int totalRuns;
  final int totalWickets;
  const _BroadcastOversView({required this.data, required this.totalRuns, required this.totalWickets});

  @override
  State<_BroadcastOversView> createState() => _BroadcastOversViewState();
}

class _BroadcastOversViewState extends State<_BroadcastOversView> {
  final ScrollController _scrollController = ScrollController();

  // Professional broadcast-graphic palette: deep navy card with a
  // magenta-to-crimson header (matches the network "lower third" look),
  // a cyan-to-blue gradient for completed-over bars, amber/gold for the
  // most recent over (the one viewers actually care about right now), and
  // a crimson dot with a white "W" for each wicket - the same visual
  // language international broadcasts use on their Manhattan/run-rate
  // graphics.
  static const _headerStart = Color(0xFFEC1876);
  static const _headerEnd = Color(0xFFB01158);
  static const _cardTop = Color(0xFF122238);
  static const _cardBottom = Color(0xFF0A1526);
  static const _navy = Color(0xFF0E2A47);
  static const _barTop = Color(0xFF57D6E8);
  static const _barBottom = Color(0xFF1E6FB3);
  static const _currentBarTop = Color(0xFFFFD873);
  static const _currentBarBottom = Color(0xFFE8973A);
  static const _wicketRed = Color(0xFFE0233A);
  static const _gold = Color(0xFFEFC15A);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToLatest());
  }

  @override
  void didUpdateWidget(covariant _BroadcastOversView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.overRuns.length != widget.data.overRuns.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToLatest());
    }
  }

  void _scrollToLatest() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final overRuns = widget.data.overRuns;
    final overWickets = widget.data.overWickets;
    const maxBarHeight = 130.0;
    const barWidth = 22.0;
    const barGap = 10.0;
    const dotSize = 14.0;
    const dotGap = 3.0;
    const runLabelHeight = 16.0;
    const runLabelGap = 4.0;

    final highestRun = overRuns.isEmpty ? 0 : overRuns.reduce((a, b) => a > b ? a : b);
    // Nice round axis ceiling in steps of 4 (0/4/8/12/16-style bands, same
    // idea as the scorer's own worm chart) so the grid lines land on tidy
    // numbers regardless of the actual highest over. The 1.45x pad is
    // deliberate headroom above the tallest bar for the wicket dots to
    // stack into without overlapping the run-number label or getting
    // clipped.
    //
    // BUG FIX (bar height didn't match its own gridlines/number): bar
    // height used to be scaled against a separate `barFillHeight` (78% of
    // maxBarHeight) while the gridlines beside it spanned the FULL
    // maxBarHeight - two different scales on one axis, so every bar
    // visually undershot where its own printed run count said it should
    // reach (an "8" bar read as ~6 against the grid). The 1.45x headroom
    // above already leaves plenty of room for the dots on its own, so bar
    // height now scales against the same maxBarHeight the gridlines use.
    final axisMax = ((((highestRun == 0 ? 8 : highestRun) * 1.45) / 4).ceil() * 4).clamp(4, 100000);

    return ConstrainedBox(
      // Same cap as _BroadcastGraphView's (the "Compare" card) so the two
      // full-screen cards read as the same width instead of one looking
      // shrunk next to the other. Keep this in sync with the maxWidth on
      // _BroadcastGraphView above if you change either one.
      constraints: const BoxConstraints(maxWidth: 600),
      child: ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_cardTop, _cardBottom]),
          border: Border.fromBorderSide(BorderSide(color: Color(0x33FFFFFF), width: 1)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // HEADER - team name on a magenta/crimson gradient bar, live
            // score pill on navy, with a thin gold accent line beneath -
            // the classic broadcast "lower third" treatment.
            Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                gradient: LinearGradient(begin: Alignment.centerLeft, end: Alignment.centerRight, colors: [_headerStart, _headerEnd]),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      '${widget.data.teamName.toUpperCase()} BATTING',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w900, letterSpacing: 0.4),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _navy,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _gold.withOpacity(0.5), width: 1),
                    ),
                    child: Text(
                      '${widget.totalRuns} for ${widget.totalWickets}',
                      style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w900),
                    ),
                  ),
                ],
              ),
            ),
            Container(height: 2, width: double.infinity, color: _gold.withOpacity(0.6)),

            // CHART BODY
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 18, 12),
              child: overRuns.isEmpty
                  ? SizedBox(
                      height: 140,
                      child: Center(
                        child: Text(tr('no_overs_bowled_yet'), style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 13)),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Text(tr('col_runs_caps'), style: TextStyle(color: _gold.withOpacity(0.9), fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 0.5)),
                            const Spacer(),
                            _legendDot(color: _wicketRed, isCircle: true, label: 'Wicket'),
                            const SizedBox(width: 12),
                            _legendDot(color: _currentBarTop, isCircle: false, label: 'This over'),
                          ],
                        ),
                        const SizedBox(height: 8),
                        // BUG FIX (graph "looks wrong" - no exact number to
                        // read): this card used to only convey each over's
                        // total via bar height against the Y-axis
                        // gridlines - fine for a rough shape, but with only
                        // 5 coarse gridlines (steps of axisMax/4) a viewer
                        // eyeballing where a bar lands between two lines
                        // will misjudge the value (e.g. a 10-run bar sitting
                        // between the "8" and "16" lines can easily read as
                        // "8"). The scorer's own local Graph tab already
                        // prints the exact run count above every bar - this
                        // adds that same exact label here so viewers read
                        // the real number instead of estimating it.
                        SizedBox(
                          height: maxBarHeight + 26 + runLabelHeight + runLabelGap,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // FIXED Y-AXIS - offset down by the same
                              // run-label height/gap reserved above every
                              // bar, so its own maxBarHeight zone still
                              // lines up with the bars' maxBarHeight zone
                              // (and hence the gridlines below) exactly.
                              SizedBox(
                                width: 22,
                                height: maxBarHeight + runLabelHeight + runLabelGap,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    SizedBox(height: runLabelHeight + runLabelGap),
                                    SizedBox(
                                      height: maxBarHeight,
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        crossAxisAlignment: CrossAxisAlignment.end,
                                        children: List.generate(5, (i) {
                                          final value = (axisMax * (4 - i) / 4).round();
                                          return Text('$value', style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 10));
                                        }),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 6),

                              // SCROLLABLE PLOT AREA - grid lines are a
                              // fixed (non-scrolling) background layer;
                              // only the bars themselves scroll on top.
                              Expanded(
                                child: Stack(
                                  children: [
                                    Positioned(
                                      top: runLabelHeight + runLabelGap,
                                      left: 0,
                                      right: 0,
                                      height: maxBarHeight,
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: List.generate(5, (_) => Container(height: 1, color: Colors.white.withOpacity(0.08))),
                                      ),
                                    ),
                                    ListView.builder(
                                      controller: _scrollController,
                                      scrollDirection: Axis.horizontal,
                                      itemCount: overRuns.length,
                                      itemBuilder: (context, i) {
                                        final isLatest = i == overRuns.length - 1;
                                        final runs = overRuns[i];
                                        final wkts = i < overWickets.length ? overWickets[i] : 0;
                                        final barHeight = (maxBarHeight * runs / axisMax).clamp(3.0, maxBarHeight);
                                        final gradientColors = isLatest ? [_currentBarTop, _currentBarBottom] : [_barTop, _barBottom];
                                        return Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: barGap / 2),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              // EXACT RUN NUMBER - printed
                                              // above every bar so the
                                              // value never has to be
                                              // estimated from bar height.
                                              SizedBox(
                                                height: runLabelHeight,
                                                child: Text(
                                                  '$runs',
                                                  style: TextStyle(
                                                    color: isLatest ? _gold : Colors.white.withOpacity(0.85),
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(height: runLabelGap),
                                              SizedBox(
                                                width: barWidth,
                                                height: maxBarHeight,
                                                child: Stack(
                                                  clipBehavior: Clip.none,
                                                  alignment: Alignment.bottomCenter,
                                                  children: [
                                                    Container(
                                                      width: barWidth,
                                                      height: barHeight,
                                                      decoration: BoxDecoration(
                                                        gradient: LinearGradient(
                                                          begin: Alignment.topCenter,
                                                          end: Alignment.bottomCenter,
                                                          colors: gradientColors,
                                                        ),
                                                        borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
                                                        boxShadow: [
                                                          BoxShadow(color: gradientColors.first.withOpacity(0.45), blurRadius: 6, offset: const Offset(0, -1)),
                                                        ],
                                                      ),
                                                    ),
                                                    // WICKET DOTS - one small
                                                    // red "W" marker stacked
                                                    // above the bar for each
                                                    // wicket that fell in
                                                    // this over, exactly the
                                                    // way an international
                                                    // broadcast's run-rate
                                                    // graph flags the fall
                                                    // of a wicket against
                                                    // the over it happened
                                                    // in.
                                                    if (wkts > 0)
                                                      Positioned(
                                                        bottom: barHeight + dotGap,
                                                        child: Column(
                                                          mainAxisSize: MainAxisSize.min,
                                                          children: List.generate(wkts, (wi) => Padding(
                                                                padding: EdgeInsets.only(bottom: wi == wkts - 1 ? 0 : dotGap),
                                                                child: Container(
                                                                  width: dotSize,
                                                                  height: dotSize,
                                                                  alignment: Alignment.center,
                                                                  decoration: BoxDecoration(
                                                                    color: _wicketRed,
                                                                    shape: BoxShape.circle,
                                                                    border: Border.all(color: Colors.white, width: 1.4),
                                                                    boxShadow: const [BoxShadow(color: Color(0x77E0233A), blurRadius: 4)],
                                                                  ),
                                                                  child: const Text('W', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w900)),
                                                                ),
                                                              )),
                                                        ),
                                                      ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(height: 6),
                                              Text(
                                                '${i + 1}',
                                                style: TextStyle(
                                                  color: isLatest ? _gold : Colors.white.withOpacity(0.55),
                                                  fontSize: 10.5,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(tr('col_overs_caps'), style: TextStyle(color: _gold.withOpacity(0.9), fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 0.5)),
                      ],
                    ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _legendDot({required Color color, required bool isCircle, required String label}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: isCircle ? BoxShape.circle : BoxShape.rectangle, borderRadius: isCircle ? null : BorderRadius.circular(2)),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: Colors.white.withOpacity(0.65), fontSize: 10.5, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _WormPainter extends CustomPainter {
  final List<int> a;
  final List<int> b;
  final int maxOvers;
  final Color colorA;
  final Color colorB;
  _WormPainter({required this.a, required this.b, required this.maxOvers, required this.colorA, required this.colorB});

  @override
  void paint(Canvas canvas, Size size) {
    const leftAxisWidth = 26.0;
    const bottomAxisHeight = 18.0;
    final chartWidth = size.width - leftAxisWidth;
    final chartHeight = size.height - bottomAxisHeight;
    final maxRuns = ([...a, ...b, 10].reduce((x, y) => x > y ? x : y) * 1.15).ceilToDouble();
    final overs = maxOvers > 1 ? maxOvers : 1;
    // Every entry is one delivery, not one over - the x-axis has to scale
    // against the total number of balls in the innings (this is what
    // makes the line move smoothly ball-by-ball instead of bunching up
    // near the left edge).
    final maxBalls = overs * 6;

    double xFor(int i) => leftAxisWidth + (i / maxBalls).clamp(0.0, 1.0) * chartWidth;
    double xForOver(int over) => leftAxisWidth + (over * 6 / maxBalls).clamp(0.0, 1.0) * chartWidth;
    double yFor(int runs) => chartHeight - (runs / maxRuns) * chartHeight;

    // Dashed horizontal grid lines read cleaner than solid ones on a dark
    // background and match a broadcast graphic's restrained look.
    void drawDashedLine(Offset p1, Offset p2, Paint paint) {
      const dashWidth = 4.0, dashGap = 3.0;
      final total = (p2 - p1).distance;
      final dir = (p2 - p1) / total;
      double covered = 0;
      while (covered < total) {
        final start = p1 + dir * covered;
        final end = p1 + dir * (covered + dashWidth).clamp(0, total);
        canvas.drawLine(start, end, paint);
        covered += dashWidth + dashGap;
      }
    }

    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(0.10)
      ..strokeWidth = 1;
    for (int i = 0; i <= 4; i++) {
      final y = chartHeight * (i / 4);
      drawDashedLine(Offset(leftAxisWidth, y), Offset(size.width, y), gridPaint);
      final label = (maxRuns * (1 - i / 4)).round().toString();
      final tp = TextPainter(
        text: TextSpan(text: label, style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 8.5, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(0, y - tp.height / 2));
    }

    for (final over in {0, (overs / 2).round(), overs}) {
      final tp = TextPainter(
        text: TextSpan(text: '$over', style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 8.5, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
      )..layout();
      final x = xForOver(over).clamp(leftAxisWidth, size.width - tp.width);
      tp.paint(canvas, Offset(x - tp.width / 2, chartHeight + 4));
    }

    void drawSeries(List<int> values, Color color) {
      if (values.isEmpty) return;
      final linePath = Path();
      final fillPath = Path();
      for (int i = 0; i < values.length; i++) {
        final pt = Offset(xFor(i + 1), yFor(values[i]));
        if (i == 0) {
          linePath.moveTo(pt.dx, pt.dy);
          fillPath.moveTo(xFor(0), chartHeight);
          fillPath.lineTo(pt.dx, pt.dy);
        } else {
          linePath.lineTo(pt.dx, pt.dy);
          fillPath.lineTo(pt.dx, pt.dy);
        }
      }
      fillPath.lineTo(xFor(values.length), chartHeight);
      fillPath.close();

      canvas.drawPath(
        fillPath,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color.withOpacity(0.30), color.withOpacity(0.0)],
          ).createShader(Rect.fromLTWH(0, 0, size.width, chartHeight)),
      );
      canvas.drawPath(
        linePath,
        Paint()
          ..color = color
          ..strokeWidth = 2.8
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      final last = Offset(xFor(values.length), yFor(values.last));
      // Soft glow + solid ring, like a live "pulse" marking the current
      // score - this is the point that keeps sliding right as the scorer
      // adds more balls.
      canvas.drawCircle(last, 8, Paint()..color = color.withOpacity(0.25)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
      canvas.drawCircle(last, 4.5, Paint()..color = Colors.black);
      canvas.drawCircle(last, 4.5, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2.2);
    }

    drawSeries(a, colorA);
    drawSeries(b, colorB);
  }

  @override
  bool shouldRepaint(covariant _WormPainter oldDelegate) => oldDelegate.a != a || oldDelegate.b != b;
}

class _PlayerBattleView extends StatelessWidget {
  final BroadcastPlayerBattle battle;
  const _PlayerBattleView({required this.battle});

  @override
  Widget build(BuildContext context) {
    final sr = battle.balls > 0 ? (battle.runs / battle.balls) * 100 : 0.0;
    final avg = battle.dismissals > 0 ? battle.runs / battle.dismissals : null;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.88),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.18)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 22, offset: const Offset(0, 6))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${battle.batsmanName} vs ${battle.bowlerName}', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
          const SizedBox(height: 16),
          if (battle.balls == 0)
            Text(tr('havent_faced_each_other'), style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 14), textAlign: TextAlign.center)
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _battleStat('${battle.runs}', 'Runs'),
                _battleStat('${battle.balls}', 'Balls'),
                _battleStat('${battle.dismissals}', 'Out'),
                _battleStat(avg?.toStringAsFixed(1) ?? '-', 'Avg'),
                _battleStat(sr.toStringAsFixed(0), 'SR'),
              ],
            ),
        ],
      ),
    );
  }

  Widget _battleStat(String value, String label) {
    return Column(
      children: [
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        Text(label, style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 11)),
      ],
    );
  }
}

/// Full-screen "Playing XI" broadcast card - one team's full squad, laid
/// out across as many columns as the available height needs. Pushed by
/// whichever of the two team buttons the scorer taps (see
/// MatchScorerScreen._broadcastPlayingXI). Same full-screen overlay
/// pattern as _PlayerBattleView/_BroadcastOversView above (see
/// _FullScreenBroadcastOverlay).
//
// IMPORTANT: _FullScreenBroadcastOverlay wraps this whole card in an
// IgnorePointer (these broadcast cards are deliberately non-interactive -
// they auto-hide on a timer, taps pass through to the video underneath).
// That means a scrollable list here can NEVER actually be scrolled by the
// viewer - whatever doesn't fit on screen is simply unreachable, not just
// clipped. So instead of one scrollable column, the squad is spread across
// N side-by-side columns, with N computed from the real available height
// so the full squad always fits in view at once, however many players
// there are or however short the screen is.
class _PlayingXIView extends StatelessWidget {
  final BroadcastPlayingXI data;
  const _PlayingXIView({required this.data});

  @override
  Widget build(BuildContext context) {
    // Poster-style palette (matches the reference tournament graphic):
    // yellow -> green -> teal vertical gradient, gold hairline dividers,
    // deep-teal ink for the header text.
    const inkTeal = Color(0xFF0B3B2E);
    const gold = Color(0xFFD9B23C);
    final screenSize = MediaQuery.of(context).size;
    // Wider cap than a single-column card needs - this is a landscape
    // screen with room to spare sideways, and multiple columns need that
    // width to avoid being squeezed into one narrow strip.
    final maxCardWidth = (screenSize.width * 0.82).clamp(360.0, 720.0).toDouble();

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: screenSize.height * 0.85, maxWidth: maxCardWidth),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.25), width: 1.5),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.55), blurRadius: 26, offset: const Offset(0, 10))],
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFE8D34A), Color(0xFF6FA85A), Color(0xFF1F7A6C)],
            stops: [0.0, 0.5, 1.0],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header - trophy + "PLAYING XI" eyebrow + team name, echoing
            // the tournament-poster header (trophy, title, team name)
            // instead of the old flat amber banner. Slightly tighter
            // padding than before so more height is left for the squad
            // grid below on short landscape screens.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
              child: Column(
                children: [
                  const Icon(Icons.emoji_events, color: inkTeal, size: 26),
                  const SizedBox(height: 3),
                  const Text(
                    "PLAYING XI",
                    style: TextStyle(color: inkTeal, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 3),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    data.teamName.toUpperCase(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: inkTeal, fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: 0.3),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            // Body - white poster-style cards in 2 rows (row 1 gets the
            // extra card on an odd squad, matching the reference poster:
            // e.g. 11 players -> 6 on top, 5 below). LayoutBuilder sizes
            // each card from the REAL available width/height so a full
            // 11-player squad never overflows sideways or vertically -
            // no scrolling is possible here (see class doc comment above),
            // so this has to fit in one shot however many players there are.
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final playerCount = data.names.length;
                    if (playerCount == 0) return const SizedBox.shrink();
                    final row1Count = (playerCount / 2).ceil();
                    final row2Count = playerCount - row1Count;
                    final maxRowCount = row1Count; // row 1 is always >= row 2

                    final availableWidth = constraints.maxWidth.isFinite ? constraints.maxWidth : 400.0;
                    final availableHeight = constraints.maxHeight.isFinite ? constraints.maxHeight : 260.0;
                    const cardSpacing = 8.0;

                    // Width-driven card size, then cap by height so 2 rows
                    // of cards (+ spacing) never exceed what's actually left
                    // - whichever constraint is tighter wins.
                    final widthPerCard = (availableWidth - cardSpacing * (maxRowCount - 1)) / maxRowCount;
                    final rowsNeeded = row2Count > 0 ? 2 : 1;
                    final heightPerCard = (availableHeight - cardSpacing * (rowsNeeded - 1)) / rowsNeeded;
                    // Poster cards are a bit taller than wide (photo + name
                    // band) - keep that ratio, but never exceed either the
                    // width or height budget above. Guard the upper bound
                    // so clamp() never sees upper < lower on very cramped
                    // screens (tiny heightPerCard would otherwise crash it).
                    final heightBasedWidthCap = (heightPerCard / 1.35).clamp(44.0, double.infinity);
                    final cardWidth = widthPerCard.clamp(44.0, heightBasedWidthCap).toDouble();
                    final cardHeight = (cardWidth * 1.35).toDouble();

                    Widget buildRow(int start, int count) {
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.start,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (int i = start; i < start + count; i++) ...[
                            if (i > start) const SizedBox(width: cardSpacing),
                            _PlayingXIPlayerTile(
                              name: data.names[i],
                              photoUrl: i < data.photoUrls.length ? data.photoUrls[i] : null,
                              role: i < data.roles.length ? data.roles[i] : null,
                              width: cardWidth,
                              height: cardHeight,
                            ),
                          ],
                        ],
                      );
                    }

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        buildRow(0, row1Count),
                        if (row2Count > 0) ...[
                          const SizedBox(height: cardSpacing),
                          buildRow(row1Count, row2Count),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
/// One player's card inside the Playing XI grid, styled after the
/// reference tournament-squad poster: a white rounded card with the
/// player's photo on top and a solid navy name band pinned to the bottom.
/// Shows the registry photo when [photoUrl] resolved to one (see
/// MatchScorerScreen._broadcastPlayingXI); otherwise falls back to a
/// generic silhouette placeholder - never leaves the slot blank, and
/// never blocks on network state (a failed/slow load just shows the
/// placeholder instead of a broken-image icon on live viewers' screens).
/// [width]/[height] are computed by the caller from the real available
/// space so a full 11-player squad always fits without overflowing.
class _PlayingXIPlayerTile extends StatelessWidget {
  final String name;
  final String? photoUrl;
  final String? role;
  final double width;
  final double height;

  const _PlayingXIPlayerTile({
    required this.name,
    required this.photoUrl,
    required this.role,
    required this.width,
    required this.height,
  });

  static const _navy = Color(0xFF0B1F3A);
  static const _roleRed = Color(0xFFCC1F2E);

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photoUrl != null && photoUrl!.trim().isNotEmpty;
    final hasRole = role != null && role!.trim().isNotEmpty;
    // Name band is a fixed fraction of the card, sized off THIS card's own
    // height (not a shared constant) so it scales down along with the
    // photo on narrow/short layouts instead of eating into the photo area.
    final nameBandHeight = (height * 0.26).clamp(16.0, 30.0);
    final nameFontSize = (width * 0.13).clamp(8.5, 12.5);
    // Role band is thinner than the name band and only takes up space
    // when there IS a role to show - the photo's Expanded above absorbs
    // whatever's left either way, so adding this never risks overflowing
    // the card's fixed total height.
    final roleBandHeight = (height * 0.16).clamp(12.0, 20.0);
    final roleFontSize = (width * 0.1).clamp(7.0, 10.0);

    return Container(
      width: width,
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.35), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Photo fills all remaining space above the name/role bands -
          // Expanded (not a fixed height) is what keeps this card from
          // ever overflowing when width/height get squeezed for a big
          // squad on a small screen, or when the role band appears/
          // disappears between players.
          Expanded(
            child: hasPhoto
                ? Image.network(
                    photoUrl!,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    errorBuilder: (context, error, stackTrace) => _demoPhoto(),
                    loadingBuilder: (context, child, progress) =>
                        progress == null ? child : _demoPhoto(),
                  )
                : _demoPhoto(),
          ),
          Container(
            width: double.infinity,
            height: nameBandHeight,
            alignment: Alignment.center,
            color: _navy,
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                name.toUpperCase(),
                textAlign: TextAlign.center,
                maxLines: 1,
                style: TextStyle(color: Colors.white, fontSize: nameFontSize, fontWeight: FontWeight.w900, letterSpacing: 0.2),
              ),
            ),
          ),
          if (hasRole)
            Container(
              width: double.infinity,
              height: roleBandHeight,
              alignment: Alignment.center,
              color: _roleRed,
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  role!.toUpperCase(),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: TextStyle(color: Colors.white, fontSize: roleFontSize, fontWeight: FontWeight.w800, letterSpacing: 0.3),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // The "demo picture" shown whenever a player has no real photo yet - a
  // plain silhouette on a light fill, matching the CircleAvatar fallback
  // style already used elsewhere in the app (profile screen, player list)
  // rather than shipping a separate placeholder image asset.
  Widget _demoPhoto() {
    return Container(
      color: const Color(0xFFE3E6EA),
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Icon(Icons.person, color: const Color(0xFF9AA3AE), size: width * 0.55),
      ),
    );
  }
}

/// One team's full batting scorecard, pushed via
/// MatchScorerScreen._broadcastScorecard - styled after the FOX Cricket
/// broadcast graphic reference (light floating card, big green centered
/// team name up top, individual dark "chip" rows per batter with a
/// separate wicket-info column, and the total shown plain on the light
/// card itself rather than inside a colored footer bar). Same full-screen
/// overlay pattern as _PlayingXIView above (see _FullScreenBroadcastOverlay).
//
// IMPORTANT: same non-interactive/non-scrollable constraint as
// _PlayingXIView (see its class doc) - the whole card sits inside an
// IgnorePointer, so a full XI's worth of batters has to fit on screen at
// once without scrolling. Row height and font size are computed from the
// real available height (LayoutBuilder) rather than fixed, so an
// all-out-innings scorecard (11 rows) still fits on a short landscape
// screen the same way a 2-3 not-out scorecard does.
class _ScorecardBroadcastView extends StatelessWidget {
  final BroadcastScorecardData data;
  const _ScorecardBroadcastView({required this.data});

  // ========================================================================
  // EASY TUNABLES - change a number here to change how the card looks.
  // Nothing else in this file needs to be touched for a size/color tweak.
  // ========================================================================

  // The big green team name at the top (e.g. "AUSTRALIA"). Smaller number
  // = smaller team name text.
  static const double _teamNameFontSize = 24;

  // Batter rows (name / wicket info / RUNS / BALLS) auto-shrink ONLY if the
  // screen genuinely doesn't have room - _batterMaxFontSize is the size
  // they'll use whenever there's room, _batterMinFontSize is the smallest
  // they're ever allowed to shrink to. Raise _batterMaxFontSize for bigger
  // batsman rows.
  static const double _batterMaxFontSize = 17;
  static const double _batterMinFontSize = 12;

  // Fixed-height chunks of the card, reserved up front so the batter-rows
  // list in the middle always gets EXACTLY what's left - this is what
  // makes the card overflow-proof no matter the squad size. If you change
  // _teamNameFontSize above, adjust _headerHeight to match (roughly
  // teamNameFontSize + 30). If you change footer text sizes below, adjust
  // _footerHeight the same way (roughly the tallest footer text stack +
  // 16-20 for padding) - a too-small height here is what causes a bottom
  // "overflow" stripe.
  static const double _headerHeight = 40;
  static const double _columnLabelsHeight = 22;
  static const double _headerToLabelsGap = 6;
  static const double _labelsToRowsGap = 0;
  // BUG FIX (TOTAL number overflowing): the "TOTAL" label (10px) + the big
  // "198/9" number below it (_totalFontSize=26) need ~39px just for that
  // text stack, plus the footer's own vertical padding (8px total) - that's
  // ~47px of real content, so the 48 this was set to left virtually zero
  // buffer and reliably clipped/overflowed on real devices. Kept this as
  // small as it safely can be rather than jumping back to the original 62.
  static const double _footerHeight = 56;

  // The big black "198/9" TOTAL number in the footer, bottom-right.
  static const double _totalFontSize = 26;

  // ---- Column proportions shared by the header labels row AND every
  // batter/yet-to-bat row below, so everything lines up in neat columns
  // exactly like the reference graphic (name | wicket info | RUNS | BALLS).
  static const int _nameFlex = 3;
  static const int _wicketFlex = 4;
  static const double _runsWidth = 44;
  static const double _colGap = 10;
  static const double _ballsWidth = 48;
  static const double _strikerArrowWidth = 16;

  static const _cardTop = Color(0xFFFAFBFA);
  static const _cardBottom = Color(0xFFE7EAE8);
  static const _teamGreen = Color(0xFF15A24A);
  static const _labelGray = Color(0xFF8A9490);
  static const _rowDark = Color(0xFF12211D);
  static const _notOutGreen = Color(0xFF20C26A);
  static const _totalInk = Color(0xFF0F1E1A);
  static const _footerLabel = Color(0xFF44534D);

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final maxCardWidth = (screenSize.width * 0.74).clamp(360.0, 640.0).toDouble();

    // Every fixed-height chunk of the card (header, column labels, footer)
    // is measured up front so the LayoutBuilder below can hand the batter
    // rows EXACTLY what's left - same "compute, don't guess" approach as
    // before, and the reason this card can never overflow regardless of
    // squad size or screen height. (See the EASY TUNABLES block above to
    // change these.)
    const headerHeight = _headerHeight;
    const columnLabelsHeight = _columnLabelsHeight;
    const headerToLabelsGap = _headerToLabelsGap;
    const labelsToRowsGap = _labelsToRowsGap;
    // FIX (bottom-overflow-under-the-runs bug): the footer's right-hand
    // column stacks a "TOTAL" label on top of the big total-runs number -
    // at _totalFontSize=26 with its label, that stack is taller than the
    // old fixed 50px footer height plus its padding, so the footer
    // silently overflowed a few px below the visible card edge on real
    // devices (Flutter's yellow/black overflow stripe). _footerHeight is
    // now sized with real headroom above that text stack - see the EASY
    // TUNABLES block if you change _totalFontSize later.
    const footerHeight = _footerHeight;

    return ConstrainedBox(
      // Slightly more generous than a typical "leave some margin" cap -
      // this overlay genuinely spans close to the full live-viewer screen
      // height (see _FullScreenBroadcastOverlay), not just the video's
      // letterboxed area, so giving the card more of that room directly
      // helps the font-size math above land on a bigger, clearer size
      // more often instead of shrinking unnecessarily.
      constraints: BoxConstraints(maxHeight: screenSize.height * 0.92, maxWidth: maxCardWidth),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_cardTop, _cardBottom]),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.6), width: 1),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.45), blurRadius: 30, offset: const Offset(0, 16)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header - JUST the team name, big/bold/green and centered,
            // with a small centered accent underline beneath it. No
            // logo/subtitle/venue line - deliberately minimal so the
            // header stays a fixed, small, predictable height no matter
            // what match this card is for.
            SizedBox(
              height: headerHeight,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      data.teamName.toUpperCase(),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _teamGreen,
                        fontSize: _teamNameFontSize,
                        // Pinning line-height to exactly 1.0x fontSize keeps
                        // this header's real rendered height predictable -
                        // without it, headerHeight above has to be guessed
                        // at and easily comes up a few px short.
                        height: 1.0,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: 46,
                      height: 3.5,
                      decoration: BoxDecoration(color: _teamGreen, borderRadius: BorderRadius.circular(2)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: headerToLabelsGap),
            // Column labels - "wicket info" over the dismissal column,
            // RUNS / BALLS right-aligned over their numeric columns -
            // same flex/width split every batter row below uses, so
            // everything lines up.
            SizedBox(
              height: columnLabelsHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    const SizedBox(width: _strikerArrowWidth),
                    const Expanded(flex: _nameFlex, child: SizedBox()),
                    Expanded(
                      flex: _wicketFlex,
                      child: const Text("wicket info", style: TextStyle(color: _labelGray, fontSize: 11, fontWeight: FontWeight.w600)),
                    ),
                    SizedBox(width: _runsWidth, child: Text(tr('col_runs_caps'), textAlign: TextAlign.right, style: const TextStyle(color: _labelGray, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4))),
                    const SizedBox(width: _colGap),
                    SizedBox(width: _ballsWidth, child: Text(tr('col_balls_caps'), textAlign: TextAlign.right, style: const TextStyle(color: _labelGray, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4))),
                  ],
                ),
              ),
            ),
            const SizedBox(height: labelsToRowsGap),
            // Batter rows - font size is picked TOP-DOWN (start from a
            // comfortable, clearly-readable size and only shrink it if the
            // screen genuinely doesn't have room), not bottom-up from
            // whatever's left divided by row count. Text has a real floor
            // (minFontSize) it will not go below; only in a genuinely
            // extreme case (a huge squad on an unusually short screen)
            // does the row's vertical margin get squeezed instead - the
            // text itself stays legible and every row still gets shown,
            // never clipped.
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: (data.batsmen.isEmpty && data.yetToBat.isEmpty)
                    ? const SizedBox.shrink()
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          // Total row count includes the dimmed "YET TO
                          // BAT" rows too - the whole point of showing
                          // them is so the full squad size (e.g. 11) is
                          // always visible even mid-innings, not just once
                          // everyone's out, so they have to count toward
                          // the same overflow-proof sizing math as played
                          // rows.
                          final n = data.batsmen.length + data.yetToBat.length;
                          final availableHeight = constraints.maxHeight.isFinite ? constraints.maxHeight : (n * 30.0);
                          // BUG FIX (bottom overflow): each row's own Container
                          // below carries `margin: vertical 1.5` - that's 1.5
                          // top + 1.5 bottom = 3.0 of real space per row, but
                          // this constant said 1.0, so the sizing math below
                          // was under-reserving space by 2.0px x every row -
                          // for an 11-row scorecard that's ~22px of silently
                          // un-budgeted height, which is exactly what was
                          // spilling out as the bottom overflow. This must
                          // always match the row widgets' real total margin.
                          // Each row below carries `margin: vertical 2.5` -
                          // 2.5 top + 2.5 bottom = 5.0 of real space between
                          // one batter's chip and the next. This MUST always
                          // match that real total, or rows silently overlap
                          // the reserved space and either overflow or (as
                          // reported) look like they're touching with no
                          // gap at all.
                          const perRowMargin = 5.0;
                          const maxFontSize = _batterMaxFontSize;
                          // Slightly tighter than before (was 1.9) - this is
                          // the "lift the batsmen up a touch" ask: rows sit a
                          // little more compact/higher, with a bit of real
                          // headroom to spare now that perRowMargin above is
                          // finally accurate, instead of everything being
                          // stretched right up against the available space.
                          const rowHeightPerFont = 1.75;

                          // BUG FIX (name text getting a horizontal "cut"
                          // through the middle, AND the bottom rows / the
                          // TOTAL footer overflowing off-screen on bigger
                          // squads): these two bugs were opposite symptoms
                          // of the SAME root cause. The old code computed
                          // fontSize and rowHeight in two separate passes -
                          // a first pass picking a "comfortable" fontSize,
                          // then a second pass independently re-capping
                          // rowHeight to whatever space was really left -
                          // and then patched the two back together with a
                          // correction step. Whenever that correction was
                          // missing or only partly applied, one of two
                          // things happened: either rowHeight got capped
                          // smaller than fontSize actually needed (chip
                          // shrinks to a thin sliver, unclipped text pokes
                          // out above/below it -> the "cut through the
                          // name" look), or the reverse - fontSize/rowHeight
                          // stayed at the "comfortable" size even though
                          // n rows at that size didn't actually fit
                          // availableHeight, so the last row(s) and the
                          // footer below them got pushed past the bottom
                          // edge (the "10th batsman + TOTAL overflow" bug).
                          //
                          // Fix: derive fontSize and rowHeight from a
                          // SINGLE formula instead of two that can drift
                          // apart. `fittingFontSize` is the largest font
                          // size where n rows, each needing
                          // (fontSize*rowHeightPerFont + perRowMargin) of
                          // real space, still add up to <= availableHeight -
                          // i.e. the exact size at which everything just
                          // fits with zero left over. rowHeight is then
                          // always computed FROM that same fontSize, never
                          // capped independently - so the chip is always
                          // exactly as tall as the text needs (no cut) and
                          // the full column of rows never exceeds
                          // availableHeight (no overflow), because both
                          // numbers came from the one calculation.
                          double fontSize = (availableHeight / n - perRowMargin) / rowHeightPerFont;
                          // BUG FIX (overflow at ~batsman #10 + TOTAL still
                          // happening after the fix above): this used to
                          // floor fontSize at a hard 6.0 via `.clamp(6.0,
                          // maxFontSize)`. On a genuinely tight real device
                          // (a full 11-man squad on a shorter screen), the
                          // size that actually FITS can be smaller than
                          // 6.0 - flooring it back up to 6.0 made rowHeight
                          // bigger than what was really available again,
                          // which is exactly what pushed the later rows
                          // and the TOTAL footer off the bottom. There's no
                          // safe hard floor to clamp UP to without risking
                          // this same overflow, so instead: only cap the
                          // TOP end (never render bigger than the
                          // comfortable maxFontSize when there's room to
                          // spare), and let the bottom end float as low as
                          // the real available space requires.
                          if (fontSize > maxFontSize) fontSize = maxFontSize;
                          if (fontSize < 1.0) fontSize = 1.0;
                          double rowHeight = fontSize * rowHeightPerFont;
                          // Belt-and-suspenders against floating-point
                          // rounding: with many rows/margins added up,
                          // tiny rounding error could in theory land the
                          // real total a hair over availableHeight even
                          // though the formula above targets an exact fit.
                          // If that ever happens, scale fontSize AND
                          // rowHeight down together by the same ratio (so
                          // they can never drift apart and the "cut
                          // through the name" bug can't come back) until
                          // the real total genuinely fits.
                          final totalNeeded = n * (rowHeight + perRowMargin);
                          if (totalNeeded > availableHeight && totalNeeded > 0) {
                            final safety = availableHeight / totalNeeded;
                            fontSize *= safety;
                            rowHeight *= safety;
                          }
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (int i = 0; i < data.batsmen.length; i++)
                                _ScorecardBatterRow(
                                  batsman: data.batsmen[i],
                                  isStriker: data.batsmen[i].id == data.strikerId,
                                  height: rowHeight,
                                  fontSize: fontSize,
                                ),
                              for (int i = 0; i < data.yetToBat.length; i++)
                                _ScorecardYetToBatRow(
                                  name: data.yetToBat[i],
                                  height: rowHeight,
                                  fontSize: fontSize,
                                ),
                            ],
                          );
                        },
                      ),
              ),
            ),
            // Footer - plain on the light card itself (no colored bar):
            // EXTRAS/OVERS on the left in muted dark text, TOTAL big and
            // bold on the right, matching the reference graphic exactly.
            SizedBox(
              height: footerHeight,
              child: Padding(
                // Vertical padding kept deliberately small/symmetric - the
                // TOTAL number stack below is the tallest thing in this
                // footer, so _footerHeight above already reserves its real
                // height; padding just adds a little breathing room, not
                // the room itself. Center-aligning the row (not
                // crossAxisAlignment.end) means neither side has to sit
                // flush against the bottom edge, which is what removes the
                // hairline overflow risk on tighter screens.
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        "EXTRAS ${data.extras}   OVERS ${data.oversDisplay}",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _footerLabel, fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.2),
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(tr('col_total_caps'), style: const TextStyle(color: _labelGray, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.0, height: 1.2)),
                        Text(
                          "${data.totalRuns}/${data.totalWickets}",
                          style: const TextStyle(color: _totalInk, fontSize: _totalFontSize, fontWeight: FontWeight.w900, height: 1.05),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One batter's row inside _ScorecardBroadcastView - a dark "chip" bar
/// styled after the reference broadcast graphic, split into the same four
/// columns the header labels use: name, wicket info, RUNS, BALLS. A
/// not-out batter's row looks exactly like every other row EXCEPT the
/// wicket-info slot shows "not out" - but the full green highlight + the
/// on-strike ▶ arrow are reserved for [isStriker] ONLY. During an
/// in-progress innings there are always TWO not-out batsmen (striker +
/// non-striker); highlighting both green (an earlier version of this
/// widget effectively would have, since it only checked "is this batsman
/// not out") doesn't match the reference graphic, which only spotlights
/// the one actually facing the bowler - the non-striker still reads
/// "not out", just without the green chip.
class _ScorecardBatterRow extends StatelessWidget {
  final Batsman batsman;
  final bool isStriker;
  final double height;
  final double fontSize;
  const _ScorecardBatterRow({required this.batsman, required this.isStriker, required this.height, required this.fontSize});

  @override
  Widget build(BuildContext context) {
    final isNotOut = batsman.dismissal.trim().toLowerCase() == 'not out';
    // Highlighting the whole chip green is reserved for the batter
    // actually on strike - matches the arrow, and avoids two green rows
    // on screen at once when both not-out batsmen are shown.
    final highlight = isStriker;
    final chipColor = highlight ? _ScorecardBroadcastView._notOutGreen : _ScorecardBroadcastView._rowDark;
    final wicketColor = highlight ? Colors.white : (isNotOut ? _ScorecardBroadcastView._notOutGreen : Colors.white70);

    return Container(
      height: height,
      margin: const EdgeInsets.symmetric(vertical: 2.5),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: chipColor, borderRadius: BorderRadius.circular(6)),
      child: Row(
        children: [
          SizedBox(
            width: _ScorecardBroadcastView._strikerArrowWidth,
            child: isStriker ? Icon(Icons.play_arrow_rounded, color: Colors.white, size: fontSize + 4) : null,
          ),
          Expanded(
            flex: _ScorecardBroadcastView._nameFlex,
            child: Text(
              batsman.name.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white, fontSize: fontSize, fontWeight: FontWeight.w800),
            ),
          ),
          Expanded(
            flex: _ScorecardBroadcastView._wicketFlex,
            child: Text(
              // Dismissal text is shown AS STORED (not upper-cased) - the
              // scorer already writes it as "b Hasan" / "c Das b Hasan" /
              // "not out", lowercase keyword + whatever case the player's
              // name was entered in, matching the reference graphic's own
              // mixed-case wicket-info column exactly.
              isNotOut ? 'not out' : batsman.dismissal,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: wicketColor, fontSize: fontSize * 0.86, fontWeight: FontWeight.w600),
            ),
          ),
          SizedBox(
            width: _ScorecardBroadcastView._runsWidth,
            child: Text("${batsman.runs}", textAlign: TextAlign.right, style: TextStyle(color: Colors.white, fontSize: fontSize, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: _ScorecardBroadcastView._colGap),
          SizedBox(
            width: _ScorecardBroadcastView._ballsWidth,
            child: Text("${batsman.balls}", textAlign: TextAlign.right, style: TextStyle(color: Colors.white, fontSize: fontSize, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

/// A squad member who hasn't come out to bat yet this innings - shown
/// after the played-batsmen rows (see the LayoutBuilder above) so the full
/// squad size is visible mid-innings, not just once everyone's out. Same
/// row shape/height/column split as _ScorecardBatterRow (so the two
/// interleave without any visual seam), just dimmed throughout and with
/// "yet to bat" where the wicket info would go instead of runs/balls
/// values.
class _ScorecardYetToBatRow extends StatelessWidget {
  final String name;
  final double height;
  final double fontSize;
  const _ScorecardYetToBatRow({required this.name, required this.height, required this.fontSize});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      margin: const EdgeInsets.symmetric(vertical: 2.5),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: _ScorecardBroadcastView._rowDark.withOpacity(0.55), borderRadius: BorderRadius.circular(6)),
      child: Row(
        children: [
          const SizedBox(width: _ScorecardBroadcastView._strikerArrowWidth),
          Expanded(
            flex: _ScorecardBroadcastView._nameFlex,
            child: Text(
              name.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white38, fontSize: fontSize, fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            flex: _ScorecardBroadcastView._wicketFlex,
            child: Text(
              "yet to bat",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white24, fontSize: fontSize * 0.86, fontWeight: FontWeight.w600),
            ),
          ),
          SizedBox(width: _ScorecardBroadcastView._runsWidth, child: Text("-", textAlign: TextAlign.right, style: TextStyle(color: Colors.white24, fontSize: fontSize))),
          const SizedBox(width: _ScorecardBroadcastView._colGap),
          SizedBox(width: _ScorecardBroadcastView._ballsWidth, child: Text("-", textAlign: TextAlign.right, style: TextStyle(color: Colors.white24, fontSize: fontSize))),
        ],
      ),
    );
  }
}

/// The FIELDING team's current bowling figures, pushed via
/// MatchScorerScreen._broadcastBowlingFigures - same light-card/dark-chip
/// visual language as _ScorecardBroadcastView above (deliberately reuses
/// its color palette directly rather than redefining it, so the two cards
/// always look like a matched pair), just with bowling's own columns
/// (Overs / Maidens / Runs / Wickets / Economy) instead of RUNS/BALLS.
/// Same overflow-proof sizing approach too: row height/font size are
/// computed from the real available height via LayoutBuilder, so a long
/// bowling list (say, a T20 innings that used all 5-6 bowlers) still fits
/// on screen without scrolling, the same way the batting scorecard does.
class _BowlingBroadcastView extends StatelessWidget {
  final BroadcastBowlingData data;
  const _BowlingBroadcastView({required this.data});

  // ---- Column proportions shared by the header labels row AND every
  // bowler row below - name gets most of the width, the four figures
  // columns are narrow fixed widths since they're always short numbers.
  static const int _nameFlex = 5;
  static const double _oversWidth = 34;
  static const double _maidensWidth = 30;
  static const double _runsWidth = 34;
  static const double _wicketsWidth = 30;
  static const double _econWidth = 48;
  static const double _colGap = 6;

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final maxCardWidth = (screenSize.width * 0.74).clamp(360.0, 640.0).toDouble();

    // Same fixed-chunk budgeting as _ScorecardBroadcastView - see that
    // class's EASY TUNABLES block for the full explanation of why every
    // piece is measured up front instead of guessed.
    const headerHeight = _ScorecardBroadcastView._headerHeight;
    const columnLabelsHeight = _ScorecardBroadcastView._columnLabelsHeight;
    const headerToLabelsGap = _ScorecardBroadcastView._headerToLabelsGap;
    const labelsToRowsGap = _ScorecardBroadcastView._labelsToRowsGap;
    const footerHeight = _ScorecardBroadcastView._footerHeight;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: screenSize.height * 0.92, maxWidth: maxCardWidth),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_ScorecardBroadcastView._cardTop, _ScorecardBroadcastView._cardBottom],
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.6), width: 1),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.45), blurRadius: 30, offset: const Offset(0, 16)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header - the FIELDING team's name (whose bowlers are listed
            // below), big/bold/green and centered - same treatment as the
            // batting scorecard's header.
            SizedBox(
              height: headerHeight,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      data.teamName.toUpperCase(),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _ScorecardBroadcastView._teamGreen,
                        fontSize: _ScorecardBroadcastView._teamNameFontSize,
                        height: 1.0,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: 46,
                      height: 3.5,
                      decoration: BoxDecoration(color: _ScorecardBroadcastView._teamGreen, borderRadius: BorderRadius.circular(2)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: headerToLabelsGap),
            // Column labels - O / M / R / W / ECON right-aligned over their
            // respective numeric columns, same split every bowler row below
            // uses.
            SizedBox(
              height: columnLabelsHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    const Expanded(flex: _nameFlex, child: SizedBox()),
                    _colHeader("O", _oversWidth),
                    const SizedBox(width: _colGap),
                    _colHeader("M", _maidensWidth),
                    const SizedBox(width: _colGap),
                    _colHeader("R", _runsWidth),
                    const SizedBox(width: _colGap),
                    _colHeader("W", _wicketsWidth),
                    const SizedBox(width: _colGap),
                    _colHeader("ECON", _econWidth),
                  ],
                ),
              ),
            ),
            const SizedBox(height: labelsToRowsGap),
            // Bowler rows - same top-down font-size picking as the batting
            // scorecard (start comfortable, only shrink if the screen
            // genuinely doesn't have room, never below the floor).
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: data.bowlers.isEmpty
                    ? const SizedBox.shrink()
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final n = data.bowlers.length;
                          final availableHeight = constraints.maxHeight.isFinite ? constraints.maxHeight : (n * 30.0);
                          // Must always match the row widget's real total
                          // margin below (margin: vertical 2.5 = 5.0 total)
                          // - see the batting scorecard's own perRowMargin
                          // comment for why a mismatch here causes overflow.
                          const perRowMargin = 5.0;
                          const maxFontSize = _ScorecardBroadcastView._batterMaxFontSize;
                          const minFontSize = _ScorecardBroadcastView._batterMinFontSize;
                          const rowHeightPerFont = 1.75;

                          double fontSize = maxFontSize;
                          double rowHeight = fontSize * rowHeightPerFont;
                          final comfortableTotal = n * (rowHeight + perRowMargin);
                          if (comfortableTotal > availableHeight) {
                            final scale = availableHeight / comfortableTotal;
                            fontSize = (maxFontSize * scale).clamp(minFontSize, maxFontSize).toDouble();
                            rowHeight = fontSize * rowHeightPerFont;
                          }
                          rowHeight = ((availableHeight - n * perRowMargin) / n).clamp(1.0, rowHeight).toDouble();
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final bowler in data.bowlers)
                                _BowlingBowlerRow(bowler: bowler, height: rowHeight, fontSize: fontSize),
                            ],
                          );
                        },
                      ),
              ),
            ),
            // Footer - same plain-on-light-card EXTRAS/OVERS/TOTAL as the
            // batting scorecard, describing the innings these bowlers are
            // conceding runs in.
            SizedBox(
              height: footerHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        "EXTRAS ${data.extras}   OVERS ${data.oversDisplay}",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _ScorecardBroadcastView._footerLabel, fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.2),
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(tr('col_total_caps'), style: const TextStyle(color: _ScorecardBroadcastView._labelGray, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.0, height: 1.2)),
                        Text(
                          "${data.totalRuns}/${data.totalWickets}",
                          style: const TextStyle(color: _ScorecardBroadcastView._totalInk, fontSize: _ScorecardBroadcastView._totalFontSize, fontWeight: FontWeight.w900, height: 1.05),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _colHeader(String label, double width) {
    return SizedBox(
      width: width,
      child: Text(label, textAlign: TextAlign.right, style: const TextStyle(color: _ScorecardBroadcastView._labelGray, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
    );
  }
}

/// One bowler's row inside _BowlingBroadcastView - same dark "chip" bar
/// styling as _ScorecardBatterRow, just with the bowling figures columns
/// (O / M / R / W / ECON) instead of a wicket-info + RUNS/BALLS split.
/// There's no "on strike" equivalent for a bowling card - every bowler who's
/// bowled this innings gets the same plain dark row, no highlight.
class _BowlingBowlerRow extends StatelessWidget {
  final Bowler bowler;
  final double height;
  final double fontSize;
  const _BowlingBowlerRow({required this.bowler, required this.height, required this.fontSize});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      margin: const EdgeInsets.symmetric(vertical: 2.5),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: _ScorecardBroadcastView._rowDark, borderRadius: BorderRadius.circular(6)),
      child: Row(
        children: [
          Expanded(
            flex: _BowlingBroadcastView._nameFlex,
            child: Text(
              bowler.name.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white, fontSize: fontSize, fontWeight: FontWeight.w800),
            ),
          ),
          _figure("${bowler.oversDisplay}", _BowlingBroadcastView._oversWidth),
          const SizedBox(width: _BowlingBroadcastView._colGap),
          _figure("${bowler.maidens}", _BowlingBroadcastView._maidensWidth),
          const SizedBox(width: _BowlingBroadcastView._colGap),
          _figure("${bowler.runs}", _BowlingBroadcastView._runsWidth),
          const SizedBox(width: _BowlingBroadcastView._colGap),
          _figure("${bowler.wickets}", _BowlingBroadcastView._wicketsWidth),
          const SizedBox(width: _BowlingBroadcastView._colGap),
          _figure(bowler.economy, _BowlingBroadcastView._econWidth),
        ],
      ),
    );
  }

  Widget _figure(String text, double width) {
    return SizedBox(
      width: width,
      child: Text(text, textAlign: TextAlign.right, style: TextStyle(color: Colors.white, fontSize: fontSize, fontWeight: FontWeight.w700)),
    );
  }
}

/// Fits a fixed-aspect-ratio video (e.g. YouTube's 16:9 player) into its
/// parent, the way CSS `object-fit` works - `BoxFit.cover` scales it up to
/// fill the parent completely (cropping the overflow), `BoxFit.contain`
/// scales it down to fit without cropping. Both modes now go through the
/// SAME widget-tree shape (LayoutBuilder -> ClipRect -> OverflowBox ->
/// SizedBox -> child) and only the computed width/height differ - this is
/// what actually fixes the toggle-goes-blank bug: previously "contain" used
/// a completely different tree (Center -> AspectRatio) than "cover"
/// (LayoutBuilder -> ClipRect -> OverflowBox -> SizedBox), so toggling fit
/// made Flutter unmount/remount that whole ancestor chain every time. The
/// GlobalKey on the video widget itself (see call site) only preserves that
/// one element - it does NOT stop the different-shaped ancestors around it
/// from being torn down and rebuilt, and that teardown is what was
/// blanking/detaching the native WebView platform view underneath. Keeping
/// one unchanging tree shape means toggling fit now only updates layout
/// numbers, never element types, so nothing above the video should ever
/// need to remount.
class _CoverFit extends StatelessWidget {
  final double aspectRatio;
  final BoxFit fit;
  final Widget child;

  const _CoverFit({required this.aspectRatio, required this.child, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) {
    // FIX (blank-screen-on-toggle regression): contain mode never needs to
    // render larger than the available space, so it doesn't need
    // OverflowBox at all - a plain AspectRatio does the job. Routing it
    // through OverflowBox + SizedBox (as this used to) forces the native
    // player underneath (YouTube/Facebook WebView - a platform view, not a
    // normal Flutter render object) to be resized to an exact pixel size.
    // Platform views on Android don't reliably survive that kind of forced
    // resize and go blank. cover mode genuinely needs to render oversized
    // and get clipped, so it keeps OverflowBox/ClipRect - that part is
    // unavoidable there. (The GlobalKey/KeyedSubtree on the video widget at
    // the call site already keeps its element identity across this shape
    // change, so switching between the two branches below never remounts
    // the player itself.)
    if (fit == BoxFit.contain) {
      // FIX (graph-overlay-off-screen-on-unfit bug): plain Center +
      // AspectRatio never needs to render larger than the available space
      // in pure Flutter layout terms, so it looked safe without a clip.
      // But the child here is a native platform view (YouTube/Facebook
      // WebView), not an ordinary Flutter render object - without an
      // explicit ClipRect around it, its native compositing surface isn't
      // confined to Flutter's clip stack, so widgets stacked on TOP of it
      // (the full-screen Runs/Over/Compare/Battle broadcast cards - see
      // _FullScreenBroadcastOverlay) could composite incorrectly against
      // it, which is what made those cards appear to render outside the
      // visible screen area specifically in "unfit"/contain mode. Cover
      // mode already wraps its (deliberately oversized) video in ClipRect
      // below for the same reason; this just keeps both branches
      // consistent.
      return ClipRect(
        child: Center(
          child: AspectRatio(aspectRatio: aspectRatio, child: child),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final screenW = constraints.maxWidth;
        final screenH = constraints.maxHeight;
        final safeW = screenW > 0 ? screenW : 1.0;
        final safeH = screenH > 0 ? screenH : 1.0;
        final screenAspect = safeW / safeH;

        double width, height;
        if (screenAspect > aspectRatio) {
          width = safeW;
          height = safeW / aspectRatio;
        } else {
          height = safeH;
          width = safeH * aspectRatio;
        }

        return ClipRect(
          child: OverflowBox(
            maxWidth: width,
            maxHeight: height,
            child: SizedBox(width: width, height: height, child: child),
          ),
        );
      },
    );
  }
}