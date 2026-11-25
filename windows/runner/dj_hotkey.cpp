// DJ global hotkey (Windows). See dj_hotkey.h.

#include "dj_hotkey.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cctype>
#include <utility>

#include "dj_channel_utils.h"

namespace dj {
namespace {

// "ctrl"/"control" -> MOD_CONTROL, "alt" -> MOD_ALT, "shift" -> MOD_SHIFT,
// "win"/"windows" -> MOD_WIN. Case-insensitive; unknown names are ignored
// (Dart only ever sends the four documented names).
UINT ModifiersFromNames(const std::vector<std::string>& names) {
  UINT modifiers = 0;
  for (const std::string& raw : names) {
    std::string name = raw;
    std::transform(name.begin(), name.end(), name.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    if (name == "ctrl" || name == "control") {
      modifiers |= MOD_CONTROL;
    } else if (name == "alt") {
      modifiers |= MOD_ALT;
    } else if (name == "shift") {
      modifiers |= MOD_SHIFT;
    } else if (name == "win" || name == "windows") {
      modifiers |= MOD_WIN;
    }
  }
  return modifiers;
}

}  // namespace

DjHotkeyChannel::DjHotkeyChannel(flutter::BinaryMessenger* messenger,
                                 HWND hwnd)
    : channel_(messenger, "com.dhanunjay.dj/hotkey",
               &flutter::StandardMethodCodec::GetInstance()),
      hwnd_(hwnd) {
  channel_.SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

DjHotkeyChannel::~DjHotkeyChannel() {
  // Unregister first: a hotkey left registered after the window is gone
  // would keep firing WM_HOTKEY at a dead window. Then unregister the
  // MethodChannel handler so a late Dart call cannot reach a dead object.
  Unregister();
  UnregisterPrivacy();
  channel_.SetMethodCallHandler(nullptr);
}

bool DjHotkeyChannel::HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                                    LPARAM lparam) {
  if (message != WM_HOTKEY || hwnd != hwnd_) {
    return false;
  }
  const int id = static_cast<int>(wparam);
  if (id == kHotkeyId && registered_) {
    // Fire-and-forget, mirroring DjSystemChannel::NotifyTrayHidden: Dart
    // owns the Stream (HotkeyChannel.onHotkeyPressed) and decides what the
    // press does (default: show/focus the DJ window).
    channel_.InvokeMethod(
        "onHotkeyPressed",
        std::make_unique<flutter::EncodableValue>(flutter::EncodableValue(
            flutter::EncodableMap{})));
    return true;
  }
  if (id == kPrivacyHotkeyId && privacy_registered_) {
    // Privacy Screen override (Ctrl+Alt+P): Dart owns the Stream
    // (HotkeyChannel.onPrivacyHotkeyPressed) and toggles the override.
    channel_.InvokeMethod(
        "onPrivacyHotkeyPressed",
        std::make_unique<flutter::EncodableValue>(flutter::EncodableValue(
            flutter::EncodableMap{})));
    return true;
  }
  return false;
}

void DjHotkeyChannel::Unregister() {
  if (registered_ && hwnd_ != nullptr) {
    ::UnregisterHotKey(hwnd_, kHotkeyId);
  }
  registered_ = false;
}

void DjHotkeyChannel::UnregisterPrivacy() {
  if (privacy_registered_ && hwnd_ != nullptr) {
    ::UnregisterHotKey(hwnd_, kPrivacyHotkeyId);
  }
  privacy_registered_ = false;
}

void DjHotkeyChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();

  // Registers one hotkey id with the given modifiers/vk. On failure the
  // reply is {"ok": false, "message": ...} and nothing is left
  // registered under that id. Shared by registerHotkey (id 1) and
  // registerPrivacyHotkey (id 2).
  auto register_one = [this](int id, bool* registered_flag,
                             const std::vector<std::string>& modifiers,
                             int64_t vk,
                             std::unique_ptr<flutter::MethodResult<
                                 flutter::EncodableValue>> result) {
    if (hwnd_ == nullptr) {
      result->Success(Err("registerHotkey needs a window to attach to."));
      return;
    }
    if (vk <= 0 || vk > 255) {
      result->Success(
          Err("registerHotkey needs a 'vk' virtual-key code (1-255)."));
      return;
    }
    if (*registered_flag) {
      ::UnregisterHotKey(hwnd_, id);
      *registered_flag = false;
    }
    const UINT flags = ModifiersFromNames(modifiers) | MOD_NOREPEAT;
    // MOD_NOREPEAT: no repeat WM_HOTKEY while the keys are held down;
    // one press is one Dart event.
    if (::RegisterHotKey(hwnd_, id, flags, static_cast<UINT>(vk)) == FALSE) {
      const DWORD error = ::GetLastError();
      if (error == ERROR_HOTKEY_ALREADY_REGISTERED) {
        result->Success(Err("hotkey already in use — pick another"));
      } else {
        result->Success(
            Err("Could not register hotkey: " + LastErrorMessage()));
      }
      return;
    }
    *registered_flag = true;
    result->Success(Ok());
  };

  if (method == "registerHotkey") {
    std::vector<std::string> modifiers;
    int64_t vk = 0;
    if (!GetStringListArg(call, "modifiers", &modifiers) ||
        !GetIntArg(call, "vk", &vk)) {
      result->Success(
          Err("registerHotkey needs a 'modifiers' list of strings and "
              "an integer 'vk' virtual-key code."));
      return;
    }
    // One main hotkey at a time: a new registration replaces the old one.
    register_one(kHotkeyId, &registered_, modifiers, vk, std::move(result));
    return;
  }

  if (method == "unregisterHotkey") {
    // Unregistering when nothing is registered is fine, not an error.
    Unregister();
    result->Success(Ok());
    return;
  }

  if (method == "registerPrivacyHotkey") {
    std::vector<std::string> modifiers;
    int64_t vk = 0;
    if (!GetStringListArg(call, "modifiers", &modifiers) ||
        !GetIntArg(call, "vk", &vk)) {
      result->Success(
          Err("registerPrivacyHotkey needs a 'modifiers' list of strings "
              "and an integer 'vk' virtual-key code."));
      return;
    }
    // Independent id: registering the override never replaces Ctrl+Alt+D.
    register_one(kPrivacyHotkeyId, &privacy_registered_, modifiers, vk,
                 std::move(result));
    return;
  }

  if (method == "unregisterPrivacyHotkey") {
    // Unregistering when nothing is registered is fine, not an error.
    UnregisterPrivacy();
    result->Success(Ok());
    return;
  }

  result->Success(Err("Unknown hotkey method: " + method + "."));
}

}  // namespace dj
