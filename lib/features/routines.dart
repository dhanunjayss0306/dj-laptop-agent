// Routines — named lists of steps DJ runs in order, e.g. a morning
// routine. Saved as plain JSON in dj_data/routines.json (local only).
//
// A Routine is {name, steps}; each step is one of:
//   openApp     — open an installed app by name (target = app name)
//   openFile    — open a file (target = file path)
//   openFolder  — open a folder in Explorer (target = folder path)
//   agentTask   — run an agent-mode task (target = the task text)
//   waitSeconds — wait (target = seconds, e.g. "5")
//   showMessage — show a message to the user (target = the message)
//
// DJ never closes apps by itself: there is deliberately no closeApp
// step kind. The 'wind down' routine only shows a summary.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../services/app_launcher.dart';
import '../services/system_ops.dart';
import 'agent_mode.dart';

/// One step of a routine.
class RoutineStep {
  const RoutineStep({
    required this.kind,
    required this.target,
  });

  /// 'openApp' | 'openFile' | 'openFolder' | 'agentTask' |
  /// 'waitSeconds' | 'showMessage'.
  final String kind;
  final String target;

  Map<String, dynamic> toJson() => {'kind': kind, 'target': target};

  factory RoutineStep.fromJson(Map<String, dynamic> j) => RoutineStep(
        kind: (j['kind'] ?? '') as String,
        target: (j['target'] ?? '') as String,
      );
}

/// A named routine: a name and its steps, in order.
class Routine {
  const Routine({required this.name, required this.steps});
  final String name;
  final List<RoutineStep> steps;

  Map<String, dynamic> toJson() => {
        'name': name,
        'steps': steps.map((s) => s.toJson()).toList(),
      };

  factory Routine.fromJson(Map<String, dynamic> j) => Routine(
        name: (j['name'] ?? '') as String,
        steps: ((j['steps'] as List?) ?? [])
            .whereType<Map<String, dynamic>>()
            .map(RoutineStep.fromJson)
            .toList(),
      );
}

/// What one routine run did, step by step.
class RoutineRunResult {
  const RoutineRunResult({
    required this.routineName,
    required this.lines,
    required this.errors,
  });
  final String routineName;
  final List<String> lines;
  final List<String> errors;
  bool get ok => errors.isEmpty;
}

/// Built-in routines. 'morning routine' opens Chrome and VS Code and
/// shows today's newest files. 'wind down' only shows a summary of
/// today's files — it closes nothing.
List<Routine> builtInRoutines() => const [
      Routine(
        name: 'morning routine',
        steps: [
          RoutineStep(kind: 'openApp', target: 'chrome'),
          RoutineStep(kind: 'openApp', target: 'vs code'),
          RoutineStep(kind: 'showMessage', target: 'Here are your newest files:'),
          RoutineStep(kind: 'agentTask', target: 'list recent files'),
        ],
      ),
      Routine(
        name: 'wind down',
        steps: [
          RoutineStep(
            kind: 'showMessage',
            target: 'Winding down — here is a summary of today\'s files:',
          ),
          RoutineStep(kind: 'agentTask', target: 'list recent files'),
        ],
      ),
    ];

/// Stores routines in dj_data/routines.json and runs them in order.
/// The app wires in [systemOps] / [appLauncher] for real opens and
/// [runAgentTask] for agentTask steps; without them those steps report
/// plainly that they are not wired, instead of failing silently.
///
/// [newestFiles] supplies today's newest files for the built-ins
/// (the app passes IndexService.listRecent). Without it the step
/// reports that the index is not available.
class RoutineStore {
  RoutineStore({
    required this.dataDir,
    this.systemOps,
    this.appLauncher,
    this.runAgentTask,
    this.newestFiles,
    this.onStep,
  });

  final String dataDir;
  final SystemOps? systemOps;
  final AppLauncher? appLauncher;
  final Future<AgentTaskResult> Function(String task)? runAgentTask;
  final Future<List<String>> Function()? newestFiles;

  /// Called after each step with a plain line ("Opened Chrome.").
  final void Function(String)? onStep;

  String get routinesPath =>
      '$dataDir${Platform.pathSeparator}routines.json';

  /// All saved routines, built-ins first when the file is missing.
  List<Routine> listRoutines() {
    final file = File(routinesPath);
    if (!file.existsSync()) return builtInRoutines();
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is List) {
        return decoded
            .whereType<Map<String, dynamic>>()
            .map(Routine.fromJson)
            .toList();
      }
    } catch (_) {
      // Corrupt file: fall back to built-ins, never crash.
    }
    return builtInRoutines();
  }

  /// Write the built-ins to disk when no routines file exists yet.
  void saveBuiltInsIfMissing() {
    if (!File(routinesPath).existsSync()) {
      saveAll(builtInRoutines());
    }
  }

  /// Save (add or replace by name) one routine.
  void saveRoutine(Routine routine) {
    final all = listRoutines()
        .where((r) => r.name.toLowerCase() != routine.name.toLowerCase())
        .toList()
      ..add(routine);
    saveAll(all);
  }

  void saveAll(List<Routine> routines) {
    Directory(dataDir).createSync(recursive: true);
    File(routinesPath).writeAsStringSync(
      const JsonEncoder.withIndent('  ')
          .convert(routines.map((r) => r.toJson()).toList()),
      encoding: utf8,
    );
  }

  /// Delete a routine by name. Returns true when one was removed.
  bool deleteRoutine(String name) {
    final all = listRoutines();
    final kept = all
        .where((r) => r.name.toLowerCase() != name.toLowerCase())
        .toList();
    if (kept.length == all.length) return false;
    saveAll(kept);
    return true;
  }

  Routine? getRoutine(String name) {
    for (final r in listRoutines()) {
      if (r.name.toLowerCase() == name.toLowerCase()) return r;
    }
    return null;
  }

  /// Run a routine by name, step by step, in order. Reports each step
  /// through [onStep] and in the returned lines. A failed step is
  /// recorded and the run continues with the next step.
  Future<RoutineRunResult> runRoutine(String name) async {
    final routine = getRoutine(name);
    if (routine == null) {
      return RoutineRunResult(
        routineName: name,
        lines: const [],
        errors: ['No routine called "$name".'],
      );
    }
    final lines = <String>[];
    final errors = <String>[];
    for (final step in routine.steps) {
      final line = await _runStep(step);
      lines.add(line);
      onStep?.call(line);
      if (line.contains('Could not') || line.contains('Failed')) {
        errors.add(line);
      }
    }
    return RoutineRunResult(
      routineName: routine.name,
      lines: lines,
      errors: errors,
    );
  }

  Future<String> _runStep(RoutineStep step) async {
    switch (step.kind) {
      case 'openApp':
        final launcher = appLauncher;
        if (launcher == null) {
          return 'Could not open ${step.target}: app launcher is not wired in.';
        }
        final result = await launcher.openApp(step.target);
        return result.message;
      case 'openFile':
        final ops = systemOps;
        if (ops == null) {
          return 'Could not open ${step.target}: system ops is not wired in.';
        }
        final result = await ops.openFile(step.target);
        return result.ok ? 'Opened ${step.target}.' : result.message;
      case 'openFolder':
        final ops = systemOps;
        if (ops == null) {
          return 'Could not open ${step.target}: system ops is not wired in.';
        }
        final result = await ops.openFolder(step.target);
        return result.ok ? 'Opened the folder ${step.target}.' : result.message;
      case 'agentTask':
        final runner = runAgentTask;
        if (runner == null) {
          return 'Could not run "${step.target}": agent mode is not wired in.';
        }
        final result = await runner(step.target);
        if (result.done) return result.answer;
        return result.stoppedReason ?? 'Agent task did not finish.';
      case 'waitSeconds':
        final seconds = int.tryParse(step.target) ?? 0;
        if (seconds > 0) {
          await Future<void>.delayed(Duration(seconds: seconds));
        }
        return 'Waited $seconds second${seconds == 1 ? '' : 's'}.';
      case 'showMessage':
        if (step.target.toLowerCase().contains('newest files') ||
            step.target.toLowerCase().contains("today's files")) {
          final files = newestFiles != null ? await newestFiles!() : null;
          if (files == null || files.isEmpty) {
            return '${step.target} (no newest files — the index is not built yet.)';
          }
          return '${step.target}\n${files.take(10).map((f) => '• $f').join('\n')}';
        }
        return step.target;
      default:
        return 'Could not run step "${step.kind}": unknown step kind.';
    }
  }
}
