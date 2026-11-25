// DJ v5.3 primitives + trace store. Port of src/main/v53/primitives.ts.
// Defaults: no model, no key, Core only. Layers 1 and 2 switch on
// only when their probe says they are up.
import 'models.dart';

class DjPrimitives {
  final String model; // '' = none
  final List<String> fallbackChain;
  final String engineKind; // 'ollama' | 'lmstudio' | 'cloud' | 'none'
  final String defaultAgent; // 'simple' | 'tool-loop'
  final int maxToolSteps;
  final String memoryBackend; // 'markdown-files'
  final bool learningEnabled;
  final int maxTraces;

  const DjPrimitives({
    required this.model,
    required this.fallbackChain,
    required this.engineKind,
    required this.defaultAgent,
    required this.maxToolSteps,
    required this.memoryBackend,
    required this.learningEnabled,
    required this.maxTraces,
  });
}

DjPrimitives defaultPrimitives() => const DjPrimitives(
      model: '',
      fallbackChain: ['cloud', 'local', 'core'],
      engineKind: 'none',
      defaultAgent: 'simple',
      maxToolSteps: 8,
      memoryBackend: 'markdown-files',
      learningEnabled: true,
      maxTraces: 200,
    );

/// Bounded in-memory trace store. Oldest traces drop off; nothing
/// is written to disk and nothing is sent anywhere.
class TraceStore {
  final List<TraceRecord> _traces = [];
  final int maxTraces;
  int _counter = 0;

  TraceStore({this.maxTraces = 200});

  TraceRecord record({
    required String route,
    required List<String> tools,
    required int ms,
    required String layer,
    String? fallback,
  }) {
    final rec = TraceRecord(
      id: 'tr-${++_counter}',
      at: DateTime.now().toIso8601String(),
      route: route,
      tools: tools,
      ms: ms,
      layer: layer,
      fallback: fallback,
    );
    _traces.add(rec);
    while (_traces.length > maxTraces) {
      _traces.removeAt(0);
    }
    return rec;
  }

  List<TraceRecord> recent(int n) =>
      _traces.sublist(_traces.length - n < 0 ? 0 : _traces.length - n);

  int get count => _traces.length;

  ({int count, int avgMs, int toolCalls, int fallbacks, Map<String, int> byLayer})
      telemetry() {
    final byLayer = <String, int>{};
    var ms = 0;
    var toolCalls = 0;
    var fallbacks = 0;
    for (final t in _traces) {
      ms += t.ms;
      toolCalls += t.tools.length;
      if (t.fallback != null) fallbacks += 1;
      byLayer[t.layer] = (byLayer[t.layer] ?? 0) + 1;
    }
    return (
      count: _traces.length,
      avgMs: _traces.isEmpty ? 0 : (ms / _traces.length).round(),
      toolCalls: toolCalls,
      fallbacks: fallbacks,
      byLayer: byLayer,
    );
  }
}
