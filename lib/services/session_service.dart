import 'package:flutter/foundation.dart';

/// Tracks whether the person chose "Continue as Guest" this app session.
/// Intentionally NOT persisted to disk - a guest is never silently treated
/// as logged in on the next launch; they see the welcome screen again.
class SessionService {
  static final ValueNotifier<bool> isGuest = ValueNotifier<bool>(false);
}
