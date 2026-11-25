#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "dj_cursor_channel.h"
#include "dj_hotkey.h"
#include "dj_input_channel.h"
#include "dj_screen_channel.h"
#include "dj_system_channel.h"
#include "dj_tray.h"
#include "dj_voice_channel.h"
#include "win32_window.h"

// A window that hosts a Flutter view, plus DJ's native Windows services:
// the six MethodChannels (system, screen, cursor, input, voice, hotkey)
// and the system tray (hide-on-close while the tray exists, "Quit DJ" to
// quit).
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
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
