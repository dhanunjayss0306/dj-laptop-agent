#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // DJ native channels. The messenger outlives the channels: they are
  // destroyed in OnDestroy before the Flutter controller is reset.
  flutter::BinaryMessenger* messenger =
      flutter_controller_->engine()->messenger();
  system_channel_ = std::make_unique<dj::DjSystemChannel>(messenger);
  screen_channel_ = std::make_unique<dj::DjScreenChannel>(messenger);
  cursor_channel_ = std::make_unique<dj::DjCursorChannel>(messenger);
  input_channel_ = std::make_unique<dj::DjInputChannel>(messenger);
  voice_channel_ = std::make_unique<dj::DjVoiceChannel>(messenger);
  // Global hotkey (Ctrl+Alt+D by default, registered from Dart). It
  // registers against this window, so it must be created here, after
  // Win32Window::OnCreate gave the window a handle.
  hotkey_channel_ =
      std::make_unique<dj::DjHotkeyChannel>(messenger, GetHandle());
  // Privacy Screen in-memory webcam capture (Media Foundation). The
  // capture thread posts its reply message to this window; the message
  // handler routes it in MessageHandler below.
  RegisterDjCameraChannel(messenger, GetHandle());

  // DJ system tray. Created only when a tray-icon file exists
  // (dj_tray.cpp); otherwise closing the window quits the app.
  tray_ = std::make_unique<dj::DjTray>(
      GetHandle(),
      [this]() { this->ShowWindow(); },
      [this]() {
        is_quitting_ = true;
        this->Destroy();
      });
  tray_->Create();

  // Show the window immediately on launch. The first-frame callback
  // above also calls Show(), but if the first Flutter frame is
  // delayed (slow plugin init, slow first build) the window would
  // otherwise stay hidden with no way to open it. Showing here
  // guarantees the window appears; the first frame paints into it
  // when ready. This is the v1.2.5 fix for "app runs, no window".
  this->Show();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Destroy the tray icon first (before-quit), then the channels (each
  // unregisters its MethodChannel handler), then the Flutter controller.
  // This order matters: the messenger must still exist while the channels
  // unregister themselves.
  if (tray_) {
    tray_->Destroy();
    tray_ = nullptr;
  }
  // Hotkey first: its destructor unregisters the hotkey from the window.
  hotkey_channel_ = nullptr;
  // Privacy camera: stop the capture thread before the engine is torn
  // down, so no reply can arrive after the messenger is gone.
  ShutdownDjCamera();
  voice_channel_ = nullptr;
  input_channel_ = nullptr;
  cursor_channel_ = nullptr;
  screen_channel_ = nullptr;
  system_channel_ = nullptr;

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::ShowWindow() {
  HWND handle = GetHandle();
  if (handle == nullptr) {
    return;
  }
  ::ShowWindow(handle, SW_RESTORE);
  ::ShowWindow(handle, SW_SHOW);
  ::SetForegroundWindow(handle);
  ::SetFocus(handle);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Tray icon clicks and the "Open DJ" / "Quit DJ" menu.
  if (tray_ && tray_->HandleMessage(hwnd, message, wparam, lparam)) {
    return 0;
  }

  // Global hotkey. RegisterHotKey delivers WM_HOTKEY to this window even
  // when DJ is not focused; the channel notifies Dart ("onHotkeyPressed").
  if (hotkey_channel_ &&
      hotkey_channel_->HandleMessage(hwnd, message, wparam, lparam)) {
    return 0;
  }

  // Privacy Screen camera replies. The capture thread posts
  // kDjCameraDoneMessage when a method reply is ready; delivering it
  // here (platform thread) hands the result back to Dart.
  if (HandleDjCameraMessage(message)) {
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;

    case WM_CLOSE:
      // Close = hide into the tray while the tray exists (Electron rule,
      // PORTING-SPEC §1.8). Only a real quit (tray "Quit DJ", which sets
      // is_quitting_) or no tray at all lets the window close.
      if (tray_ && tray_->IsActive() && !is_quitting_) {
        ::ShowWindow(hwnd, SW_HIDE);
        if (system_channel_) {
          // Dart owns the "show the tray note once" flag.
          system_channel_->NotifyTrayHidden();
        }
        return 0;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
