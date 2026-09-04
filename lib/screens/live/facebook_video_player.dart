// এই ফাইলটা শুধু একটা "switcher" — কোনো widget নেই, শুধু conditional export।
//
// - dart.library.io থাকলে (Android/iOS/Desktop) -> facebook_video_player_mobile.dart
//   (আসল webview_flutter implementation)
// - না থাকলে (Web) -> facebook_video_player_stub.dart
//   (webview_flutter কে একদমই import করে না, তাই web build-এ সেটা compile হয় না)
//
// live_viewer_screen.dart শুধু import 'facebook_video_player.dart'; করে,
// আর FacebookVideoPlayer ক্লাসটা platform অনুযায়ী automatically সঠিকটা resolve হয়।
export 'facebook_video_player_stub.dart'
    if (dart.library.io) 'facebook_video_player_mobile.dart';