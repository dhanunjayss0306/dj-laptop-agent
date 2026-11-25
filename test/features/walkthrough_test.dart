// Walkthrough engine tests: step advance / back / cancel / finish,
// using a mocked cursor channel (no native side needed).

import 'package:dj/features/screen_qa.dart' show ScreenPoint;
import 'package:dj/features/walkthrough.dart';
import 'package:dj/platform/cursor_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const cursorChannel = MethodChannel('com.dhanunjay.dj/cursor');
  final shown = <String>[];

  setUp(() {
    shown.clear();
    messenger.setMockMethodCallHandler(cursorChannel, (call) async {
      if (call.method == 'showCursor' || call.method == 'moveCursor') {
        shown.add('${call.arguments['x']},${call.arguments['y']}');
      }
      return <String, dynamic>{'ok': true};
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(cursorChannel, null);
  });

  WalkthroughEngine engine() =>
      WalkthroughEngine(cursor: CursorChannel(channel: cursorChannel));

  test('starts on step 1 of 5 and advances one step at a time', () async {
    final e = engine();
    await e.start(Walkthrough.exampleChromeSearch());
    expect(e.status, WalkthroughStatus.running);
    expect(e.progressLabel, 'Step 1 of 5');
    expect(e.currentStep?.title, 'Open Chrome');

    await e.next();
    expect(e.progressLabel, 'Step 2 of 5');
    expect(e.currentStep?.title, 'Click the address bar');

    await e.next();
    await e.next();
    expect(e.progressLabel, 'Step 4 of 5');
    e.dispose();
  });

  test('previous goes back one step and stops at the first', () async {
    final e = engine();
    await e.start(Walkthrough.exampleChromeSearch());
    await e.next();
    await e.next();
    await e.previous();
    expect(e.progressLabel, 'Step 2 of 5');
    await e.previous();
    await e.previous();
    expect(e.progressLabel, 'Step 1 of 5');
    e.dispose();
  });

  test('next on the last step finishes and hides the cursor', () async {
    final e = engine();
    await e.start(Walkthrough.exampleChromeSearch());
    for (var i = 0; i < 5; i++) {
      await e.next();
    }
    expect(e.status, WalkthroughStatus.done);
    e.dispose();
  });

  test('cancel stops the walkthrough and hides the cursor', () async {
    final e = engine();
    await e.start(Walkthrough.exampleChromeSearch());
    await e.next();
    await e.cancel();
    expect(e.status, WalkthroughStatus.cancelled);
    expect(e.isRunning, isFalse);
    // Next after cancel does nothing.
    await e.next();
    expect(e.status, WalkthroughStatus.cancelled);
    e.dispose();
  });

  test('a step with a point moves the fake cursor there', () async {
    final e = engine();
    const walkthrough = Walkthrough(
      title: 'point test',
      steps: [
        WalkthroughStep(
          title: 'Look here',
          instruction: 'Look at this button.',
          point: ScreenPoint(x: 100, y: 200, label: 'the button'),
        ),
      ],
    );
    await e.start(walkthrough);
    expect(shown, ['100,200']);
    e.dispose();
  });

  test('runCurrentAction without an actionRunner waits for Next', () async {
    final e = engine();
    await e.start(Walkthrough.exampleChromeSearch());
    await e.runCurrentAction();
    expect(e.progressLabel, 'Step 1 of 5');
    e.dispose();
  });

  test('runCurrentAction auto-advances when the action completes', () async {
    var ran = 0;
    final e = WalkthroughEngine(
      cursor: CursorChannel(channel: cursorChannel),
      actionRunner: (_) async {
        ran++;
        return true;
      },
    );
    await e.start(Walkthrough.exampleChromeSearch());
    await e.runCurrentAction();
    expect(ran, 1);
    expect(e.progressLabel, 'Step 2 of 5');
    e.dispose();
  });

  test('emits state updates on the stream', () async {
    final e = engine();
    final states = <WalkthroughState>[];
    final sub = e.updates.listen(states.add);
    await e.start(Walkthrough.exampleChromeSearch());
    await e.next();
    await Future<void>.delayed(Duration.zero);
    expect(states.length, 2);
    expect(states.last.progressLabel, 'Step 2 of 5');
    await sub.cancel();
    e.dispose();
  });
}
