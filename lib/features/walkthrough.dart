// Walkthrough engine — DJ shows the user how to do something, one
// step at a time, pointing at each thing on the screen.
//
// A Walkthrough is a list of steps. The engine shows one step at a
// time: it moves the fake cursor to the step's point, draws the step's
// annotation, shows the instruction, and waits for the user to press
// Next (or auto-advances when the step's action completes). It tracks
// progress ("Step 2 of 5") and stays with the user until done or the
// user cancels.
//
// Steps can come from the model or be built by the user. The engine
// never clicks or types by itself: a step's action only runs when the
// app wires in an [actionRunner] (the UI agent owns that wiring, and
// the agent-mode safety rules apply there). With no actionRunner, every
// step waits for Next — the user does the clicking, DJ just points.

import 'dart:async';

import '../platform/cursor_channel.dart';
import 'annotations.dart';
import 'screen_qa.dart';

/// One step of a walkthrough.
class WalkthroughStep {
  const WalkthroughStep({
    required this.title,
    required this.instruction,
    this.point,
    this.annotation,
    this.action,
    this.actionInput = '',
  });

  final String title;

  /// Plain words, one thing only. 10th-class level.
  final String instruction;

  /// Where to point, if this step points at something.
  final ScreenPoint? point;

  /// Annotation to draw for this step (circle / arrow / highlight).
  final Annotation? annotation;

  /// Optional action: 'click', 'type', 'wait', 'pressKey'.
  /// Runs only when the engine was given an actionRunner.
  final String? action;

  /// Text for a 'type' step, key name for 'pressKey', seconds for 'wait'.
  final String actionInput;

  Map<String, dynamic> toJson() => {
        'title': title,
        'instruction': instruction,
        if (point != null)
          'point': {'x': point!.x, 'y': point!.y, 'label': point!.label},
        if (action != null) 'action': action,
        if (actionInput.isNotEmpty) 'actionInput': actionInput,
      };

  factory WalkthroughStep.fromJson(Map<String, dynamic> j) {
    final p = j['point'];
    return WalkthroughStep(
      title: (j['title'] ?? '') as String,
      instruction: (j['instruction'] ?? '') as String,
      point: p is Map
          ? ScreenPoint(
              x: (p['x'] as num? ?? 0).toInt(),
              y: (p['y'] as num? ?? 0).toInt(),
              label: (p['label'] ?? '') as String,
            )
          : null,
      action: j['action'] as String?,
      actionInput: (j['actionInput'] ?? '') as String,
    );
  }
}

/// A whole walkthrough: a title and its steps in order.
class Walkthrough {
  const Walkthrough({required this.title, required this.steps});
  final String title;
  final List<WalkthroughStep> steps;

  Map<String, dynamic> toJson() => {
        'title': title,
        'steps': steps.map((s) => s.toJson()).toList(),
      };

  factory Walkthrough.fromJson(Map<String, dynamic> j) => Walkthrough(
        title: (j['title'] ?? '') as String,
        steps: ((j['steps'] as List?) ?? [])
            .whereType<Map<String, dynamic>>()
            .map(WalkthroughStep.fromJson)
            .toList(),
      );

  /// Built-in example: open Chrome and search for something.
  static Walkthrough exampleChromeSearch() => const Walkthrough(
        title: 'Open Chrome and search for something',
        steps: [
          WalkthroughStep(
            title: 'Open Chrome',
            instruction:
                'Click the Chrome icon. It is the round red, yellow, green and blue circle.',
            action: 'click',
            actionInput: 'chrome',
          ),
          WalkthroughStep(
            title: 'Click the address bar',
            instruction:
                'Click the long white bar at the top of the Chrome window. That is where you type a web address.',
            action: 'click',
          ),
          WalkthroughStep(
            title: 'Type what you want to find',
            instruction:
                'Type your search words, for example "Andhra University exam dates".',
            action: 'type',
            actionInput: 'Andhra University exam dates',
          ),
          WalkthroughStep(
            title: 'Press Enter',
            instruction:
                'Press the Enter key. Chrome shows the search results.',
            action: 'pressKey',
            actionInput: 'Enter',
          ),
          WalkthroughStep(
            title: 'Done',
            instruction:
                'Pick a result from the list to open it. Press Next to finish, or Cancel to stop here.',
          ),
        ],
      );
}

enum WalkthroughStatus { idle, running, done, cancelled }

/// The engine's state, emitted on [WalkthroughEngine.updates].
class WalkthroughState {
  const WalkthroughState({
    required this.walkthrough,
    required this.index,
    required this.status,
  });
  final Walkthrough walkthrough;
  final int index;
  final WalkthroughStatus status;

  WalkthroughStep? get currentStep =>
      walkthrough.steps.isEmpty || index >= walkthrough.steps.length
          ? null
          : walkthrough.steps[index];

  String get progressLabel =>
      'Step ${index + 1} of ${walkthrough.steps.length}';
}

/// Runs one [WalkthroughStep]'s action. Returns true when the action
/// completed, so the engine can auto-advance. The app wires this in;
/// without it, steps never auto-advance and wait for Next.
typedef WalkthroughActionRunner = Future<bool> Function(
  WalkthroughStep step,
);

class WalkthroughEngine {
  WalkthroughEngine({
    required CursorChannel cursor,
    AnnotationController? annotations,
    this.actionRunner,
  })  : _cursor = cursor,
        _annotations = annotations;

  final CursorChannel _cursor;
  final AnnotationController? _annotations;
  final WalkthroughActionRunner? actionRunner;

  final _updates = StreamController<WalkthroughState>.broadcast();

  /// Every state change (step shown, done, cancelled). The UI listens.
  Stream<WalkthroughState> get updates => _updates.stream;

  Walkthrough? _walkthrough;
  int _index = 0;
  WalkthroughStatus _status = WalkthroughStatus.idle;

  Walkthrough? get walkthrough => _walkthrough;
  int get index => _index;
  WalkthroughStatus get status => _status;
  bool get isRunning => _status == WalkthroughStatus.running;

  WalkthroughStep? get currentStep {
    final w = _walkthrough;
    if (w == null || _index >= w.steps.length) return null;
    return w.steps[_index];
  }

  String get progressLabel {
    final w = _walkthrough;
    if (w == null) return '';
    return 'Step ${_index + 1} of ${w.steps.length}';
  }

  /// Start a walkthrough from step 0. Shows the first step.
  Future<void> start(Walkthrough walkthrough) async {
    _walkthrough = walkthrough;
    _index = 0;
    _status = WalkthroughStatus.running;
    await _showCurrent();
  }

  /// Go to the next step. On the last step, finishes the walkthrough.
  Future<void> next() async {
    if (_status != WalkthroughStatus.running) return;
    final w = _walkthrough;
    if (w == null) return;
    if (_index >= w.steps.length - 1) {
      await finish();
      return;
    }
    _index++;
    await _showCurrent();
  }

  /// Go back one step. Does nothing on the first step.
  Future<void> previous() async {
    if (_status != WalkthroughStatus.running || _index == 0) return;
    _index--;
    await _showCurrent();
  }

  /// Run the current step's action (if any) and auto-advance when it
  /// completes. With no actionRunner, or no action on the step, this
  /// just waits — the user presses Next instead.
  Future<void> runCurrentAction() async {
    final step = currentStep;
    final runner = actionRunner;
    if (_status != WalkthroughStatus.running || step == null) return;
    if (step.action == null || runner == null) return;
    final done = await runner(step);
    if (done && _status == WalkthroughStatus.running) {
      await next();
    }
  }

  /// Stop the walkthrough. Hides the cursor and clears annotations.
  Future<void> cancel() async {
    if (_status != WalkthroughStatus.running) return;
    _status = WalkthroughStatus.cancelled;
    await _cleanup();
    _emit();
  }

  /// Finish the walkthrough (last step's Next). Same cleanup as cancel.
  Future<void> finish() async {
    if (_status != WalkthroughStatus.running) return;
    _status = WalkthroughStatus.done;
    await _cleanup();
    _emit();
  }

  Future<void> _showCurrent() async {
    final step = currentStep;
    if (step == null) {
      await finish();
      return;
    }
    if (step.point != null) {
      await _cursor.showCursor(
        step.point!.x,
        step.point!.y,
        step.point!.label,
      );
    }
    if (step.annotation != null && _annotations != null) {
      final annotations = _annotations;
      await annotations.clearAll();
      annotations.add(step.annotation!);
      await annotations.show();
    }
    _emit();
  }

  Future<void> _cleanup() async {
    await _cursor.hideCursor();
    final annotations = _annotations;
    if (annotations != null) await annotations.clearAll();
  }

  void _emit() {
    final w = _walkthrough;
    if (w == null) return;
    _updates.add(
      WalkthroughState(walkthrough: w, index: _index, status: _status),
    );
  }

  void dispose() => _updates.close();
}
