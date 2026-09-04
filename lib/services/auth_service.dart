import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'storage_service.dart';
import 'monitoring_service.dart';
import '../utils/auth_error.dart';

/// Wraps Supabase Auth (signup + email OTP verification, login, logout) and
/// the local "guest mode" flag.
///
/// Guest mode is a purely local choice (remembered in shared_preferences,
/// not Supabase) - a guest never gets a Supabase session, and their matches
/// never touch the cloud DB at all (see StorageService).
class AuthService {
  static const _guestModeKey = 'cricket_scorer_guest_mode_v1';

  static SupabaseClient get _client => Supabase.instance.client;

  static User? get currentUser => _client.auth.currentUser;
  static bool get isLoggedIn => currentUser != null;
  static Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  static String? get currentUserName =>
      currentUser?.userMetadata?['full_name'] as String? ?? currentUser?.email;

  static Future<bool> isGuestMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_guestModeKey) ?? false;
  }

  static Future<void> setGuestMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_guestModeKey, value);
  }

  /// Step 1 of signup: creates the account and triggers Supabase to email a
  /// verification code (requires the "Confirm signup" email template to use
  /// {{ .Token }} - see the setup note). Returns null on success, or an
  /// error message.
  static Future<String?> signUp({required String name, required String email, required String password}) async {
    try {
      await _client.auth.signUp(email: email, password: password, data: {'full_name': name});
      return null;
    } catch (e) {
      return friendlyAuthErrorMessage(e);
    }
  }

  /// Step 2 of signup: verifies the 6-digit code the user received by email.
  /// Also seeds the `profiles` table with the name entered at signup, so
  /// Profile shows it immediately rather than falling back to the email.
  static Future<String?> verifySignupOtp({required String email, required String token, String? name}) async {
    try {
      await _client.auth.verifyOTP(email: email, token: token, type: OtpType.signup);
      await setGuestMode(false);
      if (name != null && name.isNotEmpty) {
        await StorageService.saveProfile(name: name);
      }
      MonitoringService.logSignUp(method: 'email');
      return null;
    } catch (e) {
      return friendlyAuthErrorMessage(e);
    }
  }

  static Future<String?> resendSignupOtp({required String email}) async {
    try {
      await _client.auth.resend(type: OtpType.signup, email: email);
      return null;
    } catch (e) {
      return friendlyAuthErrorMessage(e);
    }
  }

  static Future<String?> signIn({required String email, required String password}) async {
    try {
      await _client.auth.signInWithPassword(email: email, password: password);
      await setGuestMode(false);
      MonitoringService.logLogin(method: 'email');
      return null;
    } catch (e) {
      return friendlyAuthErrorMessage(e);
    }
  }

  static Future<void> signOut() async {
    await _client.auth.signOut();
    unawaited(MonitoringService.setUserId(null));
  }

  /// Re-checks the CURRENT user's password without changing which account is
  /// signed in - used to gate destructive actions (e.g. deleting a tournament
  /// match) behind proof-of-identity, not just a "are you sure?" tap. Returns
  /// false (never throws) for a wrong password, no active session, or a
  /// network error - callers should treat all of those as "not verified".
  static Future<bool> verifyPassword(String password) async {
    final email = currentUser?.email;
    if (email == null) return false;
    try {
      await _client.auth.signInWithPassword(email: email, password: password);
      return true;
    } catch (e) {
      return false;
    }
  }
}