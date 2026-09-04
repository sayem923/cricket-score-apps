import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'video_source_detector.dart';

/// শুধু Mobile (Android/iOS) এর জন্য — webview_flutter ব্যবহার করে।
class FacebookVideoPlayer extends StatefulWidget {
  final String videoUrl;
  final ValueListenable<bool> mutedListenable;

  const FacebookVideoPlayer({
    super.key,
    required this.videoUrl,
    required this.mutedListenable,
  });

  @override
  State<FacebookVideoPlayer> createState() => _FacebookVideoPlayerState();
}

class _FacebookVideoPlayerState extends State<FacebookVideoPlayer> {
  WebViewController? _controller;
  bool _pageLoaded = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    final resolvedUrl = await resolveFinalUrl(widget.videoUrl);
    final initialMuted = widget.mutedListenable.value;
    final embedUrl = buildFacebookEmbedUrl(resolvedUrl, initialMuted);

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      // Desktop Chrome User-Agent ব্যবহার করে Embed Restriction বাইপাস করা হলো
      ..setUserAgent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) {
              setState(() {
                _pageLoaded = true;
                _isLoading = false;
              });
            }
            _applyMuteState(widget.mutedListenable.value);
          },
          onWebResourceError: (error) {
            debugPrint("WebView Error: ${error.description}");
          },
        ),
      )
      ..loadRequest(
        Uri.parse(embedUrl),
        // Referer Header পাঠানো হচ্ছে যাতে ফেসবুক ভিডিও পারমিশন ব্লক না করে
        headers: const {'Referer': 'https://www.facebook.com/'},
      );

    widget.mutedListenable.addListener(_onMutedChanged);
    if (mounted) {
      setState(() {
        _controller = controller;
      });
    }
  }

  @override
  void didUpdateWidget(covariant FacebookVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mutedListenable != widget.mutedListenable) {
      oldWidget.mutedListenable.removeListener(_onMutedChanged);
      widget.mutedListenable.addListener(_onMutedChanged);
    }
  }

  void _onMutedChanged() {
    _applyMuteState(widget.mutedListenable.value);
  }

  void _applyMuteState(bool muted) {
    if (!_pageLoaded || _controller == null) return;
    final js = '''
      (function() {
        var videos = document.getElementsByTagName('video');
        for (var i = 0; i < videos.length; i++) {
          videos[i].muted = $muted;
          videos[i].volume = $muted ? 0 : 1;
        }
      })();
    ''';
    _controller!.runJavaScript(js);
  }

  @override
  void dispose() {
    widget.mutedListenable.removeListener(_onMutedChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        if (_controller != null)
          WebViewWidget(controller: _controller!),
        if (_isLoading)
          const Center(
            child: CircularProgressIndicator(color: Colors.white),
          ),
      ],
    );
  }
}