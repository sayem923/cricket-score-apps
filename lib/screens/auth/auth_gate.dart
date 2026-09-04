import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/session_service.dart';
import '../../services/auth_service.dart';
import '../home_screen.dart';
import 'welcome_screen.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: SessionService.isGuest,
      builder: (context, isGuest, _) {
        if (isGuest) return const HomeScreen();
        return StreamBuilder<AuthState>(
          stream: AuthService.authStateChanges,
          builder: (context, snapshot) {
            if (AuthService.isLoggedIn) return const HomeScreen();
            return const WelcomeScreen();
          },
        );
      },
    );
  }
}
