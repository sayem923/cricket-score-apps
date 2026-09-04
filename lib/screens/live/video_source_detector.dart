import 'package:http/http.dart' as http;

enum VideoSourceType { youtube, facebook, unsupported }

class VideoSourceInfo {
  final VideoSourceType type;
  final String? id;
  VideoSourceInfo(this.type, this.id);
}

String? extractYoutubeIdFromUrl(String url) {
  try {
    final uri = Uri.parse(url);
    if (uri.host.contains('youtu.be')) {
      return uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
    }
    if (uri.pathSegments.contains('live')) {
      final idx = uri.pathSegments.indexOf('live');
      if (idx + 1 < uri.pathSegments.length) return uri.pathSegments[idx + 1];
    }
    if (uri.pathSegments.contains('embed')) {
      final idx = uri.pathSegments.indexOf('embed');
      if (idx + 1 < uri.pathSegments.length) return uri.pathSegments[idx + 1];
    }
    return uri.queryParameters['v'];
  } catch (_) {
    return null;
  }
}

Future<String> resolveFinalUrl(String url) async {
  try {
    final uri = Uri.parse(url);
    if (uri.host.contains('facebook.com') && uri.path.contains('/share/')) {
      final client = http.Client();
      try {
        final request = http.Request('GET', uri)..followRedirects = true;
        final response = await client.send(request);
        
        final finalUrl = response.headers['location'] ?? response.request?.url.toString();
        if (finalUrl != null && finalUrl.isNotEmpty) {
          return finalUrl;
        }
      } finally {
        client.close();
      }
    }
  } catch (_) {}
  return url;
}

VideoSourceInfo detectVideoSource(String url) {
  final lower = url.toLowerCase();

  if (lower.contains('youtube.com') || lower.contains('youtu.be')) {
    final id = extractYoutubeIdFromUrl(url);
    if (id != null) return VideoSourceInfo(VideoSourceType.youtube, id);
  }

  if (lower.contains('facebook.com') || lower.contains('fb.watch')) {
    return VideoSourceInfo(VideoSourceType.facebook, url);
  }

  return VideoSourceInfo(VideoSourceType.unsupported, null);
}

String buildFacebookEmbedUrl(String videoUrl, bool muted) {
  // ফেসবুকের বাড়তি ট্র্যাকিং প্যারামিটার বাদ দিয়ে ক্লিন লিংক তৈরি
  final Uri originalUri = Uri.parse(videoUrl);
  final String cleanUrl = '${originalUri.scheme}://${originalUri.host}${originalUri.path}';
  final encodedUrl = Uri.encodeComponent(cleanUrl);

  return 'https://www.facebook.com/plugins/video.php'
      '?href=$encodedUrl'
      '&show_text=false'
      '&autoplay=true'
      '&mute=${muted ? 1 : 0}'
      '&allowfullscreen=true'
      '&container_width=800';
}