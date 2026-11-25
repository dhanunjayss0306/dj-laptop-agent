// DJ entry point. The services are created once here and handed to
// the home shell: ConfigRepository, IndexService, ChatService,
// DuplicateService, CapabilityManager, and SystemOpsChannel.
// Window size on desktop (880x720) is handled by the Windows runner.
import 'package:flutter/material.dart';

import 'core/config.dart';
import 'platform/system_ops_channel.dart';
import 'theme.dart';
import 'ui/app_state.dart';
import 'ui/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dataDir = await ConfigRepository.defaultDataDir();
  final systemOps = SystemOpsChannel();
  final app = DjAppState(dataDir: dataDir, systemOps: systemOps);
  // The native runner calls onTrayHidden the first time the window
  // hides into the tray; the app state owns the show-once flag.
  systemOps.onTrayHidden = () => app.onTrayHidden();
  runApp(DjApp(app: app));
  // Register the Windows global hotkey (Ctrl+Alt+D) and show the
  // Android floating DJ button. No-op on other platforms, and never
  // blocks startup.
  // ignore: unawaited_futures
  app.registerHotkeyAndFloatingButton();
  // Capability probes take up to a few seconds; refresh in the
  // background so startup is not blocked.
  // ignore: unawaited_futures
  app.refreshStatus();
}

class DjApp extends StatelessWidget {
  const DjApp({super.key, required this.app});

  final DjAppState app;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DJ - your files, found',
      theme: djTheme(),
      home: HomeShell(app: app),
    );
  }
}
