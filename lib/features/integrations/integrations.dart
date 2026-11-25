// Default integration registry — the user's chosen order, and the
// whole list for now. Six apps + the LocalApps utility. Do NOT add
// more without the user asking: those are enough for now.
//
// ORDER (user-set, 25 Nov 2026):
//   1. WhatsApp    — deep links only (no personal-account API exists)
//   2. Gmail       — OAuth2, read-only
//   3. Google Drive — OAuth2, read-only (same Google client as Gmail)
//   4. GitHub      — personal access token, read-only
//   5. Instagram   — deep links only (no personal-account API exists)
//   6. Browsers    — launch a URL in Chrome / Opera / Edge / Firefox
//   + Local apps   — open an installed app by name (utility, no auth)
//
// No pricing, no tiers, no usage limits anywhere: DJ is the user's
// own app, no fee, unlimited.

import '../../services/system_ops.dart';
import 'browsers.dart';
import 'drive.dart';
import 'github.dart';
import 'gmail.dart';
import 'instagram.dart';
import 'integration.dart';
import 'local_apps.dart';
import 'whatsapp.dart';

export 'browsers.dart';
export 'drive.dart';
export 'github.dart';
export 'gmail.dart';
export 'google_oauth.dart';
export 'instagram.dart';
export 'integration.dart';
export 'local_apps.dart';
export 'whatsapp.dart';

/// Build the registry in the user's order.
///
/// [dataDir] is the dj_data folder (tokens live in
/// dj_config.json inside it). [systemOps] is the platform SystemOps.
IntegrationRegistry defaultRegistry({
  required String dataDir,
  required SystemOps systemOps,
}) {
  final registry = IntegrationRegistry();
  registry.register(WhatsAppIntegration(systemOps: systemOps));
  registry.register(GmailIntegration(dataDir: dataDir));
  registry.register(DriveIntegration(dataDir: dataDir));
  registry.register(GitHubIntegration(dataDir: dataDir));
  registry.register(InstagramIntegration(systemOps: systemOps));
  registry.register(BrowsersIntegration(systemOps: systemOps));
  registry.register(LocalAppsIntegration(systemOps: systemOps));
  return registry;
}
