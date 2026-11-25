// Agent loop, memory files, skill playbooks, heartbeat.
// Port of src/main/v53/agentLoop.ts.
// NOTE: AgentLoop / coreThink / loadSkillPlaybooks are NOT called
// by the Electron app's main process — ported here as the shape,
// not as live behaviour. MemoryFiles + Heartbeat ARE used (heartbeat
// only re-resolves capability and notes layer changes; it never acts
// on files by itself).
import 'dart:async';
import 'dart:io';

typedef ToolFn = FutureOr<String> Function(String input);

class AgentStep {
  final String thought;
  final String? tool;
  final String? observation;
  const AgentStep({required this.thought, this.tool, this.observation});
}

class AgentResult {
  final bool done;
  final List<AgentStep> steps;
  final String answer;
  final String? error;
  const AgentResult(
      {required this.done,
      required this.steps,
      required this.answer,
      this.error});
}

typedef ThinkFn = ({
  String? tool,
  String input,
  bool done,
  String thought,
}) Function(String task, List<String> observations, List<String> tools);

/// Default think: call a tool whose name appears in the task, then
/// answer from the observation. No model needed. Once a tool has
/// answered, the loop is done — it never calls the same tool twice
/// for one task.
({String? tool, String input, bool done, String thought}) coreThink(
    String task, List<String> observations, List<String> tools) {
  if (observations.isNotEmpty) {
    return (
      tool: null,
      input: '',
      done: true,
      thought: observations.last,
    );
  }
  final low = task.toLowerCase();
  for (final name in tools) {
    if (low.contains(name.toLowerCase())) {
      return (
        tool: name,
        input: task,
        done: false,
        thought: 'the task names the $name tool',
      );
    }
  }
  return (
    tool: null,
    input: '',
    done: true,
    thought: 'no tool matches; answering from what I know',
  );
}

/// Think, call a tool, observe, repeat — bounded, never infinite.
class AgentLoop {
  final int maxSteps;
  const AgentLoop({this.maxSteps = 8});

  Future<AgentResult> run(String task, Map<String, ToolFn> tools,
      [ThinkFn think = coreThink]) async {
    final steps = <AgentStep>[];
    final observations = <String>[];
    final names = tools.keys.toList();
    for (var i = 0; i < maxSteps; i++) {
      final next = think(task, observations, names);
      if (next.done || next.tool == null) {
        steps.add(AgentStep(thought: next.thought));
        return AgentResult(done: true, steps: steps, answer: next.thought);
      }
      final fn = tools[next.tool];
      if (fn == null) {
        steps.add(AgentStep(
            thought: next.thought, tool: next.tool, observation: 'tool not found'));
        return AgentResult(
            done: false,
            steps: steps,
            answer: '',
            error: 'tool not found: ${next.tool}');
      }
      String observation;
      try {
        observation = await fn(next.input);
      } catch (err) {
        observation = 'tool failed: $err';
      }
      steps.add(AgentStep(
          thought: next.thought, tool: next.tool, observation: observation));
      observations.add(observation);
    }
    return AgentResult(
        done: false,
        steps: steps,
        answer: '',
        error: 'stopped after $maxSteps steps — task not finished');
  }
}

/// Memory as plain Markdown files, in DJ's data folder.
class MemoryFiles {
  final String dataDir;
  MemoryFiles(this.dataDir);

  String memoryPath() =>
      '$dataDir${Platform.pathSeparator}MEMORY.md';

  String dailyPath([DateTime? date]) {
    final day = (date ?? DateTime.now()).toIso8601String().substring(0, 10);
    return '$dataDir${Platform.pathSeparator}memory${Platform.pathSeparator}$day.md';
  }

  String readMemory() {
    try {
      return File(memoryPath()).readAsStringSync();
    } catch (_) {
      return '';
    }
  }

  /// Append one long-term fact to MEMORY.md.
  void saveFact(String text, [DateTime? now]) {
    final day = (now ?? DateTime.now()).toIso8601String().substring(0, 10);
    final line = '- $day ${text.trim()}\n';
    Directory(File(memoryPath()).parent.path).createSync(recursive: true);
    File(memoryPath()).writeAsStringSync(line, mode: FileMode.append);
  }

  /// Append one line to today's daily note.
  void appendDaily(String text, [DateTime? now]) {
    final at = now ?? DateTime.now();
    final p = dailyPath(at);
    final time = at.toIso8601String().substring(11, 19);
    Directory(File(p).parent.path).createSync(recursive: true);
    File(p).writeAsStringSync('- $time ${text.trim()}\n', mode: FileMode.append);
  }

  /// Read MEMORY.md plus the newest 14 daily notes, newest first.
  /// Read-only for the Memory page.
  ({String memoryMd, List<({String date, String text})> daily}) readContent() {
    final memoryMd = readMemory();
    final daily = <({String date, String text})>[];
    final dir = Directory(
        '$dataDir${Platform.pathSeparator}memory');
    List<String> names = [];
    try {
      names = dir
          .listSync()
          .whereType<File>()
          .map((f) => f.path.split(Platform.pathSeparator).last)
          .where((f) => RegExp(r'^\d{4}-\d{2}-\d{2}\.md$').hasMatch(f))
          .toList()
        ..sort((a, b) => b.compareTo(a));
      names = names.take(14).toList();
    } catch (_) {
      names = [];
    }
    for (final name in names) {
      try {
        daily.add((
          date: name.substring(0, 10),
          text: File('${dir.path}${Platform.pathSeparator}$name')
              .readAsStringSync(),
        ));
      } catch (_) {}
    }
    return (memoryMd: memoryMd, daily: daily);
  }
}

class SkillPlaybook {
  final String id;
  final String title;
  final String body;
  final String path;
  const SkillPlaybook(
      {required this.id,
      required this.title,
      required this.body,
      required this.path});
}

/// Load *.md playbooks from a skills folder. Missing folder = no
/// skills, not an error.
List<SkillPlaybook> loadSkillPlaybooks(String dir) {
  List<FileSystemEntity> entries;
  try {
    entries = Directory(dir).listSync();
  } catch (_) {
    return [];
  }
  final files = entries
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.md'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final out = <SkillPlaybook>[];
  for (final file in files) {
    final p = file.path;
    try {
      final body = file.readAsStringSync();
      final first = body
              .split('\n')
              .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '') ;
      final fileName = p.split(Platform.pathSeparator).last;
      final title = first.replaceFirst(RegExp(r'^#+\s*'), '').trim().isEmpty
          ? fileName
          : first.replaceFirst(RegExp(r'^#+\s*'), '').trim();
      final id = fileName.replaceFirst(RegExp(r'\.md$', caseSensitive: false), '');
      out.add(SkillPlaybook(id: id, title: title, body: body, path: p));
    } catch (_) {
      // Unreadable playbook: skip it, keep the rest.
    }
  }
  return out;
}

/// A scheduled check that runs on a timer. The work itself is
/// injected, so tests can tick it without waiting.
class Heartbeat {
  final int intervalMs;
  final FutureOr<void> Function() work;
  Timer? _timer;

  Heartbeat({required this.intervalMs, required this.work});

  /// Default 30-minute heartbeat.
  factory Heartbeat.thirtyMinutes(FutureOr<void> Function() work) =>
      Heartbeat(intervalMs: 30 * 60 * 1000, work: work);

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      final result = work();
      if (result is Future<void>) unawaited(result);
    });
  }

  /// Run the work once now (used by tests, and by main on start).
  Future<void> tick() async => await work();

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  bool get running => _timer != null;
}

void unawaited(Future<void> f) {}
