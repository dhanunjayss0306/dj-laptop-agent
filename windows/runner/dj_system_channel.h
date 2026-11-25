// DJ system channel (Windows).
//
// MethodChannel "com.dhanunjay.dj/system". Implements the SystemOps
// interface used by the Dart Core services (lib/platform/system_ops_channel.dart).
//
// Win32 APIs used (no third-party libraries):
//   openFile / openFolder : ShellExecuteW (verb "open"; Explorer for folders)
//   openApp               : CreateProcessW (DETACHED_PROCESS, no console)
//   deleteToTrash         : SHFileOperationW, FO_DELETE + FOF_ALLOWUNDO
//                           (Recycle Bin). There is NO permanent delete here.
//   getSystemStats        : GetSystemInfo, GlobalMemoryStatusEx,
//                           GetTickCount64, GetSystemTimes (delta between
//                           consecutive polls; -1.0 on the first poll, no
//                           sleep on the UI thread)
//   setStartAtLogin       : RegSetValueExW / RegDeleteValueW on
//                           HKCU\Software\Microsoft\Windows\CurrentVersion\Run
//                           value name "DJ", data = this exe's full path.
//   getHomeDir            : SHGetKnownFolderPath(FOLDERID_Profile)
//   getDownloadsDir       : SHGetKnownFolderPath(FOLDERID_Downloads)
//   pickFolder            : IFileDialog with FOS_PICKFOLDERS
//
// Every method replies {"ok": true, ...} or {"ok": false, "message": ...}.
// Nothing here throws across the channel.

#ifndef RUNNER_DJ_SYSTEM_CHANNEL_H_
#define RUNNER_DJ_SYSTEM_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

namespace dj {

class DjSystemChannel {
 public:
  explicit DjSystemChannel(flutter::BinaryMessenger* messenger);
  ~DjSystemChannel();

  // Sends the one-time "tray hidden" notification to Dart
  // (method "onTrayHidden" on this same channel). The Dart side owns the
  // "show once" flag in dj_config.json.
  void NotifyTrayHidden();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  flutter::MethodChannel<flutter::EncodableValue> channel_;
};

}  // namespace dj

#endif  // RUNNER_DJ_SYSTEM_CHANNEL_H_
