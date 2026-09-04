import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:share_plus/share_plus.dart';

/// Renders [card] off-screen (via the current Overlay, positioned well
/// outside the visible viewport rather than hidden with Offstage - an
/// Offstage subtree never actually paints, so RepaintBoundary.toImage
/// would come back empty), captures it as a PNG, and hands it straight to
/// the native share sheet as an image attachment.
///
/// [card] should be a fixed-size, self-contained widget (its own
/// background color, no ambient theme dependency) since it's briefly
/// mounted completely outside this screen's normal widget tree.
Future<void> shareWidgetAsImage(
  BuildContext context, {
  required Widget card,
  required String filename,
  String? text,
  double pixelRatio = 3.0,
}) async {
  final overlay = Overlay.of(context);
  final key = GlobalKey();
  late OverlayEntry entry;
  final ready = Completer<void>();

  entry = OverlayEntry(
    builder: (context) {
      // Scheduled after this frame paints, so the RepaintBoundary below
      // has real pixels by the time we try to capture it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!ready.isCompleted) ready.complete();
      });
      return Positioned(
        left: -9999,
        top: 0,
        child: Material(
          color: Colors.transparent,
          child: RepaintBoundary(key: key, child: card),
        ),
      );
    },
  );

  overlay.insert(entry);
  try {
    await ready.future;
    // One more frame's grace beyond the post-frame callback above - some
    // platforms (web in particular) need it for the layer to actually be
    // painted before toImage reads it back.
    await Future.delayed(const Duration(milliseconds: 50));
    final boundary = key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return;
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) return;
    final bytes = byteData.buffer.asUint8List();
    await Share.shareXFiles(
      [XFile.fromData(bytes, name: filename, mimeType: 'image/png')],
      text: text,
    );
  } finally {
    entry.remove();
  }
}