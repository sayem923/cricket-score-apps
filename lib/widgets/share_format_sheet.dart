import 'package:flutter/material.dart';
import '../l10n/app_strings.dart';

/// What the person picked from the share-format picker (#5 - Real-time
/// score share). A screen without a finished result (mid-match live
/// score) simply never passes includePdf: true, so that option never
/// shows up there in the first place - callers don't need to filter it
/// themselves.
enum ShareFormat { text, image, pdf }

/// Shows a small bottom sheet letting the person choose how to share -
/// plain text (fastest, works everywhere), an image (a designed card,
/// nicer for WhatsApp/Instagram), or PDF (the full scorecard, only offered
/// where one exists - see includePdf).
Future<void> showShareFormatSheet(
  BuildContext context, {
  required void Function(ShareFormat format) onSelect,
  bool includePdf = false,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (context) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 4),
            ListTile(
              leading: const Icon(Icons.text_snippet_outlined, color: Color(0xFF00695C)),
              title: Text(tr('share_as_text'), style: const TextStyle(color: Colors.black87)),
              onTap: () {
                Navigator.pop(context);
                onSelect(ShareFormat.text);
              },
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined, color: Color(0xFF00695C)),
              title: Text(tr('share_as_image'), style: const TextStyle(color: Colors.black87)),
              onTap: () {
                Navigator.pop(context);
                onSelect(ShareFormat.image);
              },
            ),
            if (includePdf)
              ListTile(
                leading: const Icon(Icons.picture_as_pdf_outlined, color: Color(0xFF00695C)),
                title: Text(tr('share_as_pdf'), style: const TextStyle(color: Colors.black87)),
                onTap: () {
                  Navigator.pop(context);
                  onSelect(ShareFormat.pdf);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}