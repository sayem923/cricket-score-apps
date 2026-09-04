import 'package:supabase_flutter/supabase_flutter.dart';

/// Turns a raw auth error into a short, plain-language message safe to
/// show directly in a SnackBar - never the exception's own toString()
/// (e.g. "AuthApiException(message: Invalid login credentials,
/// statusCode: 400, code: invalid_credentials)"), which is what login,
/// signup, password-reset, and OTP screens were all showing verbatim
/// before this existed.
///
/// [AuthException.message] (used for the known-code cases below) is
/// already just the human sentence Supabase sends, with none of the
/// class-name/statusCode wrapper - that's the part worth keeping. Beyond
/// that, a handful of common codes get mapped to a slightly friendlier
/// wording than Supabase's own copy; anything unrecognized falls back to
/// message as-is, and a non-auth exception (e.g. no internet) gets a
/// generic connection message instead of ITS raw toString() either.
String friendlyAuthErrorMessage(Object error) {
  if (error is AuthException) {
    final code = error.code;
    final message = error.message;
    if (code == 'invalid_credentials' || message.toLowerCase().contains('invalid login credentials')) {
      return 'Incorrect email or password. Please check and try again.';
    }
    if (code == 'user_already_exists' || message.toLowerCase().contains('already registered')) {
      return 'An account with this email already exists. Try logging in instead.';
    }
    if (code == 'email_not_confirmed') {
      return 'Please verify your email before logging in.';
    }
    if (code == 'over_email_send_rate_limit') {
      return 'Too many attempts - please wait a moment and try again.';
    }
    if (message.trim().isEmpty) {
      return 'Something went wrong. Please try again.';
    }
    return message;
  }
  // Not a Supabase auth error at all (e.g. SocketException from no
  // internet) - still never show error.toString() straight to the user.
  return 'Could not reach the server. Check your internet connection and try again.';
}