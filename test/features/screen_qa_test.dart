// ScreenQA tests: [POINT:...] parsing, Core-only fallback when no
// model is running, and pointing from the user's words.
// Vision itself is NOT tested live here — the Worker has no vision
// endpoint yet (see screen_qa.dart), so the fake vision function is
// injected to prove the parsing + cursor path works end to end.


import 'package:dj/features/screen_qa.dart';
import 'package:dj/platform/cursor_channel.dart';
import 'package:dj/platform/screen_channel.dart';
import 'package:dj/platform/voice_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const screenChannel = MethodChannel('com.dhanunjay.dj/screen');
  const cursorChannel = MethodChannel('com.dhanunjay.dj/cursor');
  const voiceChannel = MethodChannel('com.dhanunjay.dj/voice');

  final cursorCalls = <Map<String, dynamic>>[];
  var speakCalls = 0;

  setUp(() {
    cursorCalls.clear();
    speakCalls = 0;
    messenger.setMockMethodCallHandler(screenChannel, (call) async {
      return <String, dynamic>{
        'ok': true,
        'png': Uint8List.fromList([1, 2, 3, 4]),
        'width': 1920,
        'height': 1080,
        'monitors': <dynamic>[],
      };
    });
    messenger.setMockMethodCallHandler(cursorChannel, (call) async {
      cursorCalls.add({
        'method': call.method,
        'args': call.arguments,
      });
      return <String, dynamic>{'ok': true};
    });
    messenger.setMockMethodCallHandler(voiceChannel, (call) async {
      if (call.method == 'speak') speakCalls++;
      return <String, dynamic>{'ok': true};
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(screenChannel, null);
    messenger.setMockMethodCallHandler(cursorChannel, null);
    messenger.setMockMethodCallHandler(voiceChannel, null);
  });

  ScreenQA qa({VisionChat? vision, bool Function()? modelUp}) => ScreenQA(
        screen: ScreenChannel(channel: screenChannel),
        cursor: CursorChannel(channel: cursorChannel),
        voice: VoiceChannel(channel: voiceChannel),
        visionChat: vision,
        modelUp: modelUp,
      );

  test('parsePoints finds tags with and without labels', () {
    final points = parsePoints(
      'Click the Save button [POINT:120,300:Save] then the X [POINT:10,20].',
    );
    expect(points.length, 2);
    expect(points[0].x, 120);
    expect(points[0].y, 300);
    expect(points[0].label, 'Save');
    expect(points[1].label, '');
    expect(stripPointTags('a [POINT:1,2:x] b'), 'a  b');
  });

  test('Core-only fallback says plainly no model is running', () async {
    final answer = await qa(modelUp: () => false).ask('what is this?');
    expect(answer.modelUsed, isFalse);
    expect(answer.fallbackUsed, isTrue);
    expect(answer.text, contains('No model is running'));
    expect(answer.points, isEmpty);
    expect(cursorCalls, isEmpty);
  });

  test('with a vision function, points move the fake cursor', () async {
    Future<String> fakeVision({
      required Uint8List png,
      required String question,
      required int width,
      required int height,
    }) async {
      expect(png, isNotEmpty);
      expect(width, 1920);
      return 'The Save button is here [POINT:500,600:Save].';
    }

    final answer = await qa(vision: fakeVision, modelUp: () => true).ask(
      'where is Save?',
      speakAnswer: true,
    );
    expect(answer.modelUsed, isTrue);
    expect(answer.points.length, 1);
    expect(answer.points.first.label, 'Save');
    expect(answer.text, isNot(contains('[POINT:')));
    expect(cursorCalls.length, 1);
    expect(cursorCalls.first['method'], 'showCursor');
    expect(speakCalls, 1);
  });

  test('pointFromWords maps rough regions only', () {
    final q = qa();
    final topLeft = q.pointFromWords(
      'top left corner',
      width: 1000,
      height: 800,
    );
    expect(topLeft.x, 150);
    expect(topLeft.y, 120);
    final middle = q.pointFromWords('in the middle', width: 1000, height: 800);
    expect(middle.x, 500);
    expect(middle.y, 400);
  });
}
