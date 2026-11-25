// Agent mode safety tests: stuck detection, password refusal,
// 15-step cap, no-screen-change stop. All tools are fakes — no
// channels, no model, no real clicks.

import 'package:dj/features/agent_mode.dart';
import 'package:flutter_test/flutter_test.dart';

AgentMode mode(
  Map<String, AgentToolFn> tools, {
  bool Function()? passwordFieldFocused,
}) =>
    AgentMode(
      tools: tools,
      showBeforeClickDelay: Duration.zero,
      passwordFieldFocused: passwordFieldFocused,
    );

void main() {
  test('stuck detection stops after the same action 3 times', () async {
    final clicked = <String>[];
    final m = mode({
      'point': (input) async => 'pointed at $input',
      'click': (input) async {
        clicked.add(input);
        return 'clicked $input';
      },
    });
    final result = await m.run(
      'click the same button',
      planOverride: const [
        AgentPlanStep(tool: 'click', input: '100,200:Save', description: 'Click Save'),
        AgentPlanStep(tool: 'click', input: '100,200:Save', description: 'Click Save'),
        AgentPlanStep(tool: 'click', input: '100,200:Save', description: 'Click Save'),
        AgentPlanStep(tool: 'click', input: '100,200:Save', description: 'Click Save'),
      ],
    );
    expect(result.done, isFalse);
    expect(result.stoppedReason, contains('same action 3 times'));
    // The 3rd identical action is the one that trips the detector,
    // so it never executes — only the first two clicks ran.
    expect(clicked.length, 2);
    m.dispose();
  });

  test('password refusal stops the task when the text has a password', () async {
    var typed = false;
    final m = mode({
      'type': (input) async {
        typed = true;
        return 'typed';
      },
    });
    final result = await m.run(
      'log in for me',
      planOverride: const [
        AgentPlanStep(
          tool: 'type',
          input: 'my password is hunter2',
          description: 'Type the password',
        ),
      ],
    );
    expect(result.done, isFalse);
    expect(result.stoppedReason, contains('never type passwords'));
    expect(typed, isFalse);
    m.dispose();
  });

  test('password refusal stops when a password field is focused', () async {
    var typed = false;
    final m = mode(
      {
        'type': (input) async {
          typed = true;
          return 'typed';
        },
      },
      passwordFieldFocused: () => true,
    );
    final result = await m.run(
      'type hello',
      planOverride: const [
        AgentPlanStep(tool: 'type', input: 'hello', description: 'Type hello'),
      ],
    );
    expect(result.done, isFalse);
    expect(result.stoppedReason, contains('never type passwords'));
    expect(typed, isFalse);
    m.dispose();
  });

  test('15-step cap stops a 20-step task', () async {
    var calls = 0;
    final m = mode({
      'search': (input) async {
        calls++;
        return 'result $calls for $input';
      },
    });
    final plan = List<AgentPlanStep>.generate(
      20,
      (i) => AgentPlanStep(
        tool: 'search',
        input: 'query $i',
        description: 'Search $i',
      ),
    );
    final result = await m.run('do twenty searches', planOverride: plan);
    expect(result.done, isFalse);
    expect(result.stepsTaken, 15);
    expect(calls, 15);
    expect(result.stoppedReason ?? result.error ?? '', contains('15 steps'));
    m.dispose();
  });

  test('no screen change for 3 steps stops the task', () async {
    var calls = 0;
    final m = mode({
      'search': (input) async {
        calls++;
        return 'result $calls';
      },
      // Same fingerprint every time: the screen never changes.
      'captureScreen': (_) async => 'fingerprint-abc',
    });
    final plan = List<AgentPlanStep>.generate(
      5,
      (i) => AgentPlanStep(
        tool: 'search',
        input: 'query $i',
        description: 'Search $i',
      ),
    );
    final result = await m.run('search a lot', planOverride: plan);
    expect(result.done, isFalse);
    expect(result.stoppedReason, contains('screen has not changed'));
    expect(calls, 4);
    m.dispose();
  });

  test('show-before-click points first, then clicks', () async {
    final order = <String>[];
    final m = mode({
      'point': (input) async {
        order.add('point');
        return 'pointed';
      },
      'click': (input) async {
        order.add('click');
        return 'clicked';
      },
    });
    final result = await m.run(
      'click it',
      planOverride: const [
        AgentPlanStep(tool: 'click', input: '50,60:OK', description: 'Click OK'),
      ],
    );
    expect(result.done, isTrue);
    expect(order, ['point', 'click']);
    m.dispose();
  });

  test('a short plan finishes normally', () async {
    final m = mode({
      'search': (input) async => 'found notes about $input',
    });
    final result = await m.run(
      'find my notes',
      planOverride: const [
        AgentPlanStep(tool: 'search', input: 'notes', description: 'Search notes'),
      ],
    );
    expect(result.done, isTrue);
    expect(result.answer, contains('found notes'));
    m.dispose();
  });

  test('empty task is blocked by the judge before anything runs', () async {
    var called = false;
    final m = mode({
      'search': (input) async {
        called = true;
        return 'x';
      },
    });
    final result = await m.run('   ');
    expect(result.done, isFalse);
    expect(result.stoppedReason, contains('Blocked by judge'));
    expect(called, isFalse);
    m.dispose();
  });

  test('Core-rules plan routes open-app tasks to the openApp tool', () {
    final plan = AgentMode.planWithCoreRules('open chrome');
    expect(plan.length, 1);
    expect(plan.first.tool, 'openApp');
    expect(plan.first.input, 'chrome');
  });
}
