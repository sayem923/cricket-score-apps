// Non-web fallback for the conditional import in live_viewer_screen.dart.
// Never actually called on Android/iOS (those platforms use webview_flutter
// instead) - it only exists so the project compiles on every platform.
import 'package:flutter/material.dart';

Widget buildWebIframe(String url) => const SizedBox.shrink();