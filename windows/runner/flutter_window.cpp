#include "flutter_window.h"

#include <optional>
#include <string>

#include "dj_startup_log.h"
#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  dj::DjLogStartup("OnCreate started");
  if (!Win32Window::OnCreate()) {
    dj::DjLogStartup("OnCreate: Win32Window::OnCreate failed");
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    dj::DjLogStartup("OnCreate: FlutterViewController has no engine/view");
    return false;
  }
  dj::DjLogStartup("engine created");
  RegisterPlugins(flutter_controller_->engine());
  dj::DjLogStartup("plugins registered");
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // First-frame fallback label: a plain native label over the client
  // area, shown until the engine paints its first frame. If Dart is
  // slow (or the renderer never delivers a frame) the window shows
  // "DJ is starting..." instead of blank white, while the message
  // loop keeps running underneath, so minimize/close still work.
  // Hidden (not destroyed) by the first-frame callback below; the
  // window itself is destroyed in OnDestroy.
  starting_label_ = ::CreateWindowExW(
      0, L"STATIC", L"DJ is starting...",
      WS_CHILD | WS_VISIBLE | SS_CENTER | SS_CENTERIMAGE, frame.left,
      frame.top, frame.right - frame.left, frame.bottom - frame.top,
      GetHandle(), nullptr, GetModuleHandle(nullptr), nullptr);

  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    first_frame_seen_.store(true);
    // Hide the fallback label; OnDestroy destroys the window. Only
    // hide here (not destroy): the callback may run on a non-UI
    // thread, and ShowWindow is safe cross-thread.
    if (starting_label_ != nullptr) {
      ::ShowWindow(starting_label_, SW_HIDE);
    }
    dj::DjLogStartup("first frame rendered");
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
  dj::DjLogStartup("native channels created");
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
  dj::DjLogStartup("window shown (OnCreate done)");

  // First-frame watchdog: a background thread (never the UI thread)
  // that logs if the first frame is late and probes whether the
  // platform thread is still pumping messages. It only writes to the
  // log; it never touches the engine.
  //
  // NOTE: first_frame_seen_ is NOT reset here. The member initializer
  // already sets it false, and the first-frame callback (registered
  // above, possibly already fired by ForceRedraw) sets it true.
  // Resetting it now would erase a frame that already arrived and
  // make the watchdog log a false "no first frame".
  stop_watchdog_.store(false);
  const DWORD started_tick = ::GetTickCount();
  const HWND window_handle = GetHandle();
  watchdog_thread_ = std::thread([this, window_handle, started_tick]() {
    WatchdogLoop(window_handle, started_tick);
  });

  return true;
}

void FlutterWindow::LayoutStartingLabel() {
  if (starting_label_ == nullptr) {
    return;
  }
  RECT frame = GetClientArea();
  ::MoveWindow(starting_label_, frame.left, frame.top,
               frame.right - frame.left, frame.bottom - frame.top, TRUE);
}

void FlutterWindow::WatchdogLoop(HWND window, DWORD started_tick) {
  // Probe cadence: first check at 5 s, then every 15 s until the
  // first frame arrives or the window is destroyed.
  bool logged_5s = false;
  for (;;) {
    std::this_thread::sleep_for(std::chrono::seconds(1));
    if (stop_watchdog_.load() || first_frame_seen_.load()) {
      return;
    }
    const DWORD elapsed = ::GetTickCount() - started_tick;
    const bool due = (!logged_5s && elapsed >= 5000) ||
                     (logged_5s && elapsed % 15000 < 1000);
    if (!due) {
      continue;
    }
    logged_5s = true;
    // Is the platform thread alive? SendMessageTimeout to our own
    // window: it answers only if the message loop is pumping. A
    // timeout here proves the platform thread is hung (native stall);
    // a fast answer with no first frame proves the stall is on the
    // Dart/renderer side instead.
    DWORD_PTR reply = 0;
    const LRESULT rc = ::SendMessageTimeoutW(
        window, WM_NULL, 0, 0, SMTO_ABORTIFHUNG, 2000, &reply);
    std::string line = "WATCHDOG: no first frame after " +
                       std::to_string(elapsed / 1000) +
                       "s; platform thread ";
    line += (rc == 0) ? "NOT RESPONDING to WM_NULL (native stall)"
                      : "responsive (stall is Dart/renderer side)";
    dj::DjLogStartup(line.c_str());
  }
}

void FlutterWindow::OnDestroy() {
  // Stop the first-frame watchdog first: it only reads atomics and
  // the window handle, but it must not outlive this object. The
  // SendMessageTimeout probe inside it returns within 2 s even if
  // the platform thread is hung, so the join below is bounded.
  stop_watchdog_.store(true);
  if (watchdog_thread_.joinable()) {
    watchdog_thread_.join();
  }
  if (starting_label_ != nullptr) {
    ::DestroyWindow(starting_label_);
    starting_label_ = nullptr;
  }
  dj::DjLogStartup("OnDestroy: window closing");
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
  // Keep the "starting..." fallback label covering the client area
  // while the first frame is still missing. Handled first, before
  // Flutter sees the message, so a resize never leaves it misplaced.
  if (message == WM_SIZE) {
    LayoutStartingLabel();
  }
  // The fallback label paints white with ink text (design law),
  // not the grey default for a STATIC control.
  if (message == WM_CTLCOLORSTATIC && starting_label_ != nullptr &&
      reinterpret_cast<HWND>(lparam) == starting_label_) {
    const HDC dc = reinterpret_cast<HDC>(wparam);
    ::SetTextColor(dc, RGB(0x1D, 0x1D, 0x1F));
    ::SetBkColor(dc, RGB(0xFF, 0xFF, 0xFF));
    static const HBRUSH white_brush =
        ::CreateSolidBrush(RGB(0xFF, 0xFF, 0xFF));
    return reinterpret_cast<LRESULT>(white_brush);
  }

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
