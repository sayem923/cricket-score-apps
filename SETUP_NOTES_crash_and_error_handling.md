# #1 Crash Reporting + Analytics, #2 Global Error Handling — Setup (Sentry)

Uses **Sentry**, not Firebase — this app's backend is Supabase, so Sentry
avoids standing up a separate Firebase project just for crash reports.
Setup is one DSN string, nothing else.

## Files added/changed
- `lib/services/monitoring_service.dart` — wraps Sentry (recordError, log, events).
- `lib/widgets/error_boundary.dart` — on-brand fallback screen instead of Flutter's red-screen-of-death.
- `lib/main.dart` — startup now runs inside `SentryFlutter.init(...)`, which installs its own error handling (no separate `runZonedGuarded` needed). Supabase URL/key now overridable via `--dart-define`.
- `lib/services/auth_service.dart` — logs `login` / `sign_up` events, clears the Sentry user on sign-out.
- `lib/l10n/app_strings.dart` — added `something_went_wrong` / `unexpected_error_message` (en + bn).

## Setup — 3 steps, ~5 minutes

### 1. Add one dependency to `pubspec.yaml`
```yaml
dependencies:
  sentry_flutter: ^8.10.0
```
(Check pub.dev for the latest version.) Then run:
```bash
flutter pub get
```

### 2. Get a free Sentry DSN
1. Go to https://sentry.io → sign up (free tier is plenty for this) → **Create Project** → pick **Flutter**.
2. Sentry shows you a DSN, looks like:
   `https://abc123@o000000.ingest.sentry.io/0000000`
3. Copy it.

### 3. Run the app with the DSN
```bash
flutter run --dart-define=SENTRY_DSN=https://abc123@o000000.ingest.sentry.io/0000000
```
No DSN passed → crash reporting is simply a no-op, app runs completely
normally. So nothing breaks if you skip this while just testing the UI.

For a real build (VS Code launch config / CI), add the same
`--dart-define` under `args` so you don't have to type it every time:
```json
// .vscode/launch.json
{
  "name": "cricket_score_apps",
  "request": "launch",
  "type": "dart",
  "args": ["--dart-define=SENTRY_DSN=https://abc123@o000000.ingest.sentry.io/0000000"]
}
```

## How to verify it's working
1. Run the app **with** the DSN set.
2. Anywhere (e.g. a button's `onPressed`), temporarily add:
   `throw Exception('test crash');`
3. Tap it → you should see the "Something went wrong" screen (not the red one).
4. Within a minute, the error shows up at https://sentry.io under your project's **Issues** tab.
5. Remove the test `throw` line afterwards.

## Where to go from here
- Sprinkle `MonitoringService.log('...')` breadcrumbs into the screens that
  matter most first: `match_scorer_screen.dart`, `start_match_screen.dart`,
  `tournament_dashboard.dart`.
- Any `try { ... } catch (e, st) { debugPrint(...) }` block already in
  `storage_service.dart` is a good candidate to also call
  `MonitoringService.recordError(e, st)` — right now those errors are only
  visible in a local `debugPrint`, not in Sentry.
