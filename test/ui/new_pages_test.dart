// Widget tests for the new HeyClicky pages: Routines, Agent, Tools,
// plus the Settings Account card when Firebase is not configured.
// Run: flutter test test/ui/
import 'dart:io';

import 'package:dj/core/models.dart';
import 'package:dj/services/system_ops.dart';
import 'package:dj/ui/agent_page.dart';
import 'package:dj/ui/app_state.dart';
import 'package:dj/ui/routines_page.dart';
import 'package:dj/ui/settings_page.dart';
import 'package:dj/ui/tools_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Test SystemOps: opens always succeed, no native channel needed.
class FakeSystemOps implements SystemOps {
  FakeSystemOps(this.home);

  final String home;

  @override
  Future<({bool ok, String message})> openFile(String path) async =>
      (ok: true, message: 'Opened.');

  @override
  Future<({bool ok, String message})> openFolder(String path) async =>
      (ok: true, message: 'Opened.');

  @override
  Future<({bool ok, String message})> openApp(
          String exe, List<String> args) async =>
      (ok: true, message: 'Opened $exe.');

  @override
  Future<void> deleteToTrash(List<String> paths) async {}

  @override
  Future<SystemStats> getSystemStats() async => SystemStats(
        cpuPercent: 12.5,
        cpuCores: 8,
        totalMemBytes: 8 * 1024 * 1024 * 1024,
        freeMemBytes: 4 * 1024 * 1024 * 1024,
        uptimeSeconds: 3600,
        platform: 'test 1.0',
        checkedAt: DateTime.now().toIso8601String(),
      );

  @override
  Future<bool> setStartAtLogin(bool enabled) async => enabled;

  @override
  String getHomeDir() => home;

  @override
  Future<String?> pickFolder() async => null;
}

Future<DjAppState> makeAppState() async {
  final tmp = Directory.systemTemp.createTempSync('dj-new-pages-test-');
  final home = Directory('${tmp.path}/home')..createSync(recursive: true);
  Directory('${home.path}/Downloads').createSync();
  final app = DjAppState(
      dataDir: '${tmp.path}/data', systemOps: FakeSystemOps(home.path));
  await app.refreshStatus();
  return app;
}

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  // Mock the native channels the new pages touch (screen capture,
  // fake cursor, voice, real input). Without these, a channel call
  // with no handler never completes inside testWidgets' fake async
  // zone and the run under test stays stuck at "Running...".
  // Capture fails (no screen in tests), cursor/voice/input succeed.
  const screenChannel = MethodChannel('com.dhanunjay.dj/screen');
  const cursorChannel = MethodChannel('com.dhanunjay.dj/cursor');
  const voiceChannel = MethodChannel('com.dhanunjay.dj/voice');
  const inputChannel = MethodChannel('com.dhanunjay.dj/input');

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger().setMockMethodCallHandler(screenChannel, (_) async {
      return <String, dynamic>{'ok': false};
    });
    messenger().setMockMethodCallHandler(cursorChannel, (_) async {
      return <String, dynamic>{'ok': true};
    });
    messenger().setMockMethodCallHandler(voiceChannel, (_) async {
      return <String, dynamic>{'ok': true};
    });
    messenger().setMockMethodCallHandler(inputChannel, (_) async {
      return <String, dynamic>{'ok': true};
    });
  });

  tearDown(() {
    messenger().setMockMethodCallHandler(screenChannel, null);
    messenger().setMockMethodCallHandler(cursorChannel, null);
    messenger().setMockMethodCallHandler(voiceChannel, null);
    messenger().setMockMethodCallHandler(inputChannel, null);
  });

  testWidgets('routines page lists built-ins and saves one', (tester) async {
    final app = await makeAppState();
    await tester.pumpWidget(wrap(RoutinesPage(app: app)));
    await tester.pumpAndSettle();

    expect(find.text('morning routine'), findsOneWidget);
    expect(find.text('wind down'), findsOneWidget);

    await tester.enterText(
      find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.hintText == 'Routine name',
      ),
      'test routine',
    );
    await tester.enterText(
      find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.hintText ==
                'Message, app name, folder, or seconds',
      ),
      'Hello there',
    );
    await tester.tap(find.text('Save routine'));
    await tester.pumpAndSettle();

    expect(find.text('test routine'), findsOneWidget);
  });

  testWidgets('routines page runs and deletes a routine', (tester) async {
    final app = await makeAppState();
    await tester.pumpWidget(wrap(RoutinesPage(app: app)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Run').first);
    await tester.pumpAndSettle();

    // The morning routine opens Chrome (not installed in the test
    // VM) and lists recent files, so the run reports plainly.
    expect(find.textContaining('could not find'), findsWidgets);

    await tester.tap(find.text('Delete').first);
    await tester.pumpAndSettle();

    expect(find.text('morning routine'), findsNothing);
    expect(find.text('wind down'), findsOneWidget);
  });

  testWidgets('agent page runs a task and shows its steps', (tester) async {
    final app = await makeAppState();
    await tester.pumpWidget(wrap(AgentPage(app: app)));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.hintText == 'DJ agent open Chrome',
      ),
      'open chrome',
    );
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Open chrome'), findsWidgets);
    expect(find.textContaining('Done: true'), findsOneWidget);
  });

  testWidgets('tools page lists integrations and starts a walkthrough',
      (tester) async {
    final app = await makeAppState();
    await tester.pumpWidget(wrap(ToolsPage(app: app)));
    await tester.pumpAndSettle();

    expect(find.text('Tutor'), findsOneWidget);
    expect(find.text('Integrations'), findsOneWidget);
    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('Gmail'), findsOneWidget);
    expect(find.text('Walkthroughs'), findsOneWidget);

    await tester.ensureVisible(find.text('Start example walkthrough'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start example walkthrough'));
    await tester.pumpAndSettle();

    expect(find.text('Step 1 of 5'), findsOneWidget);
    expect(find.text('Open Chrome'), findsOneWidget);
  });

  testWidgets('tools page tutor says plainly when it cannot see the screen',
      (tester) async {
    final app = await makeAppState();
    await tester.pumpWidget(wrap(ToolsPage(app: app)));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.enterText(
      find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.hintText == 'What do you want to learn?',
      ),
      'how do I search',
    );
    await tester.tap(find.text('Explain'));
    await tester.pumpAndSettle();

    expect(find.textContaining('could not capture'), findsWidgets);
  });

  testWidgets('settings account card says Firebase setup is needed',
      (tester) async {
    final app = await makeAppState();
    await tester.pumpWidget(wrap(SettingsPage(app: app)));
    await tester.pumpAndSettle();

    expect(find.text('Account'), findsOneWidget);
    expect(
      find.text('Set up Firebase first (see FIREBASE-SETUP.md)'),
      findsOneWidget,
    );
  });
}
