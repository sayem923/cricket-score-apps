// Basic smoke test for the app's entry screen.
//
// The previous version of this file was a leftover early draft of the whole
// app (its own main(), its own model classes, its own ScorerScreen) that
// never imported package:flutter_test and had no testWidgets() calls at all
// - so `flutter test` silently ran zero tests. This replaces it with a real,
// minimal test.
//
// It targets WelcomeScreen directly rather than the full CricketScorerApp:
// the real app's entry point (AuthGate) talks to Supabase.instance, which
// requires Supabase.initialize() to have run first (normally done in main());
// wiring that up for tests needs its own setup (mocked network/storage) that
// is out of scope for a basic smoke test.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cricket_score_apps/screens/auth/welcome_screen.dart';
import 'package:cricket_score_apps/services/session_service.dart';

void main() {
  testWidgets('WelcomeScreen shows the core entry actions', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: WelcomeScreen()));

    expect(find.text('Pro Cricket Scorer'), findsOneWidget);
    expect(find.text('LOG IN'), findsOneWidget);
    expect(find.text('SIGN UP'), findsOneWidget);
    expect(find.text('Continue as Guest'), findsOneWidget);
  });

  testWidgets('Tapping "Continue as Guest" flips SessionService.isGuest', (WidgetTester tester) async {
    SessionService.isGuest.value = false;
    await tester.pumpWidget(const MaterialApp(home: WelcomeScreen()));

    await tester.tap(find.text('Continue as Guest'));
    await tester.pump();

    expect(SessionService.isGuest.value, isTrue);

    // Reset global state so this test doesn't leak into other test runs.
    SessionService.isGuest.value = false;
  });
}
