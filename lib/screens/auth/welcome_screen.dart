import 'package:flutter/material.dart';
import '../../services/session_service.dart';
import '../../l10n/app_strings.dart';
import 'login_screen.dart';
import 'signup_screen.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF00695C),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.sports_cricket, size: 80, color: Colors.white),
              const SizedBox(height: 16),
              Text(tr('app_name'), style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(tr('app_tagline'), style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 14)),
              const SizedBox(height: 48),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const LoginScreen())),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: const Color(0xFF00695C), padding: const EdgeInsets.symmetric(vertical: 16)),
                  child: Text(tr('log_in').toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const SignupScreen())),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white), padding: const EdgeInsets.symmetric(vertical: 16)),
                  child: Text(tr('sign_up').toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 24),
              TextButton(
                onPressed: () => SessionService.isGuest.value = true,
                child: Text(tr('continue_as_guest'), style: const TextStyle(color: Colors.white70, decoration: TextDecoration.underline)),
              ),
              const SizedBox(height: 4),
              Text(tr('guest_matches_note'), style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}
