// Agent mode — "DJ agent <task>": DJ does the task itself
// (research, write, build), not just talk about it.
//
// Planning: via the model when one is up ([planner] — the app wires
// in a model planner), otherwise via Core rules — keyword routing to
// tools ([planWithCoreRules], built on BrainService).
//
// Running: the bounded [AgentLoop] from lib/core/agent_loop.dart with
// a 15-step cap and the REAL tools (captureScreen, point, click, type,
// openApp, openFile, search). The tools are injected as a map so tests
// can run the whole mode with fakes and no channels.
//
// SAFETY RULES (hard):
// * Max 15 steps per task. The loop stops there, unfinished or not.
// * Stuck detection: the same action 3 times in a row, or no screen
//   change for 3 steps, = stop and ask the user.
// * Show before click: the fake cursor is shown where DJ is about to
//   click FIRST, then DJ waits a beat ([showBeforeClickDelay]) before
//   the real click.
// * NEVER type passwords: refused when the focused field is a password
//   field ([passwordFieldFocused]) or the text to type contains a
//   password. The refusal stops the task and says so plainly.
// * Judge before any destructive action: [judgeAction] from
//   lib/core/judge.dart runs on every planned step (and on the task
//   itself); a blocked judgement stops the task before anything runs.
// * Progress is reported step by step via [onProgress] and [updates].
//
// NOTE: AgentLoop in Core caps at 8 by default; agent mode passes
// maxSteps 15 explicitly, as the brief requires. Core's loop has no
// safety hooks of its own — the hooks here wrap the tools and the
// think function, so the loop itself stays untouched.

import 'dart:async';

import '../core/agent_loop.dart';
import '../core/brain.dart';
import '../core/judge.dart';

/// One tool call, as a plain function: input in, observation out.
/// Tool inputs are short strings; the 'point' and 'click' tools take
/// "x,y" or "x,y:label" in virtual-screen pixels.
typedef AgentToolFn = Future<String> Function(String input);

/// One planned step: which tool, with what input, and why.
class AgentPlanStep {
  const AgentPlanStep({
    required this.tool,
    required this.input,
    required this.description,
  });
  final String tool;
  final String input;
  final String description;

  Map<String, dynamic> toJson() => {
        'tool': tool,
        'input': input,
        'description': description,
      };
}

/// A model planner: task in, plan out. Null / unset = Core rules.
typedef AgentPlanner = Future<List<AgentPlanStep>> Function(String task);

/// Progress of one agent run, for the UI.
class AgentProgress {
  const AgentProgress({
    required this.stepIndex,
    required this.totalSteps,
    required this.description,
    required this.status,
  });
  final int stepIndex;
  final int totalSteps;
  final String description;

  /// 'running' | 'done' | 'stopped' | 'failed'.
  final String status;
}

/// The outcome of one agent task.
class AgentTaskResult {
  const AgentTaskResult({
    required this.done,
    required this.stepsTaken,
    required this.answer,
    this.stoppedReason,
    this.error,
  });
  final bool done;
  final int stepsTaken;
  final String answer;
  final String? stoppedReason;
  final String? error;
}

class AgentMode {
  AgentMode({
    required Map<String, AgentToolFn> tools,
    this.planner,
    this.maxSteps = 15,
    this.showBeforeClickDelay = const Duration(milliseconds: 600),
    this.passwordFieldFocused,
    this.onProgress,
  }) : _rawTools = Map.of(tools);

  final Map<String, AgentToolFn> _rawTools;

  /// Model planner when a model is up; Core rules otherwise.
  final AgentPlanner? planner;

  /// Hard cap on steps per task. Default 15, per the brief.
  final int maxSteps;

  /// The beat DJ waits after showing the fake cursor, before clicking.
  final Duration showBeforeClickDelay;

  /// True when the focused field is a password field. When true, any
  /// 'type' step is refused. The UI sets this from the focused control.
  final bool Function()? passwordFieldFocused;

  final void Function(AgentProgress)? onProgress;

  final _updates = StreamController<AgentProgress>.broadcast();

  /// Step-by-step progress. The UI listens.
  Stream<AgentProgress> get updates => _updates.stream;

  /// Core-rules plan: keyword routing to tools, no model needed.
  /// Uses BrainService (the same rules as chat) to pick the tool.
  static List<AgentPlanStep> planWithCoreRules(String task) {
    final action = BrainService().decide(task);
    switch (action.action) {
      case 'openApp':
        return [
          AgentPlanStep(
            tool: 'openApp',
            input: action.query,
            description: 'Open ${action.query}',
          ),
        ];
      case 'open':
        return [
          AgentPlanStep(
            tool: 'search',
            input: action.query,
            description: "Find '${action.query}'",
          ),
          AgentPlanStep(
            tool: 'openFile',
            input: action.query,
            description: "Open '${action.query}'",
          ),
        ];
      case 'openFolder':
        return [
          AgentPlanStep(
            tool: 'openFile',
            input: action.query,
            description: "Open the '${action.query}' folder",
          ),
        ];
      case 'summarize':
        return [
          AgentPlanStep(
            tool: 'search',
            input: action.query,
            description: "Find '${action.query}' to summarise",
          ),
        ];
      case 'help':
        return const [];
      default:
        return [
          AgentPlanStep(
            tool: 'search',
            input: action.query.isEmpty ? task : action.query,
            description: "Search for '${action.query.isEmpty ? task : action.query}'",
          ),
        ];
    }
  }

  /// True when [text] looks like it contains a password. DJ never
  /// types passwords: the word 'password' (or 'passwd') in the text
  /// to type is a refusal, as is a focused password field.
  static bool looksLikePassword(String text) {
    final low = text.toLowerCase();
    return low.contains('password') || low.contains('passwd');
  }

  /// Run one task. Returns when the plan finishes, a safety rule
  /// stops the run, or the 15-step cap is hit.
  Future<AgentTaskResult> run(
    String task, {
    List<AgentPlanStep>? planOverride,
  }) async {
    // Judge the task itself first: an empty task is blocked outright.
    final taskJudge = judgeAction(
      JudgeInput(kind: 'reply', text: task, destructive: false),
    );
    if (taskJudge.blocked.isNotEmpty) {
      return AgentTaskResult(
        done: false,
        stepsTaken: 0,
        answer: '',
        stoppedReason: 'Blocked by judge: ${taskJudge.blocked.join(', ')}',
      );
    }

    final plan = planOverride ??
        (planner != null ? await planner!(task) : planWithCoreRules(task));
    if (plan.isEmpty) {
      return const AgentTaskResult(
        done: true,
        stepsTaken: 0,
        answer: 'Nothing to do — that is not a task I can run. '
            'Try "DJ agent open Chrome" or "DJ agent find my notes".',
      );
    }

    String? stopReason;
    final actionHistory = <String>[];
    String? lastFingerprint;
    var unchangedCount = 0;

    bool isDestructive(String tool, String input) {
      final low = input.toLowerCase();
      return (tool == 'click' || tool == 'type') &&
          (low.contains('delete') ||
              low.contains('remove') ||
              low.contains('trash'));
    }

    // --- Safety wrappers around the real tools. ---
    Map<String, AgentToolFn> wrappedTools() {
      final wrapped = <String, AgentToolFn>{};
      for (final entry in _rawTools.entries) {
        final tool = entry.key;
        final raw = entry.value;
        wrapped[tool] = (String input) async {
          if (stopReason != null) return 'STOP: $stopReason';

          // Stuck detection 1: same action 3 times in a row.
          final signature = '$tool::$input';
          actionHistory.add(signature);
          if (actionHistory.length >= 3 &&
              actionHistory[actionHistory.length - 1] == signature &&
              actionHistory[actionHistory.length - 2] == signature &&
              actionHistory[actionHistory.length - 3] == signature) {
            stopReason = 'stuck: the same action 3 times in a row '
                '($tool "$input") — stopping to ask you';
            return 'STOP: $stopReason';
          }

          // Password refusal: never type into a password field, and
          // never type text that contains a password.
          if (tool == 'type' &&
              ((passwordFieldFocused?.call() ?? false) ||
                  looksLikePassword(input))) {
            stopReason = 'refused: I never type passwords';
            return 'STOP: $stopReason';
          }

          // Show before click: fake cursor first, wait a beat, then click.
          if (tool == 'click') {
            final point = _rawTools['point'];
            final coords = _parseCoords(input);
            if (point != null && coords != null) {
              await point(input);
            }
            if (showBeforeClickDelay > Duration.zero) {
              await Future<void>.delayed(showBeforeClickDelay);
            }
          }

          final observation = await raw(input);

          // Stuck detection 2: no screen change for 3 steps.
          final capture = _rawTools['captureScreen'];
          if (capture != null && tool != 'captureScreen') {
            final fingerprint = await capture('');
            if (lastFingerprint != null &&
                fingerprint == lastFingerprint) {
              unchangedCount++;
              if (unchangedCount >= 3) {
                stopReason = 'stuck: the screen has not changed for '
                    '3 steps — stopping to ask you';
                return '$observation\nSTOP: $stopReason';
              }
            } else {
              unchangedCount = 0;
            }
            lastFingerprint = fingerprint;
          }
          return observation;
        };
      }
      return wrapped;
    }

    final loop = AgentLoop(maxSteps: maxSteps);
    final tools = wrappedTools();

    AgentProgress progress(int step, String description, String status) =>
        AgentProgress(
          stepIndex: step,
          totalSteps: plan.length,
          description: description,
          status: status,
        );

    // Think function: walk the plan in order; stop on a safety flag,
    // a blocked judgement, or the end of the plan.
    ({String? tool, String input, bool done, String thought}) think(
      String t,
      List<String> observations,
      List<String> names,
    ) {
      if (stopReason != null) {
        return (
          tool: null,
          input: '',
          done: true,
          thought: stopReason!,
        );
      }
      if (observations.isNotEmpty &&
          observations.last.contains('STOP:')) {
        final marker = observations.last;
        stopReason = marker
            .substring(marker.indexOf('STOP:') + 5)
            .trim()
            .split('\n')
            .first;
        return (tool: null, input: '', done: true, thought: stopReason!);
      }
      final doneCount = observations.length;
      if (doneCount >= plan.length) {
        return (
          tool: null,
          input: '',
          done: true,
          thought: 'Task finished.',
        );
      }
      final step = plan[doneCount];
      // Judge before any destructive action.
      final judged = judgeAction(
        JudgeInput(
          kind: step.tool,
          text: step.description,
          destructive: isDestructive(step.tool, step.input),
          targetCount: 1,
          goal: t,
        ),
      );
      if (judged.blocked.isNotEmpty) {
        stopReason =
            'Blocked by judge: ${judged.blocked.join(', ')}';
        return (tool: null, input: '', done: true, thought: stopReason!);
      }
      if (!names.contains(step.tool)) {
        stopReason = 'tool not available: ${step.tool}';
        return (tool: null, input: '', done: true, thought: stopReason!);
      }
      final p = progress(doneCount + 1, step.description, 'running');
      onProgress?.call(p);
      _updates.add(p);
      return (
        tool: step.tool,
        input: step.input,
        done: false,
        thought: step.description,
      );
    }

    final result = await loop.run(task, tools, think);
    final stepsTaken = result.steps.length;
    if (stopReason != null) {
      final p = progress(stepsTaken, stopReason!, 'stopped');
      onProgress?.call(p);
      _updates.add(p);
      return AgentTaskResult(
        done: false,
        stepsTaken: stepsTaken,
        answer: result.answer,
        stoppedReason: stopReason,
      );
    }
    if (!result.done) {
      final reason = result.error ?? 'stopped after $maxSteps steps';
      final p = progress(stepsTaken, reason, 'stopped');
      onProgress?.call(p);
      _updates.add(p);
      return AgentTaskResult(
        done: false,
        stepsTaken: stepsTaken,
        answer: result.answer,
        stoppedReason: reason,
        error: result.error,
      );
    }
    final p = progress(stepsTaken, 'Task finished.', 'done');
    onProgress?.call(p);
    _updates.add(p);
    // The answer is the last thing a tool observed — not the loop's
    // own "Task finished." thought.
    String lastObservation() {
      for (var i = result.steps.length - 1; i >= 0; i--) {
        final observation = result.steps[i].observation;
        if (observation != null &&
            observation.isNotEmpty &&
            !observation.contains('STOP:')) {
          return observation;
        }
      }
      return result.answer.isEmpty ? 'Done.' : result.answer;
    }

    return AgentTaskResult(
      done: true,
      stepsTaken: stepsTaken,
      answer: lastObservation(),
    );
  }

  /// "x,y" or "x,y:label" -> (x, y). Null when the input has no coords.
  static (int, int)? _parseCoords(String input) {
    final m = RegExp(r'^\s*(\d+)\s*,\s*(\d+)').firstMatch(input);
    if (m == null) return null;
    return (int.parse(m.group(1)!), int.parse(m.group(2)!));
  }

  void dispose() => _updates.close();
}
