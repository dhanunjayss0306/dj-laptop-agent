// DJ system tray (Windows).
//
// Same rule as the Electron app (PORTING-SPEC.md §1.8): the tray exists
// only when a tray-icon file exists. Candidates, in order:
//   <exe dir>\tray-icon.ico, then <exe dir>\resources\tray-icon.ico.
// No icon file -> no tray -> closing the window quits the app.
//
// Tooltip: "DJ - your files, found". Context menu, exactly two items in
// order: "Open DJ", "Quit DJ". Plain left-click on the icon = Open DJ.
// Close window = hide to tray (not quit) while the tray exists; "Quit DJ"
// is the only path that really quits. The tray icon is destroyed on quit.
//
// The tray never touches Dart state directly; FlutterWindow wires the
// callbacks (show window / quit) and the first-hide notification.

#ifndef RUNNER_DJ_TRAY_H_
#define RUNNER_DJ_TRAY_H_

#include <windows.h>

#include <functional>
#include <string>

namespace dj {

class DjTray {
 public:
  // |window| is the main DJ window (for menu ownership and ShowWindow).
  // |on_open| runs on icon click / "Open DJ". |on_quit| runs on "Quit DJ"
  // and must set the quitting flag and close the window for real.
  DjTray(HWND window, std::function<void()> on_open,
         std::function<void()> on_quit);
  ~DjTray();

  // Tries to create the tray icon. Returns false (and leaves no tray)
  // when no tray-icon file exists. Call once after the main window exists.
  bool Create();

  // Removes the tray icon. Call on quit.
  void Destroy();

  // True when the tray icon is currently shown.
  bool IsActive() const { return active_; }

  // Handles tray callback messages (WM_APP + kTrayCallback) and the
  // context-menu WM_COMMANDs. Returns true when the message was consumed.
  bool HandleMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

 private:
  static constexpr UINT kTrayCallbackMessage = WM_APP + 100;
  static constexpr UINT kMenuOpenId = 1;
  static constexpr UINT kMenuQuitId = 2;

  HWND window_ = nullptr;
  std::function<void()> on_open_;
  std::function<void()> on_quit_;
  HICON icon_ = nullptr;
  bool active_ = false;
};

}  // namespace dj

#endif  // RUNNER_DJ_TRAY_H_
