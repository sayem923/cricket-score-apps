import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import 'otp_verify_screen.dart';
import '../../l10n/app_strings.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _loading = false;
  bool _obscure = true;

  Future<void> _signup() async {
    final name = _nameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;

    if (name.isEmpty || email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('fill_all_fields'))));
      return;
    }
    if (password.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('password_min_length'))));
      return;
    }

    setState(() => _loading = true);
    // Supabase sends a 6-digit OTP code to the email (Confirm signup
    // template now uses {{ .Token }}, custom SMTP is set up via Brevo).
    final error = await AuthService.signUp(name: name, email: email, password: password);
    if (!mounted) return;
    setState(() => _loading = false);
    if (error == null) {
      Navigator.push(context, MaterialPageRoute(builder: (context) => OtpVerifyScreen(email: email, name: name)));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('sign_up_title')), backgroundColor: const Color(0xFF00695C), foregroundColor: Colors.white),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(controller: _nameCtrl, decoration: InputDecoration(labelText: tr('name_label'), prefixIcon: Icon(Icons.person_outline))),
            const SizedBox(height: 16),
            TextField(controller: _emailCtrl, keyboardType: TextInputType.emailAddress, decoration: InputDecoration(labelText: tr('gmail_email_label'), prefixIcon: Icon(Icons.email_outlined))),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordCtrl,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: tr('password_label'),
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => _obscure = !_obscure)),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _loading ? null : _signup,
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00695C), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16)),
              child: _loading ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Text(tr('sign_up').toUpperCase()),
            ),
          ],
        ),
      ),
    );
  }
}
