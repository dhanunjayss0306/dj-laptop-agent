// SystemOps — the ONLY way services touch the OS.
//
// Abstract interface (method signatures only, no implementation).
// The Windows/Android plugin tasks implement this per platform
// (platform channel — see lib/platform/system_ops_channel.dart).
// Services must call ONLY this interface for OS actions — never
// dart:io Process, and never File.delete() for destructive work
// (delete goes to the Recycle Bin / Trash only).
import '../core/models.dart';

abstract class SystemOps {
  /// Open a file with the OS default app.
  Future<({bool ok, String message})> openFile(String path);

  /// Open a folder in the file manager (Explorer on Windows).
  Future<({bool ok, String message})> openFolder(String path);

  /// Launch an executable (already resolved), detached.
  Future<({bool ok, String message})> openApp(String exe, List<String> args);

  /// Move files to the Recycle Bin / Trash. NEVER permanent delete.
  Future<void> deleteToTrash(List<String> paths);

  Future<SystemStats> getSystemStats();

  /// Persist + apply "start at login". Returns the value in effect.
  Future<bool> setStartAtLogin(bool enabled);

  /// The user's home folder.
  String getHomeDir();

  /// Native folder picker. Null = cancelled.
  Future<String?> pickFolder();
}
