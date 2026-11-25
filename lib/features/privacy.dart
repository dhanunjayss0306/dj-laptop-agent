// PrivacyService — enforces DJ's privacy rules in code, not just
// in words.
//
// THE RULES:
//   1. Screenshots are NEVER written to disk. ScreenQA keeps them in
//      memory only and drops them after the answer. There is no code
//      path in this app that writes screen bytes to a file — the test
//      in test/features/privacy_test.dart asserts exactly that (no
//      .png/.jpg file appears in the data dir after a ScreenQA run).
//   2. Only plain-text summaries / diary lines are kept (MEMORY.md,
//      memory/YYYY-MM-DD.md, dj_config.json, routines.json, index
//      files). No audio, no images, no transcripts on disk.
//   3. [deleteAllData] wipes the whole dj_data folder and resets the
//      app to first-run.
//   4. [clearScreenHistory] exists but is a documented no-op: nothing
//      is stored, so there is nothing to clear.
//
// DELETE CONFIRMATION CONTRACT (for the UI agent): the UI must ask
// the user ONCE, with one clear confirm dialog ("Delete all DJ data?
// This wipes your index, settings, memory and routines. This cannot
// be undone."), and call [deleteAllData] with confirmed: true only
// when the user confirms. Type-to-confirm is overkill — one clear
// confirm dialog is enough. Calling with confirmed: false (or
// forgetting the dialog) throws and deletes nothing.

import 'dart:io';

class PrivacyService {
  PrivacyService({required this.dataDir});

  /// The dj_data folder (index, config, memory, routines live here).
  final String dataDir;

  /// The privacy rules, as plain text, for the UI / settings page.
  static const String rules = '''
DJ keeps your files on this laptop only.
• Screenshots are never saved. DJ looks at your screen only when you ask, and the picture is dropped as soon as it answers.
• Only plain-text notes are kept: your memory files, settings, routines and the search index.
• No account, no sign-in, no fee, no usage limits.
• Delete all data wipes everything and starts DJ over as first-run.
''';

  /// Screenshots are never written to disk. This is the code-level
  /// statement of rule 1: there is no write path for screen bytes.
  /// The privacy test asserts no image file appears in [dataDir]
  /// after a ScreenQA run.
  static const bool screenshotsAreMemoryOnly = true;

  /// Nothing is stored, so there is nothing to clear. Returns a
  /// plain message for the UI. Deliberately a no-op — do NOT "fix"
  /// it by inventing a history store.
  String clearScreenHistory() =>
      'Nothing to clear — DJ never stores screenshots.';

  /// Wipe the whole dj_data folder and reset the app to first-run.
  ///
  /// [confirmed] must be true — the UI must have shown the one clear
  /// confirm dialog first (see the contract above). With confirmed:
  /// false this throws [StateError] and deletes nothing.
  ///
  /// Safety: refuses when [dataDir] does not look like a dj_data
  /// folder (its last segment must be 'dj_data'), so a wrong path
  /// can never wipe a home folder or a drive root.
  Future<void> deleteAllData({required bool confirmed}) async {
    if (!confirmed) {
      throw StateError(
        'deleteAllData needs a confirmed user choice first. '
        'Show the confirm dialog, then call again with confirmed: true.',
      );
    }
    final dir = Directory(dataDir);
    final last = dir.path
        .split(Platform.pathSeparator)
        .where((s) => s.isNotEmpty)
        .lastOrNull;
    if (last != 'dj_data') {
      throw StateError(
        'Refusing to delete "$dataDir": it is not a dj_data folder.',
      );
    }
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    // Recreate the empty folder so the next launch is a clean first-run.
    await dir.create(recursive: true);
  }

  /// List every file under [dataDir] (for audits / the privacy test).
  List<String> auditDataDir() {
    final dir = Directory(dataDir);
    if (!dir.existsSync()) return const [];
    return dir
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path)
        .toList();
  }
}
