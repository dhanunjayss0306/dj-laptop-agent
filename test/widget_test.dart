// Smoke test: the real app boots and shows the Command Center.
import 'dart:io';

import 'package:dj/core/models.dart';
import 'package:dj/main.dart';
import 'package:dj/ui/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui/ui_test.dart' show FakeSystemOps;

void main() {
  testWidgets('DJ app boots to the Command Center', (tester) async {
    // A realistic laptop window. The default 800x600 test surface is
    // shorter than any real DJ window, and the Command Center's status
    // cards overflow it by ~33 px (the Send row gets cut off).
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    // createTempSync: the async createTemp hangs inside testWidgets'
    // fake-async zone in this VM (same workaround as test/ui/).
    final tmp = Directory.systemTemp.createTempSync('dj-smoke-test-');
    final home = Directory('${tmp.path}/home')..createSync(recursive: true);
    Directory('${home.path}/Downloads').createSync();
    final dataDir = '${tmp.path}/data';
    Directory(dataDir).createSync(recursive: true);
    // Seed a one-file index so the first-run Folders dialog stays closed.
    File('$dataDir/keyword_index.json').writeAsStringSync(
      '{"files":[{"path":"${home.path}/x.txt","name":"x.txt","folder":"${home.path}","text":"hello"}],"folders":[]}',
    );
    final app = DjAppState(
      dataDir: dataDir,
      systemOps: FakeSystemOps(home.path),
    );
    // Scope the folders to the tiny temp home. The default config
    // includes the real home dir, and DuplicatesPage scans it on open;
    // on this VM that is 21 GB of files and blocks the test pump.
    app.config.value = app.config.value.copyWith(
      folders: [FolderEntry(path: home.path, enabled: true)],
    );
    await tester.pumpWidget(DjApp(app: app));
    // Bounded pumps only: pumpAndSettle never returns here because
    // the shell starts background capability probes (real HTTP with
    // timeouts) that do not settle in the fake-async zone.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('DJ'), findsWidgets);
    expect(find.text('Command Center'), findsOneWidget);
  });

  testWidgets('narrow layout shows 5 bottom tabs, rest in the drawer',
      (tester) async {
    // A phone-sized window: below the 700px wide breakpoint, so the
    // shell uses the bottom bar + drawer instead of the side nav.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final tmp = Directory.systemTemp.createTempSync('dj-narrow-test-');
    final home = Directory('${tmp.path}/home')..createSync(recursive: true);
    Directory('${home.path}/Downloads').createSync();
    final dataDir = '${tmp.path}/data';
    Directory(dataDir).createSync(recursive: true);
    File('$dataDir/keyword_index.json').writeAsStringSync(
      '{"files":[{"path":"${home.path}/x.txt","name":"x.txt","folder":"${home.path}","text":"hello"}],"folders":[]}',
    );
    final app = DjAppState(
      dataDir: dataDir,
      systemOps: FakeSystemOps(home.path),
    );
    app.config.value = app.config.value.copyWith(
      folders: [FolderEntry(path: home.path, enabled: true)],
    );
    await tester.pumpWidget(DjApp(app: app));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    // 5 primary tabs, not 11: each gets a fifth of the phone width.
    final bar = tester.widget<BottomNavigationBar>(
      find.byType(BottomNavigationBar),
    );
    expect(bar.items.length, 5);
    expect(
      bar.items.map((item) => item.label).toList(),
      ['Command Center', 'Files', 'Agent', 'Tools', 'Settings'],
    );
    // Drawer-only pages are not in the bottom bar.
    expect(find.text('Duplicates'), findsNothing);
    expect(find.text('Privacy Screen'), findsNothing);

    // The drawer lists the other 6 pages.
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    for (final title in [
      'Duplicates',
      'Organize',
      'System',
      'Memory',
      'Routines',
      'Privacy Screen',
    ]) {
      expect(find.text(title), findsOneWidget);
    }

    // A drawer page opens from the drawer.
    await tester.tap(find.text('Duplicates'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Find duplicates'), findsOneWidget);

    // A primary tab still works after a drawer page.
    await tester.tap(find.text('Settings'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Folders DJ searches'), findsOneWidget);
  });

  testWidgets('badge chip names the cloud provider at phone width',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final tmp = Directory.systemTemp.createTempSync('dj-badge-test-');
    final home = Directory('${tmp.path}/home')..createSync(recursive: true);
    Directory('${home.path}/Downloads').createSync();
    final dataDir = '${tmp.path}/data';
    Directory(dataDir).createSync(recursive: true);
    File('$dataDir/keyword_index.json').writeAsStringSync(
      '{"files":[{"path":"${home.path}/x.txt","name":"x.txt","folder":"${home.path}","text":"hello"}],"folders":[]}',
    );
    final app = DjAppState(
      dataDir: dataDir,
      systemOps: FakeSystemOps(home.path),
    );
    app.config.value = app.config.value.copyWith(
      folders: [FolderEntry(path: home.path, enabled: true)],
    );
    // A configured Worker (dj_cloud.json) resolves to Cloud (gemini).
    app.status.value = DjStatus(
      filesIndexed: 1,
      foldersIndexed: 1,
      vectorOk: false,
      embedderState: 'not started',
      embedderSource: 'none',
      hasIndex: true,
      indexStale: false,
      config: app.config.value,
      capability: const CapabilityStatus(
        layer: 'cloud',
        local: LocalModelHealth(available: false),
        cloud: CloudHealth(configured: true, valid: true, reason: 'gemini'),
        message: 'Cloud (gemini) (local model also available)',
        checkedAt: '',
      ),
      startAtLogin: false,
      hasTray: false,
    );
    await tester.pumpWidget(DjApp(app: app));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // The AppBar chip names the provider; the footer and the Command
    // Center status card both show the full message, so it appears
    // twice. A 390px AppBar with the longer chip must not overflow.
    expect(find.text('Cloud (gemini)'), findsOneWidget);
    expect(find.text('Cloud (gemini) (local model also available)'),
        findsNWidgets(2));

    // Longest provider name: the AppBar must still fit at 390px.
    app.status.value = DjStatus(
      filesIndexed: 1,
      foldersIndexed: 1,
      vectorOk: false,
      embedderState: 'not started',
      embedderSource: 'none',
      hasIndex: true,
      indexStale: false,
      config: app.config.value,
      capability: const CapabilityStatus(
        layer: 'cloud',
        local: LocalModelHealth(available: false),
        cloud: CloudHealth(
            configured: true, valid: true, reason: 'openrouter'),
        message: 'Cloud (openrouter)',
        checkedAt: '',
      ),
      startAtLogin: false,
      hasTray: false,
    );
    await tester.pump();
    // Chip + footer + status card all show it.
    expect(find.text('Cloud (openrouter)'), findsNWidgets(3));
  });

  testWidgets('first run shows the folders dialog at phone width',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final tmp = Directory.systemTemp.createTempSync('dj-first-run-test-');
    final home = Directory('${tmp.path}/home')..createSync(recursive: true);
    Directory('${home.path}/Downloads').createSync();
    final dataDir = '${tmp.path}/data';
    Directory(dataDir).createSync(recursive: true);
    // No keyword_index.json: first run, so the setup dialog must appear.
    final app = DjAppState(
      dataDir: dataDir,
      systemOps: FakeSystemOps(home.path),
    );
    app.config.value = app.config.value.copyWith(
      folders: [FolderEntry(path: home.path, enabled: true)],
    );
    await tester.pumpWidget(DjApp(app: app));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Set up DJ'), findsOneWidget);
    expect(find.text('Save and build index'), findsOneWidget);

    await tester.tap(find.text('Save and build index'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Set up DJ'), findsNothing);
    expect(find.text('Command Center'), findsWidgets);
  });
}
