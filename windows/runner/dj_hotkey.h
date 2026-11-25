// DJ global hotkey (Windows).
//
// MethodChannel "com.dhanunjay.dj/hotkey": registerHotkey(modifiers, vk),
// unregisterHotkey().
//
// A system-wide hotkey via Win32 RegisterHotKey on the runner window.
// WM_HOTKEY arrives on that window even when DJ is not the focused window
// (that is the whole point of a global hotkey); FlutterWindow routes it
// here (see DjHotkeyChannel::HandleMessage) and this channel invokes the
// Dart method "onHotkeyPressed" (see lib/platform/hotkey_channel.dart).
//
// Default hotkey is Ctrl+Alt+D (modifiers ["ctrl", "alt"], vk 0x44 'D'),
// set by the Dart wrapper's defaults; the native side registers exactly
// what Dart asks for and keeps no default of its own. Only one hotkey is
// held at a time: registering a new one replaces the old one.
//
// If the hotkey is already taken by another app, registration fails with
// {"ok": false, "message": "hotkey already in use — pick another"}.
// DJ never steals another app's hotkey and never crashes on failure.
// The hotkey is unregistered when this channel is destroyed (window
// destroy) and when unregisterHotkey() is called.

#ifndef RUNNER_DJ_HOTKEY_CHANNEL_H_
#define RUNNER_DJ_HOTKEY_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>
#include <vector>
#include <windows.h>

namespace dj {

class DjHotkeyChannel {
 public:
  // |hwnd| is the runner window RegisterHotKey registers against; WM_HOTKEY
  // is delivered to that window's procedure. Must be a valid window
  // handle (FlutterWindow passes GetHandle() after OnCreate).
  DjHotkeyChannel(flutter::BinaryMessenger* messenger, HWND hwnd);
  ~DjHotkeyChannel();

  // Routes a window message from FlutterWindow::MessageHandler. Returns
  // true when it was WM_HOTKEY for DJ's hotkey (handled: Dart notified
  // via "onHotkeyPressed"); false for anything else.
  bool HandleMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Unregisters the hotkey if one is registered. No reply, no failure.
  void Unregister();

  flutter::MethodChannel<flutter::EncodableValue> channel_;
  HWND hwnd_ = nullptr;
  bool registered_ = false;
  // Single hotkey id: only one hotkey is held at a time.
  static constexpr int kHotkeyId = 1;
};

}  // namespace dj

#endif  // RUNNER_DJ_HOTKEY_CHANNEL_H_
