// Capability layers. Port of src/main/v53/capability.ts + the
// probes in src/main/main.ts (checkLocalModel / checkCloudKey).
//
// Health probes + status display ONLY. No shipped code calls any
// LLM chat endpoint — do not invent an LLM chat path here.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

bool isAuthError(int? statusCode) => statusCode == 401 || statusCode == 403;

typedef CheckLocal = Future<LocalModelHealth> Function();
typedef CheckCloud = Future<CloudHealth> Function();

/// The Worker settings the cloud probe needs: the Worker URL and the
/// provider name. A record (not CloudSettings) so this core file does
/// not import the UI's app_state.dart, which imports this file.
typedef WorkerCloudSettings = ({String workerUrl, String provider});

class CapabilityProbes {
  final CheckLocal checkLocal;
  final CheckCloud checkCloud;
  const CapabilityProbes({required this.checkLocal, required this.checkCloud});
}

/// Probe a local model server: Ollama first, then LM Studio, each
/// with a 1.5 s timeout. First server that answers HTTP OK wins.
Future<LocalModelHealth> checkLocalModel({HttpClient? client}) async {
  final http = client ?? HttpClient();
  final servers = [
    ('Ollama', 'http://127.0.0.1:11434/api/tags'),
    ('LM Studio', 'http://127.0.0.1:1234/v1/models'),
  ];
  try {
    for (final (name, url) in servers) {
      try {
        final req = await http
            .getUrl(Uri.parse(url))
            .timeout(const Duration(milliseconds: 1500));
        final res = await req.close().timeout(const Duration(milliseconds: 1500));
        if (res.statusCode != 200) continue;
        final body = await res.transform(utf8.decoder).join();
        final data = jsonDecode(body);
        final models = data is Map ? data['models'] as List? : null;
        if (models != null && models.isNotEmpty) {
          final first = models.first;
          final modelName = first is Map
              ? (first['name'] ?? first['id'] ?? 'model').toString()
              : 'model';
          return LocalModelHealth(available: true, name: '$name ($modelName)');
        }
        return LocalModelHealth(available: true, name: name);
      } catch (_) {
        // Server not answering — try the next one.
      }
    }
  } finally {
    if (client == null) http.close();
  }
  return const LocalModelHealth(available: false, reason: 'local model not running');
}

/// Probe the cloud layer.
///
/// When a Worker URL is set ([workerUrl], from dj_cloud.json), the
/// Worker is the cloud layer: it is reported configured and available,
/// with the provider name carried in [CloudHealth.reason] so the badge
/// and Settings card can show it (e.g. "Cloud (gemini)"). There is no
/// provider key in the app to validate — the key lives only as a
/// Worker secret — so no network call is made here; a live check
/// happens on the first real Worker call. When no Worker URL is set,
/// fall back to the legacy probe of a provider API key in [config].
Future<CloudHealth> checkCloudKey(AppConfig config,
    {HttpClient? client, String? workerUrl, String? workerProvider}) async {
  final url = workerUrl?.trim() ?? '';
  if (url.isNotEmpty) {
    final provider = workerProvider?.trim() ?? '';
    return CloudHealth(
        configured: true,
        valid: true,
        reason: provider.isEmpty ? null : provider);
  }
  final cloud = config.cloud;
  final apiKey = cloud?.apiKey;
  if (apiKey == null || apiKey.isEmpty) {
    return const CloudHealth(
        configured: false, valid: null, reason: 'no cloud key set');
  }
  const bases = {
    'openai': 'https://api.openai.com/v1',
    'openrouter': 'https://openrouter.ai/api/v1',
    'anthropic': 'https://api.anthropic.com/v1',
  };
  final base = bases[cloud!.provider] ?? bases['openai']!;
  final http = client ?? HttpClient();
  try {
    final req = await http
        .getUrl(Uri.parse('$base/models'))
        .timeout(const Duration(milliseconds: 2000));
    if (cloud.provider == 'anthropic') {
      req.headers.set('x-api-key', apiKey);
      req.headers.set('anthropic-version', '2023-06-01');
    } else {
      req.headers.set('Authorization', 'Bearer $apiKey');
    }
    final res = await req.close().timeout(const Duration(milliseconds: 2000));
    // Drain the body so the connection can close cleanly.
    await res.drain<void>();
    if (res.statusCode == 200) {
      return const CloudHealth(configured: true, valid: true);
    }
    if (isAuthError(res.statusCode)) {
      return CloudHealth(
        configured: true,
        valid: false,
        statusCode: res.statusCode,
        reason: 'cloud key expired or invalid (${res.statusCode})',
      );
    }
    return CloudHealth(
      configured: true,
      valid: null,
      statusCode: res.statusCode,
      reason: 'cloud could not be checked',
    );
  } catch (_) {
    return const CloudHealth(
        configured: true, valid: null, reason: 'cloud could not be checked');
  } finally {
    if (client == null) http.close();
  }
}

class CapabilityManager {
  final CapabilityProbes probes;
  final int cacheMs;
  CapabilityStatus? _cached;
  int _cachedAt = 0;

  CapabilityManager({required this.probes, this.cacheMs = 30000});

  /// Default probes wired to a config loader. [loadWorkerCloud], when
  /// given, supplies the Worker settings from dj_cloud.json so the
  /// cloud probe reflects a configured Worker URL (see checkCloudKey);
  /// without it, only the legacy provider key in [AppConfig] is probed.
  factory CapabilityManager.withDefaultProbes(AppConfig Function() loadConfig,
          {WorkerCloudSettings Function()? loadWorkerCloud}) =>
      CapabilityManager(
        probes: CapabilityProbes(
          checkLocal: checkLocalModel,
          checkCloud: () {
            final worker = loadWorkerCloud?.call();
            return checkCloudKey(
              loadConfig(),
              workerUrl: worker?.workerUrl,
              workerProvider: worker?.provider,
            );
          },
        ),
      );

  CapabilityStatus? last() => _cached;

  /// Resolve the best layer available right now. Always returns a
  /// status — worst case, Layer 0 Core with the reasons why.
  /// 30 s cache; force=true bypasses it.
  Future<CapabilityStatus> resolve([bool force = false]) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && _cached != null && now - _cachedAt < cacheMs) {
      return _cached!;
    }
    final cloud = await _safeCheckCloud();
    final local = await _safeCheckLocal();

    String layer;
    String message;
    if (cloud.configured && cloud.valid == true) {
      layer = 'cloud';
      // When the cloud is a configured Worker, cloud.reason carries the
      // provider name (see checkCloudKey); a legacy key has no reason.
      final provider =
          cloud.reason != null && cloud.reason!.isNotEmpty ? ' (${cloud.reason})' : '';
      message =
          'Cloud$provider${local.available ? ' (local model also available)' : ''}';
    } else if (local.available) {
      layer = 'local';
      final cloudNote = cloud.configured && cloud.valid == false
          ? ' — ${cloud.reason ?? 'cloud key not working'}'
          : '';
      message = 'Local model${local.name != null ? ' (${local.name})' : ''}$cloudNote';
    } else {
      final reasons = <String>[];
      if (cloud.configured && cloud.valid == false) {
        reasons.add(cloud.reason ?? 'cloud key not working');
      } else if (cloud.configured) {
        reasons.add('cloud could not be checked');
      }
      reasons.add(local.reason ?? 'local model not running');
      layer = 'core';
      message = 'Core only: ${reasons.join(', ')}';
    }

    final status = CapabilityStatus(
      layer: layer,
      local: local,
      cloud: cloud,
      message: message,
      checkedAt: DateTime.now().toIso8601String(),
    );
    _cached = status;
    _cachedAt = now;
    return status;
  }

  /// Forces a fresh check (getCapability).
  Future<CapabilityStatus> getCapability() => resolve(true);

  /// Cached resolve (getStatus).
  Future<CapabilityStatus> getStatus() => resolve(false);

  Future<LocalModelHealth> _safeCheckLocal() async {
    try {
      return await probes.checkLocal();
    } catch (_) {
      return const LocalModelHealth(
          available: false, reason: 'local model could not be checked');
    }
  }

  Future<CloudHealth> _safeCheckCloud() async {
    try {
      return await probes.checkCloud();
    } catch (_) {
      return const CloudHealth(
          configured: false, valid: null, reason: 'cloud could not be checked');
    }
  }
}
