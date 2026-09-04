import 'package:flutter/material.dart';

/// Wraps [child] with a left-to-right shimmer sweep - the standard
/// "content is loading" look used by most polished apps instead of a
/// blank screen + spinner. Put your placeholder shapes (see [SkeletonBox])
/// inside [child]; this widget only supplies the moving highlight, it
/// doesn't know or care what shape they are.
class Shimmer extends StatefulWidget {
  final Widget child;
  const Shimmer({super.key, required this.child});

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            // The gradient's start/end slide across the widget's own width
            // each tick, driven by the controller - this is what reads as
            // "sweeping across" rather than a static gradient fill.
            final sweep = _controller.value;
            return LinearGradient(
              colors: const [Color(0xFFE0E0E0), Color(0xFFF5F5F5), Color(0xFFE0E0E0)],
              stops: const [0.35, 0.5, 0.65],
              begin: Alignment(-1.0 - sweep * 2, 0),
              end: Alignment(1.0 - sweep * 2, 0),
            ).createShader(bounds);
          },
          child: child,
        );
      },
    );
  }
}

/// One rounded-rect placeholder shape - a stand-in for a line of text, an
/// avatar, an image, etc. while real content loads. Give it the rough
/// size/shape of whatever it's replacing so the loading screen doesn't
/// visibly "jump" once real data replaces it.
class SkeletonBox extends StatelessWidget {
  final double width;
  final double height;
  final BorderRadius? borderRadius;
  const SkeletonBox({super.key, required this.width, required this.height, this.borderRadius});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: const Color(0xFFE0E0E0), borderRadius: borderRadius ?? BorderRadius.circular(4)),
    );
  }
}

/// A full skeleton stand-in for one "match card" row (see
/// match_history_screen.dart) - a circular avatar, a title-width bar, and
/// a shorter subtitle-width bar underneath, in the same Card/Row shape as
/// the real row so the swap-in doesn't shift layout.
class MatchCardSkeleton extends StatelessWidget {
  const MatchCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        child: Row(
          children: [
            const SkeletonBox(width: 40, height: 40, borderRadius: BorderRadius.all(Radius.circular(20))),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(width: MediaQuery.of(context).size.width * 0.5, height: 14),
                  const SizedBox(height: 8),
                  SkeletonBox(width: MediaQuery.of(context).size.width * 0.3, height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Drop-in replacement for `Center(child: CircularProgressIndicator())` on
/// any screen whose loaded content is a list of match-style cards -
/// renders [count] shimmering [MatchCardSkeleton] rows instead of a blank
/// screen with a spinner.
class MatchListSkeleton extends StatelessWidget {
  final int count;
  const MatchListSkeleton({super.key, this.count = 6});

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        // A skeleton screen's whole point is to show the SHAPE of what's
        // coming, not to actually be scrolled through - disabling scroll
        // avoids a jarring "scrolled skeleton" if data resolves mid-drag.
        physics: const NeverScrollableScrollPhysics(),
        itemCount: count,
        itemBuilder: (context, index) => const MatchCardSkeleton(),
      ),
    );
  }
}
