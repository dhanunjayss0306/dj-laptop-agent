// Widget tests for the DJ Flutter UI.
// Run: flutter test test/ui/
import 'dart:io';

import 'package:dj/core/models.dart';
import 'package:dj/services/system_ops.dart';
import 'package:dj/ui/app_state.dart';
import 'package:dj/ui/command_page.dart';
import 'package:dj/ui/command_palette.dart';
import 'package:dj/ui/duplicates_page.dart';
import 'package:dj/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Test SystemOps: opens always succeed, no native channel needed.
class FakeSystemOps implements SystemOps {
  FakeSystemOps(this.home);

  final String home;
  final List<String> trashed = [];

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
  Future<void> deleteToTrash(List<String> paths) async {
    trashed.addAll(paths);
  }

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
  // NOTE: createTempSync, not the async createTemp: awaiting real-IO
  // futures that need the event loop hangs inside testWidgets' fake
  // async zone. Sync file calls and the HttpClient probe complete fine.
  final tmp = Directory.systemTemp.createTempSync('dj-ui-test-');
  final home = Directory('${tmp.path}/home')..createSync(recursive: true);
  Directory('${home.path}/Downloads').createSync();
  final app = DjAppState(dataDir: '${tmp.path}/data', systemOps: FakeSystemOps(home.path));
  await app.refreshStatus();
  return app;
}

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('chat renders a search response', (tester) async {
    final app = await makeAppState();
    // Seed one indexed file so search has a result.
    File('${app.homeDir}/Downloads/virun-pitch.txt')
        .writeAsStringSync('Virun pitch for the travel hackathon.');
    await app.saveConfig(app.config.value.copyWith(
      folders: [FolderEntry(path: '${app.homeDir}/Downloads', enabled: true)],
    ));
    // The index build awaits real-IO futures and zero timers, so run it
    // outside the fake async zone.
    await tester.runAsync(() => app.rebuildIndex());
    expect(app.indexer.hasIndex(), isTrue);

    await tester.pumpWidget(wrap(CommandPage(app: app)));
    await tester.pumpAndSettle();

    expect(find.textContaining('Hi, I\'m DJ.'), findsOneWidget);
    expect(find.text('Capability'), findsOneWidget);
    expect(find.text('Index'), findsOneWidget);
    expect(find.text('Model'), findsOneWidget);

    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText ==
            'Find a file, open a folder, organize Downloads...',
      ),
      'find my Virun pitch',
    );
    // Pump so the Send button rebuilds enabled from the composer text.
    await tester.pump();
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(find.text('find my Virun pitch'), findsOneWidget);
    expect(find.text('virun-pitch.txt'), findsOneWidget);
    expect(find.text('Open'), findsWidgets);
  });

  testWidgets('duplicates card shows keeper without checkbox',
      (tester) async {
    final app = await makeAppState();
    final group = DuplicateGroup(
      id: '1',
      size: 100,
      sizeText: '100 B',
      wasted: 100,
      files: [
        DuplicateFile(
          path: '${app.homeDir}/a.txt',
          name: 'a.txt',
          folder: app.homeDir,
          mtime: '2026-11-25',
        ),
        DuplicateFile(
          path: '${app.homeDir}/b.txt',
          name: 'b.txt',
          folder: app.homeDir,
          mtime: '2026-11-25',
        ),
      ],
    );

    await tester.pumpWidget(wrap(DuplicateGroupCard(
      group: group,
      selected: const {},
      onToggle: (_, __) {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('keep'), findsOneWidget);
    // Only the extra copy gets a checkbox; the keeper gets none.
    expect(find.byType(Checkbox), findsOneWidget);
    expect(
      find.text('a.txt - 100 B, 2 copies, 100 B wasted'),
      findsOneWidget,
    );
  });

  testWidgets('settings shows the 4 cards', (tester) async {
    final app = await makeAppState();
    await tester.pumpWidget(wrap(SettingsPage(app: app)));
    await tester.pumpAndSettle();

    expect(find.text('Folders DJ searches'), findsOneWidget);
    expect(find.text('Capability'), findsOneWidget);
    expect(find.text('Always running'), findsOneWidget);
    expect(find.text('About DJ'), findsOneWidget);
    expect(find.text('Cloud (optional)'), findsOneWidget);
  });

  testWidgets('command palette filters', (tester) async {
    final app = await makeAppState();
    var page = -1;
    await tester.pumpWidget(wrap(Builder(
      builder: (context) => ElevatedButton(
        onPressed: () => showCommandPalette(
          context,
          app,
          PaletteActions(
            goToPage: (p) => page = p,
            rebuildIndex: () {},
            openFolders: () {},
            refreshStatus: () {},
          ),
        ),
        child: const Text('Open palette'),
      ),
    )));
    await tester.tap(find.text('Open palette'));
    await tester.pumpAndSettle();

    expect(find.text('Go to Command Center'), findsOneWidget);

    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText ==
            'Type to search pages and actions',
      ),
      'rebuild',
    );
    await tester.pumpAndSettle();

    expect(find.text('Rebuild index'), findsOneWidget);

    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText ==
            'Type to search pages and actions',
      ),
      'dupl',
    );
    await tester.pumpAndSettle();

    expect(find.text('Find duplicates'), findsOneWidget);
    expect(find.text('Go to System'), findsNothing);

    await tester.tap(find.text('Find duplicates'));
    await tester.pumpAndSettle();
    expect(page, 2);
  });
}
