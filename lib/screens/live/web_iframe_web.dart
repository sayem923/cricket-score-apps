// Web-only implementation.
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';

final Set<String> _registeredViewTypes = {};

Widget buildWebIframe(String url) {
  final viewType = 'live-video-iframe-${url.hashCode}';

  if (!_registeredViewTypes.contains(viewType)) {
    _registeredViewTypes.add(viewType);
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
      final wrapper = html.DivElement()
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.overflow = 'hidden'
        ..style.position = 'relative';

      final iframe = html.IFrameElement()
        ..src = url
        ..style.border = 'none'
        ..style.position = 'absolute'
        // ডেসক্রিপশন ও টাইটেল ফিল্টার করার জন্য টপ ও লেফট ক্রপিং
        ..style.top = '-12%'
        ..style.left = '-6%'
        ..style.width = '112%'
        ..style.height = '124%'
        ..allow = 'autoplay; clipboard-write; encrypted-media; picture-in-picture; web-share'
        ..allowFullscreen = true;

      wrapper.append(iframe);
      return wrapper;
    });
  }

  return HtmlElementView(viewType: viewType);
}