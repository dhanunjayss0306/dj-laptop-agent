// Workspace security. Port of src/main/v53/security.ts.
// Deny-all: a path is touchable only when it resolves inside an
// allowed root. ".." escapes and absolute paths outside every root
// are denied (null = do not touch).
import 'dart:io';

String _normalize(String p) {
  final isWindows = Platform.isWindows;
  var path = p.replaceAll(RegExp(r'[/\\]'), Platform.pathSeparator);
  // Resolve '.' and '..' lexically.
  final isAbs = path.startsWith(Platform.pathSeparator) ||
      RegExp(r'^[A-Za-z]:\\').hasMatch(path) ||
      RegExp(r'^[A-Za-z]:/').hasMatch(path);
  final parts = path.split(Platform.pathSeparator);
  final out = <String>[];
  for (final part in parts) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (out.isNotEmpty && !out.last.endsWith(':')) out.removeLast();
      continue;
    }
    out.add(part);
  }
  var result = out.join(Platform.pathSeparator);
  if (isAbs) {
    if (!(Platform.isWindows && RegExp(r'^[A-Za-z]:').hasMatch(result))) {
      result = '${Platform.pathSeparator}$result';
    }
  }
  if (isWindows) result = result.toLowerCase();
  return result;
}

bool _isAbsolute(String p) =>
    p.startsWith(Platform.pathSeparator) ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p) ||
    p.startsWith(r'\\');

class WorkspaceGuard {
  final List<String> roots;

  WorkspaceGuard(List<String> roots)
      : roots = roots.map(_normalize).where((r) => r.isNotEmpty).toList();

  /// Resolve a path to an absolute path inside the workspace, or
  /// null when it escapes. Null means "do not touch this file".
  String? resolve(String p) {
    if (p.isEmpty) return null;
    if (!_isAbsolute(p)) return null;
    final abs = _normalize(p);
    for (final root in roots) {
      if (abs == root || abs.startsWith('$root${Platform.pathSeparator}')) {
        return abs;
      }
    }
    return null;
  }

  /// Resolve a path relative to one root folder.
  String? resolveUnder(String root, String rel) {
    final joined = '$root${Platform.pathSeparator}$rel';
    return resolve(_normalize(joined));
  }

  bool isAllowed(String p) => resolve(p) != null;
}

/// A model provider: anything that can answer text and say whether
/// it is up. Local models, cloud models, and Core rules all speak
/// this one interface.
abstract class ModelProvider {
  String get id;
  String get kind; // 'core' | 'local' | 'cloud'
  Future<String> chat(String prompt);
  Future<bool> health();
}

/// The Core provider: rules only, no model, no key, no network.
/// Always healthy — it is the provider DJ falls back to.
class CoreProvider implements ModelProvider {
  @override
  String get id => 'core';
  @override
  String get kind => 'core';

  @override
  Future<String> chat(String prompt) async =>
      'Core only: I can find, open, organise, and summarise your files with rules — no model is running, so I cannot chat freely.';

  @override
  Future<bool> health() async => true;
}

class ProviderRegistry {
  final Map<String, ModelProvider> _providers = {};

  ProviderRegistry() {
    register(CoreProvider());
  }

  void register(ModelProvider provider) {
    _providers[provider.id] = provider;
  }

  ModelProvider? get(String id) => _providers[id];

  List<ModelProvider> list() => _providers.values.toList();

  /// The provider DJ uses when nothing else is up: Core.
  ModelProvider defaultProvider() => _providers['core']!;
}
