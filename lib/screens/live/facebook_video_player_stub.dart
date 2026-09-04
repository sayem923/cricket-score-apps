import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Web/stub সংস্করণ — এটা কখনো build হওয়ার কথা না, কারণ
/// live_viewer_screen.dart web-এ সরাসরি HTML iframe (buildWebIframe)
/// দিয়ে Facebook embed করে, এই widget সম্পূর্ণ bypass করে।
///
/// এই ফাইলটা শুধু safety-net হিসেবে রাখা — যাতে `webview_flutter`
/// প্যাকেজটা web build-এ কখনোই compile/link না হয়, ফলে
/// "WebViewPlatform.instance != null" এই assertion error structurally
/// সম্ভবই না থাকে।
class FacebookVideoPlayer extends StatelessWidget {
  final String videoUrl;
  final ValueListenable<bool> mutedListenable;

  const FacebookVideoPlayer({
    super.key,
    required this.videoUrl,
    required this.mutedListenable,
  });

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Web-এ এই widget ব্যবহার হওয়ার কথা না।',
        style: TextStyle(color: Colors.white70),
      ),
    );
  }
}