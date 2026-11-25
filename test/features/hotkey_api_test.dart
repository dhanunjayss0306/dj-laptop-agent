// Hotkey API tests: register/unregister over the mocked channel,
// and the shared stream fed by feedPress (Android floating button /
// wake word path).


import 'package:dj/features/hotkey_api.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('com.dhanunjay.dj/hotkey');

  setUp(() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'registerHotkey') {
        expect(call.arguments['hotkey'], isA<String>());
        return <String, dynamic>{'ok': true};
      }
      if (call.method == 'unregisterHotkey') {
        return <String, dynamic>{'ok': true};
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('default hotkey is Ctrl+Alt+D', () {
    expect(HotkeyService.defaultHotkey, 'Ctrl+Alt+D');
  });

  test('registerHotkey registers the default and reports it', () async {
    final hotkeys = HotkeyService(channel: channel);
    expect(await hotkeys.registerHotkey(), isTrue);
    expect(hotkeys.registeredHotkey, 'Ctrl+Alt+D');
    hotkeys.dispose();
  });

  test('registerHotkey accepts a custom hotkey', () async {
    final hotkeys = HotkeyService(channel: channel);
    expect(await hotkeys.registerHotkey(hotkey: 'Ctrl+Alt+J'), isTrue);
    expect(hotkeys.registeredHotkey, 'Ctrl+Alt+J');
    hotkeys.dispose();
  });

  test('unregisterHotkey clears the registration', () async {
    final hotkeys = HotkeyService(channel: channel);
    await hotkeys.registerHotkey();
    expect(await hotkeys.unregisterHotkey(), isTrue);
    expect(hotkeys.registeredHotkey, isNull);
    hotkeys.dispose();
  });

  test('feedPress emits on the shared stream', () async {
    final hotkeys = HotkeyService(channel: channel);
    final events = <void>[];
    final sub = hotkeys.onHotkeyPressed.listen(events.add);
    hotkeys.feedPress();
    hotkeys.feedPress();
    await Future<void>.delayed(Duration.zero);
    expect(events.length, 2);
    await sub.cancel();
    hotkeys.dispose();
  });

  test('registerHotkey returns false when the native side is missing', () async {
    messenger.setMockMethodCallHandler(channel, null);
    final hotkeys = HotkeyService(channel: channel);
    expect(await hotkeys.registerHotkey(), isFalse);
    expect(hotkeys.registeredHotkey, isNull);
    hotkeys.dispose();
  });
}
