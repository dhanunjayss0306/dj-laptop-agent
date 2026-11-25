// Shared app state: the services are created once in main.dart and
// handed to every page through this holder. The UI calls the real
// service APIs only; nothing here invents a service method.
//
// Gaps this holder works around (see report):
// - No service builds a DjStatus, so it is assembled here from
//   IndexService.status(), the embedder state/source, config, and
//   CapabilityManager.resolve().
// - No update service exists in the Flutter build, so updateState
//   stays idle and the update banner never shows.
// - No config field stores the Cloud Worker URL, so the optional
//   Cloud settings live in dj_cloud.json next to dj_config.json.
// - No API reports whether a tray icon exists, so hasTray is
//   Platform.isWindows (the Windows runner creates the tray).
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import '../core/agent_loop.dart';
import '../core/capability.dart';
import '../core/config.dart' as cfg;
import '../core/local_model.dart';
import '../core/models.dart';
import '../core/worker_client.dart';
import '../features/account/account.dart';
import '../features/agent_mode.dart';
import '../features/integrations/integrations.dart';
import '../features/routines.dart';
import '../features/screen_qa.dart';
import '../features/walkthrough.dart';
import '../platform/cursor_channel.dart';
import '../platform/floating_button_channel.dart';
import '../platform/hotkey_channel.dart';
import '../platform/input_channel.dart';
import '../platform/screen_channel.dart';
import '../platform/voice_channel.dart';
import '../services/app_launcher.dart';
import '../services/chat_service.dart';
import '../services/duplicate_service.dart';
import '../services/index_service.dart';
import '../services/system_ops.dart';

class CloudSettings {
  final String workerUrl;
  // 'gemini' | 'groq' | 'nvidia' | 'openai' | 'openrouter' | 'anthropic'.
  // Default is Gemini: the best free provider (research brain, big
  // context). Keys never live here — only as Worker secrets.
  final String provider;
  /// Model name for the provider. Empty = the provider's free default.
  /// Model names change often, so this is a free-text field in Settings.
  final String model;
  const CloudSettings({
    this.workerUrl = '',
    this.provider = 'gemini',
    this.model = '',
  });
}

class DjAppState {
  DjAppState({
    required this.dataDir,
    required this.systemOps,
    Embedder? embedder,
  }) {
    configRepo = cfg.ConfigRepository(dataDir: dataDir);
    config = ValueNotifier<AppConfig>(configRepo.load());
    indexer = IndexService(
      dataDir: dataDir,
      embedder: embedder ?? NotStartedEmbedder(),
      onProgress: (p) => indexProgress.value = p,
    );
    indexer.loadFromDisk();
    duplicates = DuplicateService(systemOps: systemOps);
    chat = ChatService(
      indexer: indexer,
      getFolders: () => cfg.enabledFolders(config.value),
      systemOps: systemOps,
      duplicates: duplicates,
      local: LocalModelClient(),
      localModel: config.value.localModel,
      preferLocal: config.value.preferLocal ?? false,
    );
    _refreshChatCloud();
    capability =
        CapabilityManager.withDefaultProbes(() => config.value);
    memory = MemoryFiles(dataDir);
    hotkeyChannel = HotkeyChannel();
    floatingButtonChannel = FloatingButtonChannel();
    screenChannel = ScreenChannel();
    cursorChannel = CursorChannel();
    voiceChannel = VoiceChannel();
    inputChannel = InputChannel();
    appLauncher = AppLauncher(systemOps);
    agentMode = AgentMode(tools: _agentTools());
    routines = RoutineStore(
      dataDir: dataDir,
      systemOps: systemOps,
      appLauncher: appLauncher,
      runAgentTask: (task) async => agentMode.run(task),
      newestFiles: () async =>
          indexer.listRecent().map((r) => r.path).toList(),
    );
    integrations = defaultRegistry(dataDir: dataDir, systemOps: systemOps);
    walkthroughEngine = WalkthroughEngine(cursor: cursorChannel);
  }

  final String dataDir;
  final SystemOps systemOps;

  late final cfg.ConfigRepository configRepo;
  late final IndexService indexer;
  late final DuplicateService duplicates;
  late final ChatService chat;
  late final CapabilityManager capability;
  late final MemoryFiles memory;

  /// HeyClicky channels and features, wired once here so every page
  /// shares the same instances. The channels make no native call
  /// until used, so constructing them is safe on any platform.
  late final HotkeyChannel hotkeyChannel;
  late final FloatingButtonChannel floatingButtonChannel;
  late final ScreenChannel screenChannel;
  late final CursorChannel cursorChannel;
  late final VoiceChannel voiceChannel;
  late final InputChannel inputChannel;
  late final AppLauncher appLauncher;
  late final AgentMode agentMode;
  late final RoutineStore routines;
  late final IntegrationRegistry integrations;
  late final WalkthroughEngine walkthroughEngine;

  late final ValueNotifier<AppConfig> config;
  final ValueNotifier<DjStatus?> status = ValueNotifier<DjStatus?>(null);
  final ValueNotifier<IndexProgress?> indexProgress =
      ValueNotifier<IndexProgress?>(null);
  final ValueNotifier<bool> buildingIndex = ValueNotifier<bool>(false);
  final ValueNotifier<bool> trayNoteVisible = ValueNotifier<bool>(false);
  final ValueNotifier<UpdateState> updateState = ValueNotifier<UpdateState>(
    const UpdateState(status: 'idle', message: ''),
  );

  /// Text of the last finished index build, for the chat to post.
  String? lastIndexBuiltText;
  final ValueNotifier<int> indexBuiltVersion = ValueNotifier<int>(0);

  String get homeDir {
    final h = systemOps.getHomeDir();
    if (h.isNotEmpty) return h;
    return cfg.getHomeDir();
  }

  String get downloadsDir => cfg.getDownloadsDir(homeDir);

  /// Refresh capability (fresh when [force] is true, cached otherwise)
  /// and rebuild the assembled DjStatus.
  Future<DjStatus> refreshStatus({bool force = false}) async {
    final cap = await capability.resolve(force);
    final s = indexer.status();
    final assembled = DjStatus(
      filesIndexed: s.filesIndexed,
      foldersIndexed: s.foldersIndexed,
      vectorOk: s.vectorOk,
      embedderState: indexer.embedder.state,
      embedderSource: indexer.embedder.source,
      hasIndex: indexer.hasIndex(),
      indexStale: indexer.indexIsStale(),
      config: config.value,
      capability: cap,
      startAtLogin: config.value.startAtLogin ?? false,
      hasTray: Platform.isWindows,
    );
    status.value = assembled;
    return assembled;
  }

  /// Save config to disk and refresh status.
  Future<void> saveConfig(AppConfig next) async {
    configRepo.save(next);
    config.value = next;
    _refreshChatLocal();
    await refreshStatus();
  }

  /// Point the chat file-Q&A at the saved local-model pick (server
  /// + model name, and whether Local goes first). Called at startup
  /// (via the ChatService constructor) and whenever settings are
  /// saved.
  void _refreshChatLocal() {
    chat.localModel = config.value.localModel;
    chat.preferLocal = config.value.preferLocal ?? false;
  }

  /// Full index rebuild over the enabled folders. Returns the counts,
  /// or null when a build is already running.
  Future<IndexCounts?> rebuildIndex() async {
    if (buildingIndex.value) return null;
    buildingIndex.value = true;
    indexProgress.value = null;
    try {
      final counts = await indexer.build(cfg.enabledFolders(config.value));
      lastIndexBuiltText = IndexService.indexBuiltSummary(counts);
      indexBuiltVersion.value++;
      await refreshStatus();
      return counts;
    } finally {
      buildingIndex.value = false;
      indexProgress.value = null;
    }
  }

  /// Called once by the tray channel the first time the window hides
  /// into the tray. Sets the persisted flag and shows the note banner
  /// once; it never shows again after that.
  Future<void> onTrayHidden() async {
    if (config.value.trayNoteSeen == true) return;
    final next = config.value.copyWith(trayNoteSeen: true);
    configRepo.save(next);
    config.value = next;
    trayNoteVisible.value = true;
    await refreshStatus();
  }

  void dismissTrayNote() {
    trayNoteVisible.value = false;
  }

  // -- Optional Cloud settings (dj_cloud.json, local only) ----------

  String get _cloudPath =>
      '$dataDir${Platform.pathSeparator}dj_cloud.json';

  CloudSettings loadCloudSettings() {
    try {
      final file = File(_cloudPath);
      if (!file.existsSync()) return const CloudSettings();
      final data = jsonDecode(file.readAsStringSync());
      if (data is! Map<String, dynamic>) return const CloudSettings();
      final provider = data['provider'] as String?;
      final model = data['model'] as String?;
      return CloudSettings(
        workerUrl: data['workerUrl'] as String? ?? '',
        provider: _isKnownProvider(provider) ? provider! : 'gemini',
        model: model ?? '',
      );
    } catch (_) {
      return const CloudSettings();
    }
  }

  void saveCloudSettings(CloudSettings settings) {
    Directory(dataDir).createSync(recursive: true);
    File(_cloudPath).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'workerUrl': settings.workerUrl,
        'provider': settings.provider,
        'model': settings.model,
      }),
      encoding: utf8,
    );
    _refreshChatCloud();
  }

  /// True when [provider] is one of the six providers DJ knows.
  /// Anything else is not a provider DJ can talk to.
  static bool _isKnownProvider(String? provider) =>
      provider == 'gemini' ||
      provider == 'groq' ||
      provider == 'nvidia' ||
      provider == 'openai' ||
      provider == 'openrouter' ||
      provider == 'anthropic';

  /// Free default model per cloud provider. Model names change, so the
  /// Settings field lets the user type a newer one; this is only the
  /// starting point. Gemini 3.8 Flash is the current stable free Flash
  /// model (verified Nov 2026); Groq's gpt-oss-120b is free at
  /// 1,000 requests/day; NVIDIA's Nemotron 3 Super is free for
  /// prototyping on NIM.
  static String defaultCloudModel(String provider) => switch (provider) {
        'gemini' => 'gemini-3.8-flash',
        'groq' => 'openai/gpt-oss-120b',
        'nvidia' => 'nvidia/nemotron-3-super-120b-a12b',
        'anthropic' => 'claude-sonnet-4-5',
        _ => 'gpt-4o',
      };

  /// The model DJ actually asks: the saved one, or the provider's
  /// free default when the field is empty.
  static String effectiveCloudModel(CloudSettings settings) {
    final saved = settings.model.trim();
    return saved.isEmpty ? defaultCloudModel(settings.provider) : saved;
  }

  /// Map a saved provider name to the enum. Unknown names fall back to
  /// Gemini (the free default) — they never reach the Worker, so the
  /// Worker never sees a provider it does not know.
  static CloudProvider providerFor(String provider) => switch (provider) {
        'anthropic' => CloudProvider.anthropic,
        'openrouter' => CloudProvider.openrouter,
        'groq' => CloudProvider.groq,
        'nvidia' => CloudProvider.nvidia,
        'openai' => CloudProvider.openai,
        _ => CloudProvider.gemini,
      };

  /// Point the chat file-Q&A at the saved Worker settings (or clear
  /// it when no Worker URL is set). Called at startup and whenever
  /// the cloud settings are saved.
  void _refreshChatCloud() {
    final cloud = loadCloudSettings();
    chat.cloud = buildWorkerClient();
    chat.cloudProvider = providerFor(cloud.provider);
    chat.cloudModel = effectiveCloudModel(cloud);
  }

  // -- Cloud Worker client for ScreenQA -------------------------------

  /// A client for the saved Worker URL, or null when no URL is set.
  /// The caller owns the client and should close it when done.
  WorkerClient? buildWorkerClient() {
    final url = loadCloudSettings().workerUrl.trim();
    if (url.isEmpty) return null;
    return WorkerClient(url);
  }

  /// Vision model for a saved provider: the provider's default model.
  /// gemini-3.8-flash, gpt-4o and claude-sonnet-4-5 accept images, so
  /// screen Q&A works with Gemini, OpenAI, OpenRouter and Anthropic.
  /// Groq's and NVIDIA's defaults are text-only, so a screenshot
  /// question with those providers fails with a plain message — use
  /// Gemini or OpenAI for screen questions.
  static String visionModelFor(String provider) =>
      defaultCloudModel(provider);

  /// ScreenQA wired to the saved Cloud settings. When no Worker URL
  /// is set (or [client] is null), the returned ScreenQA has no
  /// vision function and answers with the Core-only fallback.
  ScreenQA buildScreenQA() => buildScreenQAForClient(buildWorkerClient());

  ScreenQA buildScreenQAForClient(WorkerClient? client) {
    if (client == null) {
      return ScreenQA(
        screen: screenChannel,
        cursor: cursorChannel,
        voice: voiceChannel,
      );
    }
    final cloud = loadCloudSettings();
    return ScreenQA(
      screen: screenChannel,
      cursor: cursorChannel,
      voice: voiceChannel,
      visionChat: makeWorkerVisionChat(
        client,
        provider: providerFor(cloud.provider),
        model: visionModelFor(cloud.provider),
      ),
      modelUp: () => true,
    );
  }

  // -- Hotkey (Windows) + floating button (Android) --------------------

  /// Register the Windows global hotkey (Ctrl+Alt+D) and show the
  /// Android floating DJ button. Each is a no-op on other platforms
  /// and returns false instead of throwing when the native side is
  /// not there. Call once at startup; the HomeShell listens for
  /// presses on [hotkeyChannel].
  Future<void> registerHotkeyAndFloatingButton() async {
    try {
      if (Platform.isWindows) {
        await hotkeyChannel.registerHotkey();
      } else if (Platform.isAndroid) {
        await floatingButtonChannel.showFloatingButton();
      }
    } catch (_) {
      // No native side yet: the hotkey simply never fires.
    }
  }

  // -- Account (Firebase, optional) -----------------------------------

  Account? _account;
  bool _accountTried = false;

  /// True only when Firebase was initialized (see FIREBASE-SETUP.md).
  /// False before setup: no firebase_options.dart, no
  /// google-services.json, no initializeApp call.
  bool get firebaseConfigured {
    try {
      return Firebase.apps.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// The DJ account, or null when Firebase is not configured yet.
  /// Never throws: when Firebase is unavailable the app runs fully
  /// without an account.
  Account? get account {
    if (_accountTried) return _account;
    _accountTried = true;
    if (!firebaseConfigured) return null;
    try {
      _account = Account.create(dataDir: dataDir);
    } catch (_) {
      _account = null;
    }
    return _account;
  }

  // -- AgentMode tools (real tools, no fakes) -------------------------

  Map<String, AgentToolFn> _agentTools() {
    return {
      'search': (input) async {
        final hits = await indexer.search(input, 5);
        if (hits.isEmpty) return 'No files found for "$input".';
        return hits.map((h) => h.name).join('\n');
      },
      'openFile': (input) async {
        final path = input.trim();
        if (path.isNotEmpty) {
          try {
            if (File(path).existsSync()) {
              final result = await systemOps.openFile(path);
              return result.message;
            }
          } catch (_) {}
        }
        final hits = await indexer.search(path, 3);
        if (hits.isEmpty) return 'No file found for "$input".';
        final result = await systemOps.openFile(hits.first.path);
        return result.ok ? 'Opened ${hits.first.name}.' : result.message;
      },
      'openApp': (input) async {
        final result = await appLauncher.openApp(input);
        return result.message;
      },
      'captureScreen': (_) async {
        final capture = await screenChannel.captureScreen();
        if (capture == null) return 'capture failed';
        return 'screen ${capture.width}x${capture.height}, '
            '${capture.png.length} bytes';
      },
      'point': (input) async {
        final coords = _parseCoords(input);
        if (coords == null) return 'No coordinates in "$input".';
        await cursorChannel.showCursor(coords.$1, coords.$2);
        return 'Pointed at ${coords.$1},${coords.$2}.';
      },
      'click': (input) async {
        final coords = _parseCoords(input);
        if (coords == null) return 'No coordinates in "$input".';
        await inputChannel.moveMouse(coords.$1, coords.$2);
        final ok = await inputChannel.click();
        return ok
            ? 'Clicked at ${coords.$1},${coords.$2}.'
            : 'Could not click at ${coords.$1},${coords.$2}.';
      },
      'type': (input) async {
        final ok = await inputChannel.typeText(input);
        return ok ? 'Typed.' : 'Could not type.';
      },
    };
  }

  static (int, int)? _parseCoords(String input) {
    final m = RegExp(r'^\s*(\d+)\s*,\s*(\d+)').firstMatch(input);
    if (m == null) return null;
    return (int.parse(m.group(1)!), int.parse(m.group(2)!));
  }
}

/// Capability badge label for a status, per PORTING-SPEC section 3.4.
/// Null status -> "Checking".
String capabilityBadgeLabel(CapabilityStatus? cap) {
  if (cap == null) return 'Checking';
  return switch (cap.layer) {
    'cloud' => 'Cloud',
    'local' => 'Local model',
    _ => 'Core only',
  };
}

/// Badge dot colour: green when a model/cloud layer is up, amber when
/// the cloud key is expired/invalid, neutral otherwise.
Color capabilityBadgeColor(CapabilityStatus? cap) {
  if (cap == null) return const Color(0xFF8E8E93);
  if (cap.layer == 'cloud' || cap.layer == 'local') {
    return const Color(0xFF1E7E34);
  }
  if (cap.cloud.valid == false) return const Color(0xFF9A6A00);
  return const Color(0xFF8E8E93);
}

/// Search mode line for the side nav Status section.
String searchModeLabel(DjStatus? status) {
  if (status == null) return 'loading status...';
  if (status.embedderState == 'loading') return 'loading status...';
  if (status.vectorOk && status.embedderState == 'ready') {
    return 'meaning search';
  }
  return 'keyword search only';
}

/// Embedder label for the side nav Status section.
String embedderLabel(DjStatus? status) {
  if (status == null) return 'embedder not started';
  return switch (status.embedderState) {
    'ready' => status.embedderSource == 'bundled'
        ? 'embedder ready (bundled model)'
        : status.embedderSource == 'downloaded'
            ? 'embedder ready (downloaded model)'
            : 'embedder ready',
    'loading' => 'embedder loading',
    'unavailable' => 'embedder not available',
    _ => 'embedder not started',
  };
}

/// Cloud key line for the StatusCards Model card.
String cloudKeyLine(CapabilityStatus cap) {
  if (cap.cloud.valid == true) return 'Cloud key works';
  if (cap.cloud.valid == false) return 'Cloud key expired or invalid';
  if (cap.cloud.configured) return 'Cloud key set, not checked yet';
  return 'No cloud key set';
}
