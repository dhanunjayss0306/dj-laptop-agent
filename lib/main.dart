// DJ entry point. The services are created once here and handed to
// the home shell: ConfigRepository, IndexService, ChatService,
// DuplicateService, CapabilityManager, and SystemOpsChannel.
// Window size on desktop (880x720) is handled by the Windows runner.
import 'dart:async';

import 'package:flutter/material.dart';

import 'core/config.dart';
import 'core/startup_log.dart';
import 'platform/system_ops_channel.dart';
import 'theme.dart';
import 'ui/app_state.dart';
import 'ui/home_shell.dart';

Future<void> main() async {
  StartupLog.log('main() entered');
  WidgetsFlutterBinding.ensureInitialized();
  final dataDir = await ConfigRepository.defaultDataDir();
  StartupLog.log('dataDir resolved');
  final systemOps = SystemOpsChannel();
  // The saved search index is NOT loaded here. Loading it (JSON decode
  // of keyword_index.json + reading vectors.bin) is synchronous work on
  // the UI isolate, and doing it before runApp delays the first frame
  // by however large the index has grown. It is loaded after the first
  // frame instead (see the post-frame callback below); the first-run
  // Folders dialog checks hasIndex() in its own post-frame callback,
  // which runs after this one.
  final app = DjAppState(
    dataDir: dataDir,
    systemOps: systemOps,
    loadIndex: false,
  );
  // The native runner calls onTrayHidden the first time the window
  // hides into the tray; the app state owns the show-once flag.
  systemOps.onTrayHidden = () => app.onTrayHidden();
  StartupLog.log('DjAppState created (index not loaded yet)');
  runApp(DjApp(app: app));
  StartupLog.log('runApp called');
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _firstFrameSeen = true;
    StartupLog.log('first frame built');
    app.loadIndexFromDisk();
    StartupLog.log('index loaded from disk');
  });
  // Watchdog: if the event loop is alive but the first frame still has
  // not been built 10 s after launch, say so in the log. (If the loop
  // itself is starved, this timer cannot fire — then the native
  // watchdog in windows/runner/flutter_window.cpp reports instead.)
  Timer(const Duration(seconds: 10), () {
    if (!_firstFrameSeen) {
      StartupLog.log(
          'WATCHDOG: first frame not built 10s after launch');
    }
  });
  // Register the Windows global hotkey (Ctrl+Alt+D) and show the
  // Android floating DJ button. No-op on other platforms, and never
  // blocks startup.
  // ignore: unawaited_futures
  app.registerHotkeyAndFloatingButton().then(
      (_) => StartupLog.log('hotkey registered'));
  // Privacy Screen: registers the Ctrl+Alt+P override hotkey (Windows
  // only) and starts protection if the setting is on. Never blocks
  // startup.
  // ignore: unawaited_futures
  app.privacyScreen.initialize().then(
      (_) => StartupLog.log('privacy screen initialized'));
  // Capability probes take up to a few seconds; refresh in the
  // background so startup is not blocked.
  // ignore: unawaited_futures
  app.refreshStatus().then(
      (_) => StartupLog.log('refreshStatus done'));
}

// Set by the first-frame post-frame callback above.
bool _firstFrameSeen = false;

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
