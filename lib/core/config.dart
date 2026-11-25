// Config repository. Port of src/main/config.ts + src/main/utils/paths.ts.
// Stored as pretty JSON in dj_config.json inside <appSupport>/dj_data.
// Corrupt or missing file -> defaults, never crash.
// DJ never indexes the whole C: drive.
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

String getHomeDir() {
  final env = Platform.environment;
  if (env['USERPROFILE'] != null && env['USERPROFILE']!.isNotEmpty) {
    return env['USERPROFILE']!;
  }
  if (env['HOME'] != null && env['HOME']!.isNotEmpty) return env['HOME']!;
  if (env['HOMEDRIVE'] != null) {
    return '${env['HOMEDRIVE'] ?? ''}${env['HOMEPATH'] ?? ''}';
  }
  return Directory.current.path;
}

/// The real Desktop folder. OneDrive Desktop first, else plain Desktop.
String findDesktop(String home) {
  final oneDrive = _join(home, 'OneDrive', 'Desktop');
  try {
    if (Directory(oneDrive).statSync().type == FileSystemEntityType.directory) {
      return oneDrive;
    }
  } catch (_) {}
  return _join(home, 'Desktop');
}

String getDownloadsDir(String home) => _join(home, 'Downloads');

String _join(String a, String b, [String? c]) {
  final sep = Platform.pathSeparator;
  var out = a.endsWith(sep) ? a : '$a$sep$b';
  if (c != null) out = '$out$sep$c';
  return out;
}

/// The five default folders DJ looks in.
List<FolderEntry> defaultFolders([String? home]) {
  final h = home ?? getHomeDir();
  final antigravity = _join(h, 'Antigravity');
  final userFiles = Directory(antigravity).existsSync() ? antigravity : h;
  return [
    FolderEntry(path: getDownloadsDir(h), enabled: true),
    FolderEntry(path: findDesktop(h), enabled: true),
    FolderEntry(path: _join(h, 'Documents'), enabled: true),
    FolderEntry(path: _join(h, 'Pictures'), enabled: true),
    FolderEntry(path: userFiles, enabled: true),
  ];
}

/// Enabled folder paths that actually exist on this machine.
List<String> enabledFolders(AppConfig config) {
  final out = <String>[];
  for (final entry in config.folders) {
    if (!entry.enabled) continue;
    try {
      if (Directory(entry.path).statSync().type ==
          FileSystemEntityType.directory) {
        out.add(entry.path);
      }
    } catch (_) {
      // Missing folder: skip it silently.
    }
  }
  return out;
}

class ConfigRepository {
  final String dataDir;
  String get configPath => '$dataDir${Platform.pathSeparator}dj_config.json';

  ConfigRepository({required this.dataDir});

  /// Default data dir: [appSupport]/dj_data (path_provider).
  /// Call this once at startup; pass the result to the constructor.
  static Future<String> defaultDataDir() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}${Platform.pathSeparator}dj_data';
  }

  bool exists() => File(configPath).existsSync();

  AppConfig load() {
    if (exists()) {
      try {
        final saved = jsonDecode(File(configPath).readAsStringSync());
        if (saved is Map<String, dynamic>) {
          final defaults = defaultConfig();
          // Merge over defaults so missing fields get defaults.
          return AppConfig(
            folders: saved['folders'] is List
                ? AppConfig.fromJson(saved).folders
                : defaults.folders,
            localModel: saved['localModel'] is Map<String, dynamic>
                ? LocalModelConfig.fromJson(saved['localModel'])
                : null,
            cloud: saved['cloud'] is Map<String, dynamic>
                ? CloudConfig.fromJson(saved['cloud'])
                : null,
            startAtLogin: saved['startAtLogin'] as bool?,
            trayNoteSeen: saved['trayNoteSeen'] as bool?,
            preferLocal: saved['preferLocal'] as bool?,
          );
        }
      } catch (_) {
        // Corrupt config: fall through to defaults.
      }
    }
    return defaultConfig();
  }

  void save(AppConfig config) {
    Directory(dataDir).createSync(recursive: true);
    File(configPath).writeAsStringSync(prettyJson(config.toJson()), encoding: utf8);
  }

  AppConfig defaultConfig() => AppConfig(folders: defaultFolders());
}
