// Tutoring mode — DJ teaches a tool step by step, like a teacher.
//
// Given a screen + a tool/app name, the tutor explains that tool one
// UI element at a time, in plain words (10th-class level), pointing at
// each element with the fake cursor and an annotation.
//
// How it works: [Tutor] uses ScreenQA (capture on demand — never
// continuous) plus the Walkthrough engine. Each lesson step explains
// ONE UI element and points at it.
//
// HONEST LIMIT: without a vision model running, DJ cannot see the
// screen, so it cannot discover where the buttons are. In that case
// [explainFromScreen] says so plainly and builds a lesson only from
// elements the user (or the app) supplies with known positions
// ([lessonForTool]). The tutor never invents button positions.
//
// Mode flag: the UI turns tutoring on/off with [enabled]. When off,
// [explainFromScreen] refuses with a plain message.

import 'dart:async';

import 'screen_qa.dart';
import 'walkthrough.dart';

/// One UI element the tutor will explain. The point must be a real,
/// known position — never guessed.
class TutorElement {
  const TutorElement({
    required this.name,
    required this.description,
    this.point,
  });
  final String name;

  /// Plain words, one idea only. 10th-class level.
  final String description;
  final ScreenPoint? point;
}

/// What the tutor produced for one ask.
class TutorExplanation {
  const TutorExplanation({required this.text, required this.lesson});
  final String text;

  /// Null when no lesson could be built (tutor off, or no model and
  /// no known element positions).
  final Walkthrough? lesson;
}

class Tutor {
  Tutor({
    required ScreenQA screenQA,
    required WalkthroughEngine walkthrough,
    this.enabled = false,
  })  : _screenQA = screenQA,
        _walkthrough = walkthrough;

  final ScreenQA _screenQA;
  final WalkthroughEngine _walkthrough;

  /// Mode flag the UI turns on/off.
  bool enabled;

  void toggle() => enabled = !enabled;

  /// Build a lesson from elements with known positions. One step per
  /// element, plus a short intro step. Simple language throughout.
  Walkthrough lessonForTool(String appName, List<TutorElement> elements) {
    final steps = <WalkthroughStep>[
      WalkthroughStep(
        title: 'Let us learn $appName',
        instruction:
            'We will go slowly, one button at a time. Press Next when you are ready for the next one.',
      ),
      ...elements.map(
        (e) => WalkthroughStep(
          title: e.name,
          instruction: e.description,
          point: e.point,
        ),
      ),
      const WalkthroughStep(
        title: 'That is it for now',
        instruction:
            'Try it yourself now. If you get stuck, ask me again and we will go through it once more.',
      ),
    ];
    return Walkthrough(title: 'Learn $appName', steps: steps);
  }

  /// Start a lesson built by [lessonForTool] on the walkthrough engine.
  Future<void> startLesson(Walkthrough lesson) =>
      _walkthrough.start(lesson);

  /// Explain a tool from the live screen. Captures the screen once
  /// (on demand), asks the model to name the UI elements one by one,
  /// and turns the answer into a walkthrough.
  ///
  /// The model is asked to answer as short numbered lines, each ending
  /// with a [POINT:x,y:label] tag. Lines without a point become
  /// point-free steps (the words are still shown).
  Future<TutorExplanation> explainFromScreen(
    String appName,
    String question,
  ) async {
    if (!enabled) {
      return const TutorExplanation(
        text: 'Tutoring mode is off. Turn it on first, then ask me again.',
        lesson: null,
      );
    }
    final answer = await _screenQA.ask(
      'Explain $appName step by step, like a teacher talking to a '
      '10th-class student. One UI element per line. Keep each line '
      'short and simple. End each line with a [POINT:x,y:label] tag '
      'for the element it talks about. Question: $question',
    );
    if (answer.fallbackUsed) {
      return TutorExplanation(
        text: '${answer.text}\n\nIf you tell me the names of the buttons '
            'you see, I can still walk you through them one by one.',
        lesson: null,
      );
    }
    final lesson = lessonFromAnswer(appName, answer.text);
    return TutorExplanation(text: answer.text, lesson: lesson);
  }

  /// Turn a model answer (short lines, each with a [POINT:...] tag)
  /// into a Walkthrough. Pure function — easy to test.
  static Walkthrough lessonFromAnswer(String appName, String answer) {
    final lines = answer
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final steps = <WalkthroughStep>[
      WalkthroughStep(
        title: 'Let us learn $appName',
        instruction:
            'We will go slowly, one thing at a time. Press Next when you are ready for the next one.',
      ),
    ];
    for (final line in lines) {
      final points = parsePoints(line);
      final text = stripPointTags(line)
          .replaceFirst(RegExp(r'^\d+[.)]\s*'), '')
          .trim();
      if (text.isEmpty && points.isEmpty) continue;
      steps.add(
        WalkthroughStep(
          title: points.isNotEmpty && points.first.label.isNotEmpty
              ? points.first.label
              : 'Next step',
          instruction: text.isEmpty ? 'Look here.' : text,
          point: points.isNotEmpty ? points.first : null,
        ),
      );
    }
    steps.add(
      const WalkthroughStep(
        title: 'That is it for now',
        instruction:
            'Try it yourself now. If you get stuck, ask me again and we will go through it once more.',
      ),
    );
    return Walkthrough(title: 'Learn $appName', steps: steps);
  }
}
