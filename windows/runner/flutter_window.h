#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <atomic>
#include <chrono>
#include <memory>
#include <thread>

#include "dj_camera_channel.h"
#include "dj_cursor_channel.h"
#include "dj_hotkey.h"
#include "dj_input_channel.h"
#include "dj_screen_channel.h"
#include "dj_system_channel.h"
#include "dj_tray.h"
#include "dj_voice_channel.h"
#include "win32_window.h"

// A window that hosts a Flutter view, plus DJ's native Windows services:
// the seven MethodChannels (system, screen, cursor, input, voice, hotkey,
// privacy camera) and the system tray (hide-on-close while the tray
// exists, "Quit DJ" to quit). The privacy camera channel is function
// based (see dj_camera_channel.h) rather than a member, because its
// capture thread needs a plain window handle for its reply message.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // Restores the window if minimized, then shows and focuses it.
  // Used by the tray ("Open DJ" / icon click).
  void ShowWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // DJ native channels (created in OnCreate, destroyed in OnDestroy).
  std::unique_ptr<dj::DjSystemChannel> system_channel_;
  std::unique_ptr<dj::DjScreenChannel> screen_channel_;
  std::unique_ptr<dj::DjCursorChannel> cursor_channel_;
  std::unique_ptr<dj::DjInputChannel> input_channel_;
  std::unique_ptr<dj::DjVoiceChannel> voice_channel_;
  std::unique_ptr<dj::DjHotkeyChannel> hotkey_channel_;

  // System tray. Null/absent when no tray-icon file exists; in that case
  // closing the window quits the app (Electron rule, PORTING-SPEC §1.8).
  std::unique_ptr<dj::DjTray> tray_;

  // Set only by the tray "Quit DJ" menu item. While false, closing the
  // window hides it into the tray instead of quitting.
  bool is_quitting_ = false;

  // First-frame fallback + watchdog (see flutter_window.cpp).
  //
  // The Flutter child window is blank white until the engine paints
  // its first frame. While no frame has arrived, a plain native
  // "DJ is starting..." label covers the client area so the window
  // never sits blank, and a watchdog thread logs whether the frame is
  // late and whether the platform thread is still pumping messages.
  // The label is hidden the moment the first frame callback fires, so
  // the normal fast path is untouched.
  HWND starting_label_ = nullptr;
  std::atomic<bool> first_frame_seen_{false};
  std::atomic<bool> stop_watchdog_{false};
  std::thread watchdog_thread_;

  // Watchdog body: runs on its own thread, never on the UI thread.
  void WatchdogLoop(HWND window, DWORD started_tick);

  // (Re)positions the starting label over the client area.
  void LayoutStartingLabel();
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
