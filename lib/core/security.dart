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
  late final List<String> _realRoots;

  WorkspaceGuard(List<String> roots)
      : roots = roots
            .where((r) => !r.contains('\x00'))
            .map(_normalize)
            .where((r) => r.isNotEmpty)
            .toList() {
    _realRoots = <String>[];
    for (final root in this.roots) {
      _realRoots.add(root);
      try {
        if (Directory(root).existsSync()) {
          final real = _normalize(Directory(root).resolveSymbolicLinksSync());
          if (real.isNotEmpty && !_realRoots.contains(real)) {
            _realRoots.add(real);
          }
        }
      } catch (_) {}
    }
  }

  bool _matchesAnyRoot(String normalizedPath, List<String> allowedRoots) {
    for (final root in allowedRoots) {
      if (normalizedPath == root ||
          normalizedPath.startsWith('$root${Platform.pathSeparator}')) {
        return true;
      }
    }
    return false;
  }

  /// Resolve a path to an absolute path inside the workspace, or
  /// null when it escapes. Null means "do not touch this file".
  String? resolve(String p) {
    if (p.isEmpty || p.contains('\x00')) return null;
    if (!_isAbsolute(p)) return null;
    final abs = _normalize(p);
    if (!_matchesAnyRoot(abs, roots)) return null;

    // Resolve symlinks / junctions on existing paths (or nearest existing
    // ancestor within a root) so a link inside a workspace cannot escape.
    final resolvedReal = _resolveExistingSymlink(abs);
    if (resolvedReal != null && !_matchesAnyRoot(resolvedReal, _realRoots)) {
      return null;
    }
    return abs;
  }

  String? _resolveExistingSymlink(String abs) {
    try {
      final type = FileSystemEntity.typeSync(abs, followLinks: false);
      if (type == FileSystemEntityType.link) {
        return _normalize(Link(abs).resolveSymbolicLinksSync());
      }
      if (type == FileSystemEntityType.file) {
        return _normalize(File(abs).resolveSymbolicLinksSync());
      }
      if (type == FileSystemEntityType.directory) {
        return _normalize(Directory(abs).resolveSymbolicLinksSync());
      }
      // Walk up to deepest existing parent; preserve the non-existent suffix
      // so new files in symlinked folders still resolve accurately, and stop
      // once we reach a path shorter than any allowed root.
      final sep = Platform.pathSeparator;
      var cursor = abs;
      while (cursor.contains(sep)) {
        final idx = cursor.lastIndexOf(sep);
        if (idx <= 0) break;
        final parent = cursor.substring(0, idx);
        if (parent.endsWith(':') || !_matchesAnyRoot(parent, roots)) break;
        if (Directory(parent).existsSync()) {
          final realParent =
              _normalize(Directory(parent).resolveSymbolicLinksSync());
          final suffix = abs.substring(parent.length);
          return '$realParent$suffix';
        }
        cursor = parent;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Resolve a path relative to one root folder.
  String? resolveUnder(String root, String rel) {
    if (rel.contains('\x00')) return null;
    final joined = '$root${Platform.pathSeparator}$rel';
    return resolve(_normalize(joined));
  }

  bool isAllowed(String p) => resolve(p) != null;
}

const Set<String> _sensitiveFileNames = {
  '.env',
  '.env.local',
  '.env.production',
  '.env.development',
  'dj_cloud.json',
  'dj_config.json',
  'credentials.json',
  'id_rsa',
  'id_ed25519',
  'id_ecdsa',
  'known_hosts',
  'authorized_keys',
};

const Set<String> _sensitiveExtensions = {
  '.pem',
  '.key',
  '.p12',
  '.pfx',
  '.kdbx',
  '.jks',
  '.keystore',
};

const Set<String> _sensitiveSegments = {
  '.ssh',
  '.gnupg',
  '.aws',
  '_private-donotshare',
};

/// True when [p] names a credential, secret, or DJ internal config file
/// that should never be indexed or read by AI tools.
bool isSensitivePath(String p) {
  if (p.isEmpty) return false;
  final parts = p.replaceAll('\\', '/').toLowerCase().split('/');
  for (final seg in parts) {
    if (_sensitiveSegments.contains(seg)) return true;
  }
  final name = parts.last;
  if (_sensitiveFileNames.contains(name) || name.startsWith('.env.')) {
    return true;
  }
  final dot = name.lastIndexOf('.');
  if (dot != -1 && _sensitiveExtensions.contains(name.substring(dot))) {
    return true;
  }
  return false;
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
