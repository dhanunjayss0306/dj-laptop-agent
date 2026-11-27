// Self-updater for DJ (Windows + release check for Android).
//
// Checks GitHub Releases (dhanunjayss0306/dj-laptop-agent) for a newer
// version, downloads dj-windows.zip to %TEMP%\dj_update, spawns a tiny
// detached PowerShell script to swap files in the running install folder,
// deletes the downloaded zip automatically, and relaunches dj.exe.
//
// Respects Store builds: if running from WindowsApps, update checks and
// self-install are disabled cleanly. User data in %APPDATA%\DJ\dj_data
// is never touched.

import 'dart:convert';
import 'dart:io';

const String kCurrentDjVersion = '1.2.16';
const String kGithubLatestReleaseUrl =
    'https://api.github.com/repos/dhanunjayss0306/dj-laptop-agent/releases/latest';

class DjReleaseInfo {
  const DjReleaseInfo({
    required this.version,
    required this.tagName,
    required this.htmlUrl,
    this.windowsZipUrl,
    this.androidApkUrl,
  });

  final String version;
  final String tagName;
  final String htmlUrl;
  final String? windowsZipUrl;
  final String? androidApkUrl;
}

/// Normalize `"v1.2.16+16"` or `"1.2.16"` into `[1, 2, 16]`.
List<int> parseSemver(String raw) {
  var clean = raw.trim().toLowerCase();
  if (clean.startsWith('v')) clean = clean.substring(1);
  final plus = clean.indexOf('+');
  if (plus != -1) clean = clean.substring(0, plus);
  final dash = clean.indexOf('-');
  if (dash != -1) clean = clean.substring(0, dash);
  final parts = clean.split('.');
  return [
    for (var i = 0; i < 3; i++)
      i < parts.length ? (int.tryParse(parts[i]) ?? 0) : 0,
  ];
}

/// True when [candidateTag] is strictly newer than [currentVersion].
bool isNewerVersion(String candidateTag, String currentVersion) {
  final a = parseSemver(candidateTag);
  final b = parseSemver(currentVersion);
  for (var i = 0; i < 3; i++) {
    if (a[i] > b[i]) return true;
    if (a[i] < b[i]) return false;
  }
  return false;
}

bool isWindowsStoreBuild() =>
    Platform.isWindows &&
    Platform.resolvedExecutable.toLowerCase().contains('\\windowsapps\\');

class DjAutoUpdater {
  /// Check GitHub Releases for a newer release. Returns null on network
  /// error, offline, or when running as a Windows Store package.
  Future<DjReleaseInfo?> checkLatest({
    String apiUrl = kGithubLatestReleaseUrl,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    if (isWindowsStoreBuild()) return null;
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.getUrl(Uri.parse(apiUrl)).timeout(timeout);
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('User-Agent', 'dj-laptop-agent/$kCurrentDjVersion');
      final res = await req.close().timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final body = await utf8.decodeStream(res).timeout(timeout);
      final json = jsonDecode(body);
      if (json is! Map<String, dynamic>) return null;
      final tag = json['tag_name']?.toString() ?? '';
      if (tag.isEmpty) return null;
      final htmlUrl = json['html_url']?.toString() ??
          'https://github.com/dhanunjayss0306/dj-laptop-agent/releases';

      String? winZip;
      String? androidApk;
      final assets = json['assets'];
      if (assets is List) {
        for (final asset in assets) {
          if (asset is! Map<String, dynamic>) continue;
          final name = asset['name']?.toString().toLowerCase() ?? '';
          final url = asset['browser_download_url']?.toString();
          if (url == null || url.isEmpty) continue;
          if (name.endsWith('.zip') && name.contains('windows')) {
            winZip = url;
          } else if (name.endsWith('.apk')) {
            androidApk = url;
          }
        }
      }
      final parsed = parseSemver(tag);
      return DjReleaseInfo(
        version: '${parsed[0]}.${parsed[1]}.${parsed[2]}',
        tagName: tag,
        htmlUrl: htmlUrl,
        windowsZipUrl: winZip,
        androidApkUrl: androidApk,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Download [zipUrl], extract it over the running Windows install folder
  /// via a temporary detached PowerShell helper, delete the temp zip, and
  /// relaunch `dj.exe`. Returns an error string on failure or null when the
  /// update helper has started (caller should then call `exit(0)`).
  Future<String?> downloadAndApplyWindowsUpdate(
    String zipUrl, {
    void Function(String status)? onProgress,
    Duration downloadTimeout = const Duration(minutes: 3),
  }) async {
    if (!Platform.isWindows) return 'Auto-update is Windows-only.';
    if (isWindowsStoreBuild()) return 'Managed by the Microsoft Store.';
    final exePath = Platform.resolvedExecutable;
    final installDir = File(exePath).parent.path;

    final tempRoot = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}dj_update',
    );
    await tempRoot.create(recursive: true);
    final zipFile = File('${tempRoot.path}${Platform.pathSeparator}dj-windows.zip');
    final scriptFile =
        File('${tempRoot.path}${Platform.pathSeparator}apply_update.ps1');

    onProgress?.call('Downloading update...');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req =
          await client.getUrl(Uri.parse(zipUrl)).timeout(downloadTimeout);
      req.headers.set('User-Agent', 'dj-laptop-agent/$kCurrentDjVersion');
      final res = await req.close().timeout(downloadTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return 'Download failed (HTTP ${res.statusCode}).';
      }
      final sink = zipFile.openWrite();
      try {
        await res.pipe(sink).timeout(downloadTimeout);
      } finally {
        await sink.close();
      }
    } catch (e) {
      return 'Download failed: $e';
    } finally {
      client.close(force: true);
    }

    // Verify valid PK zip header before replacing anything.
    try {
      final len = await zipFile.length();
      if (len < 1024) return 'Downloaded update file is incomplete.';
      final raf = await zipFile.open();
      try {
        final magic = await raf.read(2);
        if (magic.length < 2 || magic[0] != 0x50 || magic[1] != 0x4B) {
          return 'Downloaded update is not a valid zip archive.';
        }
      } finally {
        await raf.close();
      }
    } catch (e) {
      return 'Could not verify update zip: $e';
    }

    onProgress?.call('Installing and restarting...');
    String esc(String s) => s.replaceAll("'", "''");
    final script = '''
\$ErrorActionPreference = 'Stop'
\$targetPid = $pid
\$zipPath = '${esc(zipFile.path)}'
\$installDir = '${esc(installDir)}'
\$exePath = '${esc(exePath)}'
try { Wait-Process -Id \$targetPid -Timeout 12 -ErrorAction SilentlyContinue } catch {}
Start-Sleep -Milliseconds 500
Expand-Archive -LiteralPath \$zipPath -DestinationPath \$installDir -Force
Remove-Item -LiteralPath \$zipPath -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath \$exePath) {
  Start-Process -FilePath \$exePath -WorkingDirectory \$installDir
}
''';
    await scriptFile.writeAsString(script, encoding: utf8);

    try {
      await Process.start(
        'powershell.exe',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          scriptFile.path,
        ],
        mode: ProcessStartMode.detached,
      );
      return null;
    } catch (e) {
      return 'Could not launch updater: $e';
    }
  }
}
