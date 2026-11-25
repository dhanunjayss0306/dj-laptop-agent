// Annotation controller tests: maps sent over the cursor channel,
// and clearAll. The native 'annotate' method is still pending, so
// the mock stands in for it.

import 'package:dj/features/annotations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('com.dhanunjay.dj/cursor');
  final calls = <Map<String, dynamic>>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add({'method': call.method, 'args': call.arguments});
      return <String, dynamic>{'ok': true};
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('drawCircle sends an annotate call with DJ blue', () async {
    final c = AnnotationController(channel: channel);
    expect(await c.drawCircle(100, 200, 40), isTrue);
    expect(calls.length, 1);
    expect(calls.first['method'], 'annotate');
    final list = calls.first['args']['annotations'] as List;
    expect(list.length, 1);
    expect(list.first['type'], 'circle');
    expect(list.first['x'], 100);
    expect(list.first['color'], djBlueArgb);
    expect(djBlueArgb, 0xFF0071E3);
  });

  test('drawArrow / highlight / drawText accumulate in one list', () async {
    final c = AnnotationController(channel: channel);
    await c.drawArrow(0, 0, 50, 50);
    await c.highlight(10, 10, 100, 60);
    await c.drawText(20, 20, 'Click here');
    expect(c.annotations.length, 3);
    final last = calls.last['args']['annotations'] as List;
    expect(last.length, 3);
    expect(last.map((a) => a['type']).toList(), ['arrow', 'highlight', 'text']);
  });

  test('clearAll empties the list and calls clearAnnotations', () async {
    final c = AnnotationController(channel: channel);
    await c.drawCircle(1, 2, 3);
    expect(await c.clearAll(), isTrue);
    expect(c.annotations, isEmpty);
    expect(calls.last['method'], 'clearAnnotations');
  });

  test('a missing native method returns false instead of throwing', () async {
    messenger.setMockMethodCallHandler(channel, null);
    final c = AnnotationController(channel: channel);
    expect(await c.drawCircle(1, 2, 3), isFalse);
  });
}
