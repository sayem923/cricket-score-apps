import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import '../models/models.dart';
import '../utils/pdf_scorecard.dart';

/// A single reusable "Download Scorecard" action - used identically from
/// both the post-match result screen and Match History, so the PDF layout
/// and behavior never drift between the two entry points.
///
/// Hands the generated PDF to the OS share sheet (Printing.sharePdf)
/// rather than writing straight to a folder - this covers "save to
/// Files/Drive", "share to WhatsApp", and "print" all through one system
/// dialog, without this app needing storage permissions or guessing where
/// the person wants the file.
class DownloadScorecardButton extends StatefulWidget {
  final MatchResultData result;
  final bool compact;

  const DownloadScorecardButton({super.key, required this.result, this.compact = false});

  @override
  State<DownloadScorecardButton> createState() => _DownloadScorecardButtonState();
}

class _DownloadScorecardButtonState extends State<DownloadScorecardButton> {
  bool _working = false;

  Future<void> _download() async {
    setState(() => _working = true);
    try {
      final bytes = await buildScorecardPdf(widget.result);
      final safeNames = '${widget.result.teamName1}_vs_${widget.result.teamName2}'.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '');
      await Printing.sharePdf(bytes: bytes, filename: 'scorecard_$safeNames.pdf');
    } catch (e) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("Couldn't generate scorecard"),
          content: SingleChildScrollView(child: Text('$e')),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.compact) {
      return IconButton(
        icon: _working
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.picture_as_pdf_outlined),
        tooltip: 'Download scorecard (PDF)',
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        onPressed: _working ? null : _download,
      );
    }
    return OutlinedButton.icon(
      onPressed: _working ? null : _download,
      icon: _working
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.download, size: 18),
      label: Text(_working ? 'Preparing…' : 'Download Scorecard'),
      style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF00695C), side: const BorderSide(color: Color(0xFF00695C))),
    );
  }
}
