// DJ — shared types. Dart port of src/shared/types.ts.
// Field names match the TypeScript types exactly so stored JSON
// (dj_config.json, keyword_index.json, vectors_meta.json) stays compatible.
import 'dart:convert';

String _s(Map<String, dynamic> j, String k, [String d = '']) =>
    j[k] is String ? j[k] as String : d;
int _i(Map<String, dynamic> j, String k, [int d = 0]) =>
    j[k] is num ? (j[k] as num).toInt() : d;
double _d(Map<String, dynamic> j, String k, [double d = 0]) =>
    j[k] is num ? (j[k] as num).toDouble() : d;
bool _b(Map<String, dynamic> j, String k, [bool d = false]) =>
    j[k] is bool ? j[k] as bool : d;

class FolderEntry {
  final String path;
  final bool enabled;
  const FolderEntry({required this.path, this.enabled = true});
  factory FolderEntry.fromJson(Map<String, dynamic> j) =>
      FolderEntry(path: _s(j, 'path'), enabled: _b(j, 'enabled', true));
  Map<String, dynamic> toJson() => {'path': path, 'enabled': enabled};
}

class LocalModelConfig {
  final String kind; // 'ollama' | 'lmstudio'
  final String? model;
  const LocalModelConfig({required this.kind, this.model});
  factory LocalModelConfig.fromJson(Map<String, dynamic> j) =>
      LocalModelConfig(kind: _s(j, 'kind'), model: j['model'] as String?);
  Map<String, dynamic> toJson() =>
      {'kind': kind, if (model != null) 'model': model};
}

class CloudConfig {
  final String provider; // 'openai' | 'openrouter' | 'anthropic'
  final String? apiKey;
  const CloudConfig({required this.provider, this.apiKey});
  factory CloudConfig.fromJson(Map<String, dynamic> j) =>
      CloudConfig(provider: _s(j, 'provider'), apiKey: j['apiKey'] as String?);
  Map<String, dynamic> toJson() =>
      {'provider': provider, if (apiKey != null) 'apiKey': apiKey};
}

class AppConfig {
  final List<FolderEntry> folders;
  final LocalModelConfig? localModel;
  final CloudConfig? cloud;
  final bool? startAtLogin;
  final bool? trayNoteSeen;
  /// When true, DJ tries the local model before the cloud when
  /// answering questions. Null = cloud first (the default).
  final bool? preferLocal;
  /// Privacy Screen sensitivity, 0.0 (lenient) to 1.0 (strict).
  /// Null = 0.75 (the default).
  final double? privacySensitivity;
  /// Privacy Screen: warn about a second face in view. Null = true.
  final bool? privacyDetectShoulderSurfers;
  /// Privacy Screen: start protection when DJ starts. Null = false.
  final bool? privacyStartOnLaunch;
  const AppConfig({
    required this.folders,
    this.localModel,
    this.cloud,
    this.startAtLogin,
    this.trayNoteSeen,
    this.preferLocal,
    this.privacySensitivity,
    this.privacyDetectShoulderSurfers,
    this.privacyStartOnLaunch,
  });
  factory AppConfig.fromJson(Map<String, dynamic> j) => AppConfig(
        folders: (j['folders'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(FolderEntry.fromJson)
            .toList(),
        localModel: j['localModel'] is Map<String, dynamic>
            ? LocalModelConfig.fromJson(j['localModel'])
            : null,
        cloud: j['cloud'] is Map<String, dynamic>
            ? CloudConfig.fromJson(j['cloud'])
            : null,
        startAtLogin: j['startAtLogin'] as bool?,
        trayNoteSeen: j['trayNoteSeen'] as bool?,
        preferLocal: j['preferLocal'] as bool?,
        privacySensitivity: j['privacySensitivity'] is num
            ? (j['privacySensitivity'] as num).toDouble()
            : null,
        privacyDetectShoulderSurfers:
            j['privacyDetectShoulderSurfers'] as bool?,
        privacyStartOnLaunch: j['privacyStartOnLaunch'] as bool?,
      );
  Map<String, dynamic> toJson() => {
        'folders': folders.map((f) => f.toJson()).toList(),
        if (localModel != null) 'localModel': localModel!.toJson(),
        if (cloud != null) 'cloud': cloud!.toJson(),
        if (startAtLogin != null) 'startAtLogin': startAtLogin,
        if (trayNoteSeen != null) 'trayNoteSeen': trayNoteSeen,
        if (preferLocal != null) 'preferLocal': preferLocal,
        if (privacySensitivity != null)
          'privacySensitivity': privacySensitivity,
        if (privacyDetectShoulderSurfers != null)
          'privacyDetectShoulderSurfers': privacyDetectShoulderSurfers,
        if (privacyStartOnLaunch != null)
          'privacyStartOnLaunch': privacyStartOnLaunch,
      };
  AppConfig copyWith({
    List<FolderEntry>? folders,
    LocalModelConfig? localModel,
    CloudConfig? cloud,
    bool? startAtLogin,
    bool? trayNoteSeen,
    bool? preferLocal,
    double? privacySensitivity,
    bool? privacyDetectShoulderSurfers,
    bool? privacyStartOnLaunch,
  }) =>
      AppConfig(
        folders: folders ?? this.folders,
        localModel: localModel ?? this.localModel,
        cloud: cloud ?? this.cloud,
        startAtLogin: startAtLogin ?? this.startAtLogin,
        trayNoteSeen: trayNoteSeen ?? this.trayNoteSeen,
        preferLocal: preferLocal ?? this.preferLocal,
        privacySensitivity: privacySensitivity ?? this.privacySensitivity,
        privacyDetectShoulderSurfers:
            privacyDetectShoulderSurfers ?? this.privacyDetectShoulderSurfers,
        privacyStartOnLaunch:
            privacyStartOnLaunch ?? this.privacyStartOnLaunch,
      );
}

typedef CapabilityLayer = String; // 'core' | 'local' | 'cloud'

class LocalModelHealth {
  final bool available;
  final String? name;
  final String? reason;
  const LocalModelHealth({required this.available, this.name, this.reason});
  factory LocalModelHealth.fromJson(Map<String, dynamic> j) =>
      LocalModelHealth(
          available: _b(j, 'available'),
          name: j['name'] as String?,
          reason: j['reason'] as String?);
  Map<String, dynamic> toJson() => {
        'available': available,
        if (name != null) 'name': name,
        if (reason != null) 'reason': reason,
      };
}

class CloudHealth {
  final bool configured;
  final bool? valid;
  final String? reason;
  final int? statusCode;
  const CloudHealth(
      {required this.configured, this.valid, this.reason, this.statusCode});
  factory CloudHealth.fromJson(Map<String, dynamic> j) => CloudHealth(
        configured: _b(j, 'configured'),
        valid: j['valid'] as bool?,
        reason: j['reason'] as String?,
        statusCode: j['statusCode'] is num ? (j['statusCode'] as num).toInt() : null,
      );
  Map<String, dynamic> toJson() => {
        'configured': configured,
        'valid': valid,
        if (reason != null) 'reason': reason,
        if (statusCode != null) 'statusCode': statusCode,
      };
}

class CapabilityStatus {
  final String layer; // CapabilityLayer
  final LocalModelHealth local;
  final CloudHealth cloud;
  final String message;
  final String checkedAt;
  const CapabilityStatus({
    required this.layer,
    required this.local,
    required this.cloud,
    required this.message,
    required this.checkedAt,
  });
  factory CapabilityStatus.fromJson(Map<String, dynamic> j) =>
      CapabilityStatus(
        layer: _s(j, 'layer', 'core'),
        local: j['local'] is Map<String, dynamic>
            ? LocalModelHealth.fromJson(j['local'])
            : const LocalModelHealth(available: false),
        cloud: j['cloud'] is Map<String, dynamic>
            ? CloudHealth.fromJson(j['cloud'])
            : const CloudHealth(configured: false),
        message: _s(j, 'message'),
        checkedAt: _s(j, 'checkedAt'),
      );
  Map<String, dynamic> toJson() => {
        'layer': layer,
        'local': local.toJson(),
        'cloud': cloud.toJson(),
        'message': message,
        'checkedAt': checkedAt,
      };
}

class TraceRecord {
  final String id;
  final String at;
  final String route;
  final List<String> tools;
  final int ms;
  final String layer;
  final String? fallback;
  const TraceRecord({
    required this.id,
    required this.at,
    required this.route,
    required this.tools,
    required this.ms,
    required this.layer,
    this.fallback,
  });
  factory TraceRecord.fromJson(Map<String, dynamic> j) => TraceRecord(
        id: _s(j, 'id'),
        at: _s(j, 'at'),
        route: _s(j, 'route'),
        tools: (j['tools'] as List? ?? []).whereType<String>().toList(),
        ms: _i(j, 'ms'),
        layer: _s(j, 'layer', 'core'),
        fallback: j['fallback'] as String?,
      );
  Map<String, dynamic> toJson() => {
        'id': id,
        'at': at,
        'route': route,
        'tools': tools,
        'ms': ms,
        'layer': layer,
        if (fallback != null) 'fallback': fallback,
      };
}

class SearchResult {
  final String path;
  final String name;
  final String folder;
  final String snippet;
  final double score;
  final int? size;
  final String? mtime;
  final String? note;
  const SearchResult({
    required this.path,
    required this.name,
    required this.folder,
    required this.snippet,
    required this.score,
    this.size,
    this.mtime,
    this.note,
  });
  factory SearchResult.fromJson(Map<String, dynamic> j) => SearchResult(
        path: _s(j, 'path'),
        name: _s(j, 'name'),
        folder: _s(j, 'folder'),
        snippet: _s(j, 'snippet'),
        score: _d(j, 'score'),
        size: j['size'] is num ? (j['size'] as num).toInt() : null,
        mtime: j['mtime'] as String?,
        note: j['note'] as String?,
      );
  Map<String, dynamic> toJson() => {
        'path': path,
        'name': name,
        'folder': folder,
        'snippet': snippet,
        'score': score,
        if (size != null) 'size': size,
        if (mtime != null) 'mtime': mtime,
        if (note != null) 'note': note,
      };
  SearchResult copyWith({String? note, String? snippet, double? score}) =>
      SearchResult(
        path: path,
        name: name,
        folder: folder,
        snippet: snippet ?? this.snippet,
        score: score ?? this.score,
        size: size,
        mtime: mtime,
        note: note ?? this.note,
      );
}

class IndexedFolder {
  final String path;
  final String name;
  final String parent;
  const IndexedFolder(
      {required this.path, required this.name, required this.parent});
  factory IndexedFolder.fromJson(Map<String, dynamic> j) => IndexedFolder(
      path: _s(j, 'path'), name: _s(j, 'name'), parent: _s(j, 'parent'));
  Map<String, dynamic> toJson() =>
      {'path': path, 'name': name, 'parent': parent};
}

/// One indexed file (keyword_index.json). `text` is the first 12,000 chars.
class IndexedFile {
  final String path;
  final String name;
  final String folder;
  final String text;
  final int? size;
  final double? mtimeMs;
  final String? note;
  const IndexedFile({
    required this.path,
    required this.name,
    required this.folder,
    required this.text,
    this.size,
    this.mtimeMs,
    this.note,
  });
  factory IndexedFile.fromJson(Map<String, dynamic> j) => IndexedFile(
        path: _s(j, 'path'),
        name: _s(j, 'name'),
        folder: _s(j, 'folder'),
        text: _s(j, 'text'),
        size: j['size'] is num ? (j['size'] as num).toInt() : null,
        mtimeMs: j['mtimeMs'] is num ? (j['mtimeMs'] as num).toDouble() : null,
        note: j['note'] as String?,
      );
  Map<String, dynamic> toJson() => {
        'path': path,
        'name': name,
        'folder': folder,
        'text': text,
        if (size != null) 'size': size,
        if (mtimeMs != null) 'mtimeMs': mtimeMs,
        if (note != null) 'note': note,
      };
}

typedef EmbedderState = String; // 'ready' | 'loading' | 'unavailable' | 'not-started'
typedef EmbedderSource = String; // 'bundled' | 'downloaded' | 'none'
typedef UpdateStatus = String; // 'idle'|'checking'|'available'|'downloading'|'ready'|'up-to-date'|'error'

class UpdateState {
  final String status;
  final String message;
  final String? version;
  const UpdateState({required this.status, required this.message, this.version});
  factory UpdateState.fromJson(Map<String, dynamic> j) => UpdateState(
      status: _s(j, 'status', 'idle'),
      message: _s(j, 'message'),
      version: j['version'] as String?);
  Map<String, dynamic> toJson() => {
        'status': status,
        'message': message,
        if (version != null) 'version': version,
      };
}

class DjStatus {
  final int filesIndexed;
  final int foldersIndexed;
  final bool vectorOk;
  final String embedderState;
  final String embedderSource;
  final bool hasIndex;
  final bool indexStale;
  final AppConfig config;
  final CapabilityStatus capability;
  final bool startAtLogin;
  final bool hasTray;
  const DjStatus({
    required this.filesIndexed,
    required this.foldersIndexed,
    required this.vectorOk,
    required this.embedderState,
    required this.embedderSource,
    required this.hasIndex,
    required this.indexStale,
    required this.config,
    required this.capability,
    required this.startAtLogin,
    required this.hasTray,
  });
  factory DjStatus.fromJson(Map<String, dynamic> j) => DjStatus(
        filesIndexed: _i(j, 'filesIndexed'),
        foldersIndexed: _i(j, 'foldersIndexed'),
        vectorOk: _b(j, 'vectorOk'),
        embedderState: _s(j, 'embedderState', 'not-started'),
        embedderSource: _s(j, 'embedderSource', 'none'),
        hasIndex: _b(j, 'hasIndex'),
        indexStale: _b(j, 'indexStale'),
        config: j['config'] is Map<String, dynamic>
            ? AppConfig.fromJson(j['config'])
            : AppConfig(folders: const []),
        capability: j['capability'] is Map<String, dynamic>
            ? CapabilityStatus.fromJson(j['capability'])
            : CapabilityStatus(
                layer: 'core',
                local: const LocalModelHealth(available: false),
                cloud: const CloudHealth(configured: false),
                message: 'Core only',
                checkedAt: DateTime.now().toIso8601String()),
        startAtLogin: _b(j, 'startAtLogin'),
        hasTray: _b(j, 'hasTray'),
      );
  Map<String, dynamic> toJson() => {
        'filesIndexed': filesIndexed,
        'foldersIndexed': foldersIndexed,
        'vectorOk': vectorOk,
        'embedderState': embedderState,
        'embedderSource': embedderSource,
        'hasIndex': hasIndex,
        'indexStale': indexStale,
        'config': config.toJson(),
        'capability': capability.toJson(),
        'startAtLogin': startAtLogin,
        'hasTray': hasTray,
      };
}

class OrganizeMove {
  final String name;
  final String old;
  final String newPath;
  final String folder;
  const OrganizeMove({
    required this.name,
    required this.old,
    required this.newPath,
    required this.folder,
  });
  factory OrganizeMove.fromJson(Map<String, dynamic> j) => OrganizeMove(
      name: _s(j, 'name'),
      old: _s(j, 'old'),
      newPath: _s(j, 'new'),
      folder: _s(j, 'folder'));
  Map<String, dynamic> toJson() =>
      {'name': name, 'old': old, 'new': newPath, 'folder': folder};
  OrganizeMove copyWith({String? newPath}) => OrganizeMove(
      name: name, old: old, newPath: newPath ?? this.newPath, folder: folder);
}

class DuplicateFile {
  final String path;
  final String name;
  final String folder;
  final String mtime;
  const DuplicateFile(
      {required this.path,
      required this.name,
      required this.folder,
      required this.mtime});
  factory DuplicateFile.fromJson(Map<String, dynamic> j) => DuplicateFile(
      path: _s(j, 'path'),
      name: _s(j, 'name'),
      folder: _s(j, 'folder'),
      mtime: _s(j, 'mtime'));
  Map<String, dynamic> toJson() =>
      {'path': path, 'name': name, 'folder': folder, 'mtime': mtime};
}

class DuplicateGroup {
  final String id;
  final int size;
  final String sizeText;
  final int wasted;
  final List<DuplicateFile> files;
  const DuplicateGroup({
    required this.id,
    required this.size,
    required this.sizeText,
    required this.wasted,
    required this.files,
  });
  factory DuplicateGroup.fromJson(Map<String, dynamic> j) => DuplicateGroup(
        id: _s(j, 'id'),
        size: _i(j, 'size'),
        sizeText: _s(j, 'sizeText'),
        wasted: _i(j, 'wasted'),
        files: (j['files'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(DuplicateFile.fromJson)
            .toList(),
      );
  Map<String, dynamic> toJson() => {
        'id': id,
        'size': size,
        'sizeText': sizeText,
        'wasted': wasted,
        'files': files.map((f) => f.toJson()).toList(),
      };
}

/// OrganizeRange — sealed union. JSON: {kind:'today'|'yesterday'|'lastDays'|'all', days?}
sealed class OrganizeRange {
  const OrganizeRange();
  String get kind;
  factory OrganizeRange.fromJson(Map<String, dynamic> j) {
    switch (j['kind']) {
      case 'today':
        return const OrganizeRangeToday();
      case 'yesterday':
        return const OrganizeRangeYesterday();
      case 'lastDays':
        return OrganizeRangeLastDays(days: _i(j, 'days', 1));
      case 'all':
      default:
        return const OrganizeRangeAll();
    }
  }
  Map<String, dynamic> toJson();
}

class OrganizeRangeToday extends OrganizeRange {
  const OrganizeRangeToday();
  @override
  String get kind => 'today';
  @override
  Map<String, dynamic> toJson() => {'kind': 'today'};
}

class OrganizeRangeYesterday extends OrganizeRange {
  const OrganizeRangeYesterday();
  @override
  String get kind => 'yesterday';
  @override
  Map<String, dynamic> toJson() => {'kind': 'yesterday'};
}

class OrganizeRangeLastDays extends OrganizeRange {
  final int days;
  const OrganizeRangeLastDays({required this.days});
  @override
  String get kind => 'lastDays';
  @override
  Map<String, dynamic> toJson() => {'kind': 'lastDays', 'days': days};
}

class OrganizeRangeAll extends OrganizeRange {
  const OrganizeRangeAll();
  @override
  String get kind => 'all';
  @override
  Map<String, dynamic> toJson() => {'kind': 'all'};
}

class ChatAction {
  final String action; // search|open|openFolder|summarize|organize|duplicates|list|openApp|help|ask
  final String query;
  const ChatAction({required this.action, required this.query});
  factory ChatAction.fromJson(Map<String, dynamic> j) =>
      ChatAction(action: _s(j, 'action'), query: _s(j, 'query'));
  Map<String, dynamic> toJson() => {'action': action, 'query': query};
}

/// ChatResponse — sealed union over the 12 kinds in types.ts.
sealed class ChatResponse {
  const ChatResponse();
  String get kind;
  String get text;
  Map<String, dynamic> toJson();
  factory ChatResponse.fromJson(Map<String, dynamic> j) {
    switch (j['kind']) {
      case 'search':
        return ChatResponseSearch(
            text: _s(j, 'text'),
            results: _results(j['results']));
      case 'opened':
        return ChatResponseOpened(
            text: _s(j, 'text'), results: _results(j['results']));
      case 'summary':
        return ChatResponseSummary(
            text: _s(j, 'text'),
            fileName: _s(j, 'fileName'),
            summary: _s(j, 'summary'),
            note: _s(j, 'note'));
      case 'organize-plan':
        return ChatResponseOrganizePlan(
          text: _s(j, 'text'),
          label: _s(j, 'label'),
          range: j['range'] is Map<String, dynamic>
              ? OrganizeRange.fromJson(j['range'])
              : const OrganizeRangeAll(),
          plan: (j['plan'] as List? ?? [])
              .whereType<Map<String, dynamic>>()
              .map(OrganizeMove.fromJson)
              .toList(),
        );
      case 'organize-done':
        return ChatResponseOrganizeDone(
          text: _s(j, 'text'),
          moved: (j['moved'] as List? ?? [])
              .whereType<Map<String, dynamic>>()
              .map(OrganizeMove.fromJson)
              .toList(),
          errors: (j['errors'] as List? ?? []).whereType<String>().toList(),
          logPath: _s(j, 'logPath'),
        );
      case 'duplicates':
        return ChatResponseDuplicates(
          text: _s(j, 'text'),
          groups: (j['groups'] as List? ?? [])
              .whereType<Map<String, dynamic>>()
              .map(DuplicateGroup.fromJson)
              .toList(),
        );
      case 'duplicates-deleted':
        return ChatResponseDuplicatesDeleted(
          text: _s(j, 'text'),
          deleted: (j['deleted'] as List? ?? []).whereType<String>().toList(),
          errors: (j['errors'] as List? ?? []).whereType<String>().toList(),
        );
      case 'duplicates-merged':
        return ChatResponseDuplicatesMerged(
          text: _s(j, 'text'),
          moved: (j['moved'] as List? ?? []).whereType<String>().toList(),
          errors: (j['errors'] as List? ?? []).whereType<String>().toList(),
        );
      case 'ask-range':
        return ChatResponseAskRange(text: _s(j, 'text'));
      case 'help':
        return ChatResponseHelp(text: _s(j, 'text'));
      case 'folders':
        return ChatResponseFolders(
          text: _s(j, 'text'),
          folders: (j['folders'] as List? ?? [])
              .whereType<Map<String, dynamic>>()
              .map(IndexedFolder.fromJson)
              .toList(),
        );
      case 'message':
      default:
        return ChatResponseMessage(text: _s(j, 'text'));
    }
  }
  static List<SearchResult> _results(Object? v) => (v as List? ?? [])
      .whereType<Map<String, dynamic>>()
      .map(SearchResult.fromJson)
      .toList();
}

class ChatResponseMessage extends ChatResponse {
  @override
  final String text;
  const ChatResponseMessage({required this.text});
  @override
  String get kind => 'message';
  @override
  Map<String, dynamic> toJson() => {'kind': kind, 'text': text};
}

class ChatResponseSearch extends ChatResponse {
  @override
  final String text;
  final List<SearchResult> results;
  const ChatResponseSearch({required this.text, required this.results});
  @override
  String get kind => 'search';
  @override
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'text': text,
        'results': results.map((r) => r.toJson()).toList(),
      };
}

class ChatResponseOpened extends ChatResponse {
  @override
  final String text;
  final List<SearchResult> results;
  const ChatResponseOpened({required this.text, required this.results});
  @override
  String get kind => 'opened';
  @override
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'text': text,
        'results': results.map((r) => r.toJson()).toList(),
      };
}

class ChatResponseSummary extends ChatResponse {
  @override
  final String text;
  final String fileName;
  final String summary;
  final String note;
  const ChatResponseSummary(
      {required this.text,
      required this.fileName,
      required this.summary,
      required this.note});
  @override
  String get kind => 'summary';
  @override
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'text': text,
        'fileName': fileName,
        'summary': summary,
        'note': note,
      };
}

class ChatResponseOrganizePlan extends ChatResponse {
  @override
  final String text;
  final String label;
  final OrganizeRange range;
  final List<OrganizeMove> plan;
  const ChatResponseOrganizePlan(
      {required this.text,
      required this.label,
      required this.range,
      required this.plan});
  @override
  String get kind => 'organize-plan';
  @override
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'text': text,
        'label': label,
        'range': range.toJson(),
        'plan': plan.map((m) => m.toJson()).toList(),
      };
}

class ChatResponseOrganizeDone extends ChatResponse {
  @override
  final String text;
  final List<OrganizeMove> moved;
  final List<String> errors;
  final String logPath;
  const ChatResponseOrganizeDone(
      {required this.text,
      required this.moved,
      required this.errors,
      required this.logPath});
  @override
  String get kind => 'organize-done';
  @override
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'text': text,
        'moved': moved.map((m) => m.toJson()).toList(),
        'errors': errors,
        'logPath': logPath,
      };
}

class ChatResponseDuplicates extends ChatResponse {
  @override
  final String text;
  final List<DuplicateGroup> groups;
  const ChatResponseDuplicates({required this.text, required this.groups});
  @override
  String get kind => 'duplicates';
  @override
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'text': text,
        'groups': groups.map((g) => g.toJson()).toList(),
      };
}

class ChatResponseDuplicatesDeleted extends ChatResponse {
  @override
  final String text;
  final List<String> deleted;
  final List<String> errors;
  const ChatResponseDuplicatesDeleted(
      {required this.text, required this.deleted, required this.errors});
  @override
  String get kind => 'duplicates-deleted';
  @override
  Map<String, dynamic> toJson() =>
      {'kind': kind, 'text': text, 'deleted': deleted, 'errors': errors};
}

class ChatResponseDuplicatesMerged extends ChatResponse {
  @override
  final String text;
  final List<String> moved;
  final List<String> errors;
  const ChatResponseDuplicatesMerged(
      {required this.text, required this.moved, required this.errors});
  @override
  String get kind => 'duplicates-merged';
  @override
  Map<String, dynamic> toJson() =>
      {'kind': kind, 'text': text, 'moved': moved, 'errors': errors};
}

class ChatResponseAskRange extends ChatResponse {
  @override
  final String text;
  const ChatResponseAskRange({required this.text});
  @override
  String get kind => 'ask-range';
  @override
  Map<String, dynamic> toJson() => {'kind': kind, 'text': text};
}

class ChatResponseHelp extends ChatResponse {
  @override
  final String text;
  const ChatResponseHelp({required this.text});
  @override
  String get kind => 'help';
  @override
  Map<String, dynamic> toJson() => {'kind': kind, 'text': text};
}

class ChatResponseFolders extends ChatResponse {
  @override
  final String text;
  final List<IndexedFolder> folders;
  const ChatResponseFolders({required this.text, required this.folders});
  @override
  String get kind => 'folders';
  @override
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'text': text,
        'folders': folders.map((f) => f.toJson()).toList(),
      };
}

class IndexProgress {
  final String stage; // 'scan' | 'read' | 'done'
  final int done;
  final int total;
  final String message;
  const IndexProgress(
      {required this.stage,
      required this.done,
      required this.total,
      required this.message});
  factory IndexProgress.fromJson(Map<String, dynamic> j) => IndexProgress(
      stage: _s(j, 'stage', 'scan'),
      done: _i(j, 'done'),
      total: _i(j, 'total'),
      message: _s(j, 'message'));
  Map<String, dynamic> toJson() =>
      {'stage': stage, 'done': done, 'total': total, 'message': message};
}

class SystemStats {
  final double? cpuPercent;
  final int cpuCores;
  final int totalMemBytes;
  final int freeMemBytes;
  final int uptimeSeconds;
  final String platform;
  final String checkedAt;
  const SystemStats({
    required this.cpuPercent,
    required this.cpuCores,
    required this.totalMemBytes,
    required this.freeMemBytes,
    required this.uptimeSeconds,
    required this.platform,
    required this.checkedAt,
  });
  factory SystemStats.fromJson(Map<String, dynamic> j) => SystemStats(
        cpuPercent:
            j['cpuPercent'] is num ? (j['cpuPercent'] as num).toDouble() : null,
        cpuCores: _i(j, 'cpuCores'),
        totalMemBytes: _i(j, 'totalMemBytes'),
        freeMemBytes: _i(j, 'freeMemBytes'),
        uptimeSeconds: _i(j, 'uptimeSeconds'),
        platform: _s(j, 'platform'),
        checkedAt: _s(j, 'checkedAt'),
      );
  Map<String, dynamic> toJson() => {
        'cpuPercent': cpuPercent,
        'cpuCores': cpuCores,
        'totalMemBytes': totalMemBytes,
        'freeMemBytes': freeMemBytes,
        'uptimeSeconds': uptimeSeconds,
        'platform': platform,
        'checkedAt': checkedAt,
      };
}

class MemoryDay {
  final String date;
  final String text;
  const MemoryDay({required this.date, required this.text});
  factory MemoryDay.fromJson(Map<String, dynamic> j) =>
      MemoryDay(date: _s(j, 'date'), text: _s(j, 'text'));
  Map<String, dynamic> toJson() => {'date': date, 'text': text};
}

class MemoryContent {
  final String memoryMd;
  final List<MemoryDay> daily;
  const MemoryContent({required this.memoryMd, required this.daily});
  factory MemoryContent.fromJson(Map<String, dynamic> j) => MemoryContent(
        memoryMd: _s(j, 'memoryMd'),
        daily: (j['daily'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(MemoryDay.fromJson)
            .toList(),
      );
  Map<String, dynamic> toJson() => {
        'memoryMd': memoryMd,
        'daily': daily.map((d) => d.toJson()).toList(),
      };
}

class IndexCounts {
  final int files;
  final int folders;
  final int chunks;
  final int embedded;
  final int keywordOnly;
  final int skipped;
  final int errors;
  final double seconds;
  final bool vectorOk;
  final int? reused;
  final int? newCount;
  final int? removed;
  final List<String>? skippedNames;
  const IndexCounts({
    required this.files,
    required this.folders,
    required this.chunks,
    required this.embedded,
    required this.keywordOnly,
    required this.skipped,
    required this.errors,
    required this.seconds,
    required this.vectorOk,
    this.reused,
    this.newCount,
    this.removed,
    this.skippedNames,
  });
  factory IndexCounts.fromJson(Map<String, dynamic> j) => IndexCounts(
        files: _i(j, 'files'),
        folders: _i(j, 'folders'),
        chunks: _i(j, 'chunks'),
        embedded: _i(j, 'embedded'),
        keywordOnly: _i(j, 'keywordOnly'),
        skipped: _i(j, 'skipped'),
        errors: _i(j, 'errors'),
        seconds: _d(j, 'seconds'),
        vectorOk: _b(j, 'vectorOk'),
        reused: j['reused'] is num ? (j['reused'] as num).toInt() : null,
        newCount: j['new'] is num ? (j['new'] as num).toInt() : null,
        removed: j['removed'] is num ? (j['removed'] as num).toInt() : null,
        skippedNames:
            (j['skippedNames'] as List?)?.whereType<String>().toList(),
      );
  Map<String, dynamic> toJson() => {
        'files': files,
        'folders': folders,
        'chunks': chunks,
        'embedded': embedded,
        'keywordOnly': keywordOnly,
        'skipped': skipped,
        'errors': errors,
        'seconds': seconds,
        'vectorOk': vectorOk,
        if (reused != null) 'reused': reused,
        if (newCount != null) 'new': newCount,
        if (removed != null) 'removed': removed,
        if (skippedNames != null) 'skippedNames': skippedNames,
      };
}

class EmbedRequest {
  final String id;
  final List<String> texts;
  final bool forQuery;
  const EmbedRequest(
      {required this.id, required this.texts, required this.forQuery});
  factory EmbedRequest.fromJson(Map<String, dynamic> j) => EmbedRequest(
        id: _s(j, 'id'),
        texts: (j['texts'] as List? ?? []).whereType<String>().toList(),
        forQuery: _b(j, 'forQuery'),
      );
  Map<String, dynamic> toJson() =>
      {'id': id, 'texts': texts, 'forQuery': forQuery};
}

class EmbedResponse {
  final String id;
  final List<List<double>>? vectors;
  final String? error;
  const EmbedResponse({required this.id, this.vectors, this.error});
  factory EmbedResponse.fromJson(Map<String, dynamic> j) => EmbedResponse(
        id: _s(j, 'id'),
        vectors: (j['vectors'] as List?)
            ?.map((row) => (row as List)
                .whereType<num>()
                .map((n) => n.toDouble())
                .toList())
            .toList(),
        error: j['error'] as String?,
      );
  Map<String, dynamic> toJson() => {
        'id': id,
        'vectors': vectors,
        if (error != null) 'error': error,
      };
}

/// One stored vector row (vectors_meta.json).
class VectorMeta {
  final String id;
  final String path;
  final String name;
  final String folder;
  final int chunk;
  final String text;
  const VectorMeta({
    required this.id,
    required this.path,
    required this.name,
    required this.folder,
    required this.chunk,
    required this.text,
  });
  factory VectorMeta.fromJson(Map<String, dynamic> j) => VectorMeta(
        id: _s(j, 'id'),
        path: _s(j, 'path'),
        name: _s(j, 'name'),
        folder: _s(j, 'folder'),
        chunk: _i(j, 'chunk'),
        text: _s(j, 'text'),
      );
  Map<String, dynamic> toJson() => {
        'id': id,
        'path': path,
        'name': name,
        'folder': folder,
        'chunk': chunk,
        'text': text,
      };
}

String prettyJson(Object value) =>
    const JsonEncoder.withIndent('  ').convert(value);
