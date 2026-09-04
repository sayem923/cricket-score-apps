import 'package:flutter/material.dart';
import '../../services/storage_service.dart';
import '../../l10n/app_strings.dart';
import 'live_viewer_screen.dart';

class WatchLiveScreen extends StatefulWidget {
  const WatchLiveScreen({super.key});

  @override
  State<WatchLiveScreen> createState() => _WatchLiveScreenState();
}

class _WatchLiveScreenState extends State<WatchLiveScreen> {
  final _codeCtrl = TextEditingController();
  bool _checking = false;
  String? _error;

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _watch() async {
    final code = _codeCtrl.text.trim().toUpperCase();
    if (code.isEmpty) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    final broadcast = await StorageService.fetchLiveBroadcast(code);
    if (!mounted) return;
    setState(() => _checking = false);
    if (broadcast == null) {
      setState(() => _error = tr('no_live_match_found'));
      return;
    }
    Navigator.push(context, MaterialPageRoute(builder: (context) => LiveViewerScreen(broadcastId: code)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('watch_live_title')), backgroundColor: const Color(0xFF00695C), foregroundColor: Colors.white),
      // BUG FIX (overflow when the keyboard opens for the 6-char code
      // field): this body used to be a plain fixed Column with no
      // scrolling. On a real device, when the keyboard slides up it
      // shrinks the Scaffold's available body height (Flutter resizes
      // the body to avoid the keyboard by default) - the Icon + text +
      // field + button together no longer fit in that shorter height,
      // which is exactly what threw the "RenderFlex overflowed" warning
      // every time typing began. Wrapping the content in a
      // SingleChildScrollView lets it scroll instead of overflow
      // whenever the keyboard eats into the available space, while
      // looking and behaving exactly the same when the keyboard is
      // closed (content already fits, so there's nothing to scroll).
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.podcasts, size: 56, color: Color(0xFF00695C)),
            const SizedBox(height: 16),
            Text(
              tr('enter_live_code_hint'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _codeCtrl,
              textCapitalization: TextCapitalization.characters,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, letterSpacing: 4, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                hintText: tr('code_hint'),
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
              onSubmitted: (_) => _watch(),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _checking ? null : _watch,
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00695C), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
              child: _checking ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Text(tr('watch_caps').toUpperCase()),
            ),
          ],
        ),
      ),
    );
  }
}