import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/auth_service.dart'; 
import '../../utils/auth_error.dart';
import '../../l10n/app_strings.dart';

class OtpVerifyScreen extends StatefulWidget {
  final String email;
  final String? name;
  final bool isForPasswordReset;

  const OtpVerifyScreen({
    super.key,
    required this.email,
    this.name,
    this.isForPasswordReset = false,
  });

  @override
  State<OtpVerifyScreen> createState() => _OtpVerifyScreenState();
}

class _OtpVerifyScreenState extends State<OtpVerifyScreen> {
  final _codeCtrl = TextEditingController();
  final _newPasswordCtrl = TextEditingController();
  bool _loading = false;
  bool _resending = false;
  bool _obscure = true;

  // --- টাইমারের জন্য ভ্যারিয়েবল ---
  Timer? _timer;
  int _secondsRemaining = 60;
  bool _canResend = false;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _codeCtrl.dispose();
    _newPasswordCtrl.dispose();
    super.dispose();
  }


  void _startTimer() {
    setState(() {
      _secondsRemaining = 60;
      _canResend = false;
    });

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsRemaining > 0) {
        setState(() => _secondsRemaining--);
      } else {
        setState(() => _canResend = true);
        _timer?.cancel();
      }
    });
  }

  String get _formattedTime {
    final minutes = (_secondsRemaining ~/ 60).toString().padLeft(2, '0');
    final seconds = (_secondsRemaining % 60).toString().padLeft(2, '0');
    return "$minutes:$seconds";
  }

  Future<void> _verify() async {
    final code = _codeCtrl.text.trim();
    final newPassword = _newPasswordCtrl.text;

    if (code.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('enter_code_error'))),
      );
      return;
    }

    if (widget.isForPasswordReset) {
      if (newPassword.isEmpty || newPassword.length < 6) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('password_min_length'))),
        );
        return;
      }
    }

    setState(() => _loading = true);

    String? error;
    try {
      if (widget.isForPasswordReset) {
        // Supabase Direct Call for Password Recovery OTP
        await Supabase.instance.client.auth.verifyOTP(
          email: widget.email,
          token: code,
          type: OtpType.recovery,
        );
        await Supabase.instance.client.auth.updateUser(
          UserAttributes(password: newPassword),
        );
      } else {
        error = await AuthService.verifySignupOtp(
          email: widget.email,
          token: code,
          name: widget.name,
        );
      }
    } catch (e) {
      error = friendlyAuthErrorMessage(e);
    }

    if (!mounted) return;
    setState(() => _loading = false);

    if (error == null) {
      if (widget.isForPasswordReset) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('password_updated_success')),
            backgroundColor: Colors.green,
          ),
        );
      }
      Navigator.of(context).popUntil((r) => r.isFirst);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _resend() async {
    if (!_canResend || _resending) return;

    setState(() => _resending = true);

    String? error;
    try {
      if (widget.isForPasswordReset) {
        await Supabase.instance.client.auth.resetPasswordForEmail(widget.email);
      } else {
        error = await AuthService.resendSignupOtp(email: widget.email);
      }
    } catch (e) {
      error = friendlyAuthErrorMessage(e);
    }

    if (!mounted) return;
    setState(() => _resending = false);

    if (error == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('code_resent_success'))),
      );
      _startTimer(); // রিসেন্ড সফল হলে টাইমার পুনরায় ১ মিনিট থেকে শুরু হবে
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("${tr('could_not_resend')}: $error"), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isForPasswordReset ? tr('reset_password_title') : tr('verify_email_title')),
        backgroundColor: const Color(0xFF00695C),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr('otp_sent_to'), style: TextStyle(color: Colors.grey[700])),
            Text(widget.email, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 24),
            TextField(
              controller: _codeCtrl,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, letterSpacing: 8),
              decoration: InputDecoration(labelText: tr('six_digit_code')),
            ),
            const SizedBox(height: 16),

            if (widget.isForPasswordReset) ...[
              TextField(
                controller: _newPasswordCtrl,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: tr('new_password_label'),
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            ElevatedButton(
              onPressed: _loading ? null : _verify,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00695C),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Text(widget.isForPasswordReset ? tr('update_password').toUpperCase() : tr('verify').toUpperCase()),
            ),
            const SizedBox(height: 12),

            // --- Countdown UI Block ---
            Center(
              child: _canResend
                  ? TextButton(
                      onPressed: _resending ? null : _resend,
                      child: _resending
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              tr('resend_code'),
                              style: const TextStyle(
                                color: Color(0xFF00695C),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    )
                  : Text(
                      "${tr('resend_code_in')} $_formattedTime",
                      style: TextStyle(color: Colors.grey[600]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}