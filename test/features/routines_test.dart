// Routines tests: save / list / delete / run, plus the built-ins.
// Uses a temp dj_data folder and a fake SystemOps — no real apps.

import 'dart:io';

import 'package:dj/features/agent_mode.dart';
import 'package:dj/features/routines.dart';
import 'package:dj/services/app_launcher.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// AppLauncher that always succeeds (AppLauncher itself looks for a
/// real chrome.exe on PATH, which the Linux test machine has not got).
class FakeAppLauncher extends AppLauncher {
  FakeAppLauncher() : super(FakeSystemOps());

  @override
  Future<({bool ok, String message})> openApp(String name) async =>
      (ok: true, message: 'Opened $name.');
}

class FailingAppLauncher extends AppLauncher {
  FailingAppLauncher() : super(FailingSystemOps());

  @override
  Future<({bool ok, String message})> openApp(String name) async =>
      (
        ok: false,
        message: "I could not find an app called '$name' on this laptop.",
      );
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dj_routines_test_');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  RoutineStore store({Future<AgentTaskResult> Function(String)? runner}) {
    final ops = FakeSystemOps();
    return RoutineStore(
      dataDir: tmp.path,
      systemOps: ops,
      appLauncher: FakeAppLauncher(),
      runAgentTask: runner ??
          (_) async => const AgentTaskResult(
                done: true,
                stepsTaken: 1,
                answer: 'newest: a.txt',
              ),
      newestFiles: () async => ['a.txt', 'b.txt'],
    );
  }

  test('built-ins exist when no file is saved yet', () {
    final s = store();
    final names = s.listRoutines().map((r) => r.name).toList();
    expect(names, contains('morning routine'));
    expect(names, contains('wind down'));
  });

  test('wind down never closes anything', () {
    final windDown = builtInRoutines().firstWhere(
      (r) => r.name == 'wind down',
    );
    expect(
      windDown.steps.map((s) => s.kind),
      everyElement(isNot('closeApp')),
    );
    expect(windDown.steps.map((s) => s.kind), isNot(contains('close')));
  });

  test('saveRoutine adds a routine and listRoutines returns it', () {
    final s = store();
    s.saveRoutine(
      const Routine(
        name: 'study time',
        steps: [RoutineStep(kind: 'showMessage', target: 'Go study.')],
      ),
    );
    expect(
      s.listRoutines().map((r) => r.name),
      contains('study time'),
    );
    // Saved to disk: a fresh store sees it too.
    expect(store().listRoutines().map((r) => r.name), contains('study time'));
  });

  test('saveRoutine replaces a routine with the same name', () {
    final s = store();
    s.saveRoutine(
      const Routine(
        name: 'study time',
        steps: [RoutineStep(kind: 'showMessage', target: 'v1')],
      ),
    );
    s.saveRoutine(
      const Routine(
        name: 'study time',
        steps: [RoutineStep(kind: 'showMessage', target: 'v2')],
      ),
    );
    final found = s.listRoutines().where((r) => r.name == 'study time');
    expect(found.length, 1);
    expect(found.first.steps.first.target, 'v2');
  });

  test('deleteRoutine removes it and returns true; unknown returns false', () {
    final s = store();
    s.saveRoutine(
      const Routine(
        name: 'temp',
        steps: [RoutineStep(kind: 'showMessage', target: 'hi')],
      ),
    );
    expect(s.deleteRoutine('temp'), isTrue);
    expect(s.listRoutines().map((r) => r.name), isNot(contains('temp')));
    expect(s.deleteRoutine('temp'), isFalse);
  });

  test('runRoutine runs steps in order and reports each one', () async {
    final s = store();
    final seen = <String>[];
    final result = await s.runRoutine('morning routine');
    expect(result.ok, isTrue);
    expect(result.lines.length, 4);
    expect(result.lines[0], contains('Opened chrome.'));
    expect(result.lines[1], contains('Opened vs code.'));
    expect(result.lines[2], contains('a.txt'));
    expect(result.lines[3], contains('newest: a.txt'));
    expect(seen, isEmpty); // onStep not wired in this store
  });

  test('runRoutine reports each step through onStep', () async {
    final lines = <String>[];
    final ops = FakeSystemOps();
    final s = RoutineStore(
      dataDir: tmp.path,
      systemOps: ops,
      appLauncher: FakeAppLauncher(),
      onStep: lines.add,
    );
    await s.runRoutine('wind down');
    expect(lines.length, 2);
    expect(lines.first, contains('Winding down'));
  });

  test('runRoutine of an unknown name reports an error', () async {
    final s = store();
    final result = await s.runRoutine('no such routine');
    expect(result.ok, isFalse);
    expect(result.errors.first, contains('No routine called'));
  });

  test('waitSeconds(0) and showMessage steps run without wiring', () async {
    final s = RoutineStore(dataDir: tmp.path);
    s.saveRoutine(
      const Routine(
        name: 'quick',
        steps: [
          RoutineStep(kind: 'waitSeconds', target: '0'),
          RoutineStep(kind: 'showMessage', target: 'Hello.'),
        ],
      ),
    );
    final result = await s.runRoutine('quick');
    expect(result.ok, isTrue);
    expect(result.lines, ['Waited 0 seconds.', 'Hello.']);
  });

  test('a failing openApp step is recorded and the run continues', () async {
    final ops = FailingSystemOps();
    final s = RoutineStore(
      dataDir: tmp.path,
      systemOps: ops,
      appLauncher: FailingAppLauncher(),
    );
    final result = await s.runRoutine('morning routine');
    expect(result.ok, isFalse);
    expect(result.lines.first, contains('could not find'));
    expect(result.lines.length, 4);
  });
}
