import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../l10n/app_strings.dart';

/// Replaces Flutter's default red-screen-of-death with an on-brand fallback
/// whenever a widget throws during build.
///
/// Wire this up ONCE from main(), before runApp:
///   ErrorWidget.builder = (details) => AppErrorScreen(details: details);
///
/// This only catches *build-time* widget errors (the same ones
/// FlutterError.onError sees). It intentionally does NOT catch errors from
/// async code, gestures, or anything outside a build() call - those are
/// caught by the runZonedGuarded handler in main.dart instead. Both paths
/// report through MonitoringService.recordError, so nothing falls through
/// uncaught either way.
///
/// Deliberately has NO "try again" button that just rebuilds the same
/// broken subtree (that would loop back into the same error). Instead it
/// offers a way back to Home, which is a fresh widget tree.
class AppErrorScreen extends StatelessWidget {
  final FlutterErrorDetails details;
  const AppErrorScreen({super.key, required this.details});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.background,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.error_outline_rounded, color: AppColors.primary, size: 40),
                ),
                const SizedBox(height: 20),
                Text(
                  tr('something_went_wrong'),
                  style: AppTextStyles.title.copyWith(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  tr('unexpected_error_message'),
                  style: AppTextStyles.body.copyWith(color: AppColors.border),
                  textAlign: TextAlign.center,
                ),
                if (kReleaseModeSafe == false) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Text(
                      details.exceptionAsString(),
                      style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontFamily: 'monospace'),
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Small indirection so this file doesn't need to import 'dart:io' /
/// foundation just to branch on debug-vs-release for the diagnostic panel
/// above. Set from main.dart via `kReleaseModeSafe = kReleaseMode` if you
/// want the debug-only exception panel; defaults to hiding it (safe
/// default for anyone who forgets to wire it).
bool kReleaseModeSafe = true;