// Smoke test: the real app boots and shows the Command Center.
import 'dart:io';
import 'dart:ui';

import 'package:dj/core/models.dart';
import 'package:dj/main.dart';
import 'package:dj/ui/app_state.dart';
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
}
