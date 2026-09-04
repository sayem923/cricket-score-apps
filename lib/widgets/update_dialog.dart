import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/models.dart';

/// Shows the "new version available" dialog. Call once per app launch
/// (e.g. from HomeScreen.initState after StorageService.checkForUpdate()
/// comes back non-null) - never call this speculatively from build(), or
/// it'll try to reopen on every rebuild.
///
/// On Android, [info.storeUrl] is expected to be a *direct .apk download
/// link* (not a Play Store listing) - tapping "Update Now" downloads it
/// in-app with a progress bar, then hands it to the OS package installer,
/// same as manually downloading and tapping the file today. This only
/// makes sense while the app is sideloaded outside Play Store; once it's
/// actually published, point `store_url` at the Play Store listing instead
/// and this same dialog will just open that link in the browser (iOS
/// always does this too, since iOS has no sideloaded-APK equivalent).
///
/// [info.mandatory] (installed version below `min_required_version`)
/// removes the "Later" button and blocks the back gesture/button, so the
/// person can't dismiss their way past a required update.
Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) async {
  await showDialog(
    context: context,
    barrierDismissible: !info.mandatory,
    builder: (context) => PopScope(
      canPop: !info.mandatory,
      child: _UpdateDialogContent(info: info),
    ),
  );
}

class _UpdateDialogContent extends StatefulWidget {
  final UpdateInfo info;
  const _UpdateDialogContent({required this.info});

  @override
  State<_UpdateDialogContent> createState() => _UpdateDialogContentState();
}

enum _Stage { prompt, downloading, error }

class _UpdateDialogContentState extends State<_UpdateDialogContent> {
  _Stage _stage = _Stage.prompt;
  double _progress = 0;
  String? _errorText;

  bool get _isDirectApkLink => Platform.isAndroid && widget.info.storeUrl.toLowerCase().endsWith('.apk');

  Future<void> _startUpdate() async {
    if (!_isDirectApkLink) {
      // Not a raw APK link (Play Store listing, TestFlight, iOS, etc.) -
      // nothing an app can sideload-install for you, just hand it to the
      // browser/App Store like a normal link.
      final uri = Uri.parse(widget.info.storeUrl);
      if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!widget.info.mandatory && mounted) Navigator.pop(context);
      return;
    }

    setState(() {
      _stage = _Stage.downloading;
      _progress = 0;
    });

    try {
      final dir = await getTemporaryDirectory();
      final savePath = '${dir.path}/update.apk';
      await Dio().download(
        widget.info.storeUrl,
        savePath,
        onReceiveProgress: (received, total) {
          if (total > 0 && mounted) setState(() => _progress = received / total);
        },
      );
      if (!mounted) return;
      // Handing off to the OS package installer. The first time this
      // happens, Android will prompt the person to allow "install unknown
      // apps" for this app specifically - that's a one-time OS-level
      // permission, not something this code can pre-grant.
      final result = await OpenFilex.open(savePath);
      if (result.type != ResultType.done && mounted) {
        setState(() {
          _stage = _Stage.error;
          _errorText = result.message;
        });
        return;
      }
      // Installer is up; our dialog has done its job either way.
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _errorText = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;

    if (_stage == _Stage.downloading) {
      return AlertDialog(
        title: const Text('Downloading update…'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: _progress > 0 ? _progress : null),
            const SizedBox(height: 12),
            Text('${(_progress * 100).toStringAsFixed(0)}%'),
          ],
        ),
      );
    }

    if (_stage == _Stage.error) {
      return AlertDialog(
        title: const Text("Couldn't update"),
        content: SingleChildScrollView(
          child: Text(_errorText ?? 'Something went wrong while downloading the update.'),
        ),
        actions: [
          if (!info.mandatory)
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Later')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF00695C)),
            onPressed: () => setState(() => _stage = _Stage.prompt),
            child: const Text('Try Again'),
          ),
        ],
      );
    }

    return AlertDialog(
      title: Row(
        children: [
          Icon(info.mandatory ? Icons.system_update_alt : Icons.new_releases, color: const Color(0xFF00695C)),
          const SizedBox(width: 10),
          Expanded(child: Text(info.mandatory ? 'Update Required' : 'Update Available')),
        ],
      ),
      content: Text(
        info.message ??
            (info.mandatory
                ? 'A required update (v${info.latestVersion}) is available. Please update to keep using the app - you are currently on v${info.currentVersion}.'
                : 'A new version (v${info.latestVersion}) is available. You are currently on v${info.currentVersion}.'),
      ),
      actions: [
        if (!info.mandatory)
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Later')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF00695C)),
          onPressed: _startUpdate,
          child: const Text('Update Now'),
        ),
      ],
    );
  }
}
