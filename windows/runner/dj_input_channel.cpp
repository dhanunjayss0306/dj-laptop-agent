// DJ real input channel (Windows SendInput). See dj_input_channel.h.
//
// Safety note (also in the header and in lib/platform/input_channel.dart):
// this file performs exactly the input Dart requests. Step limits, stuck
// detection, show-before-click, and keeping input away from password
// prompts are the Dart caller's job, not this file's.

#include "dj_input_channel.h"

#include <flutter/standard_method_codec.h>

#include <windows.h>

#include <algorithm>
#include <cctype>
#include <map>
#include <string>
#include <utility>
#include <vector>

#include "dj_channel_utils.h"

namespace dj {
namespace {

// Lowercases an ASCII string (key names are matched case-insensitively).
std::string LowerAscii(std::string s) {
  std::transform(s.begin(), s.end(), s.begin(),
                 [](unsigned char c) { return std::tolower(c); });
  return s;
}

std::string Trim(const std::string& s) {
  const size_t first = s.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) {
    return std::string();
  }
  const size_t last = s.find_last_not_of(" \t\r\n");
  return s.substr(first, last - first + 1);
}

std::vector<std::string> SplitPlus(const std::string& s) {
  std::vector<std::string> parts;
  size_t start = 0;
  while (true) {
    const size_t plus = s.find('+', start);
    if (plus == std::string::npos) {
      parts.push_back(Trim(s.substr(start)));
      break;
    }
    parts.push_back(Trim(s.substr(start, plus - start)));
    start = plus + 1;
  }
  return parts;
}

// Named (non-character) keys -> virtual-key codes.
const std::map<std::string, WORD>& NamedKeys() {
  static const std::map<std::string, WORD> keys = {
      {"enter", VK_RETURN},     {"return", VK_RETURN},
      {"escape", VK_ESCAPE},    {"esc", VK_ESCAPE},
      {"tab", VK_TAB},
      {"space", VK_SPACE},      {"spacebar", VK_SPACE},
      {"backspace", VK_BACK},   {"back", VK_BACK},
      {"delete", VK_DELETE},    {"del", VK_DELETE},
      {"insert", VK_INSERT},    {"ins", VK_INSERT},
      {"home", VK_HOME},        {"end", VK_END},
      {"pageup", VK_PRIOR},     {"pagedown", VK_NEXT},
      {"up", VK_UP},            {"down", VK_DOWN},
      {"left", VK_LEFT},        {"right", VK_RIGHT},
      {"f1", VK_F1},            {"f2", VK_F2},
      {"f3", VK_F3},            {"f4", VK_F4},
      {"f5", VK_F5},            {"f6", VK_F6},
      {"f7", VK_F7},            {"f8", VK_F8},
      {"f9", VK_F9},            {"f10", VK_F10},
      {"f11", VK_F11},          {"f12", VK_F12},
      {"win", VK_LWIN},         {"windows", VK_LWIN},
      {"menu", VK_APPS},        {"apps", VK_APPS},
      {"printscreen", VK_SNAPSHOT},
      {"capslock", VK_CAPITAL},
      {"numlock", VK_NUMLOCK},
      {"scrolllock", VK_SCROLL},
  };
  return keys;
}

bool SendKey(WORD vk, bool key_up) {
  INPUT input{};
  input.type = INPUT_KEYBOARD;
  input.ki.wVk = vk;
  input.ki.wScan = static_cast<WORD>(
      ::MapVirtualKeyW(vk, MAPVK_VK_TO_VSC));
  input.ki.dwFlags = key_up ? KEYEVENTF_KEYUP : 0;
  return ::SendInput(1, &input, sizeof(INPUT)) == 1;
}

// Presses one key name, optionally with modifiers ("Ctrl+C", "Alt+Tab",
// "Win", "Shift+F10"). Returns false for an unknown key name.
// A lone modifier ("Ctrl", "Alt", "Shift", "Win") presses and releases it.
bool PressKeyName(const std::string& raw_key) {
  const std::vector<std::string> parts = SplitPlus(raw_key);
  if (parts.empty()) {
    return false;
  }
  std::vector<WORD> modifiers;
  std::string final_key;
  for (const std::string& part : parts) {
    const std::string name = LowerAscii(part);
    if (name == "ctrl" || name == "control") {
      modifiers.push_back(VK_CONTROL);
    } else if (name == "alt") {
      modifiers.push_back(VK_MENU);
    } else if (name == "shift") {
      modifiers.push_back(VK_SHIFT);
    } else if (name == "win" || name == "windows") {
      modifiers.push_back(VK_LWIN);
    } else {
      final_key = name;
    }
  }
  if (final_key.empty()) {
    // Lone modifier(s): tap each one.
    if (modifiers.empty()) {
      return false;
    }
    for (WORD mod : modifiers) {
      if (!SendKey(mod, false) || !SendKey(mod, true)) {
        return false;
      }
    }
    return true;
  }
  WORD vk = 0;
  const auto& named = NamedKeys();
  const auto it = named.find(final_key);
  if (it != named.end()) {
    vk = it->second;
  } else if (final_key.size() == 1) {
    // Single character: VkKeyScanW gives the virtual key for the current
    // keyboard layout (e.g. 'a' -> 'A', '1' -> '1'). Shift state from
    // VkKeyScanW is ignored; the caller should pass Shift explicitly.
    const SHORT scan = ::VkKeyScanW(WideFromUtf8(final_key)[0]);
    if (scan == -1) {
      return false;
    }
    vk = static_cast<WORD>(LOBYTE(scan));
  } else {
    return false;  // Unknown key name.
  }
  for (WORD mod : modifiers) {
    if (!SendKey(mod, false)) {
      return false;
    }
  }
  const bool down_ok = SendKey(vk, false);
  const bool up_ok = SendKey(vk, true);
  for (auto rit = modifiers.rbegin(); rit != modifiers.rend(); ++rit) {
    SendKey(*rit, true);
  }
  return down_ok && up_ok;
}

// Moves the mouse to virtual-screen pixel (x, y), normalized to 0-65535
// as SendInput requires for MOUSEEVENTF_ABSOLUTE.
bool MoveMouseAbsolute(int x, int y) {
  const int vx = ::GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int vy = ::GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int vw = ::GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int vh = ::GetSystemMetrics(SM_CYVIRTUALSCREEN);
  if (vw <= 1 || vh <= 1) {
    return false;
  }
  const LONG norm_x = static_cast<LONG>(
      (static_cast<int64_t>(x - vx) * 65535) / (vw - 1));
  const LONG norm_y = static_cast<LONG>(
      (static_cast<int64_t>(y - vy) * 65535) / (vh - 1));
  INPUT input{};
  input.type = INPUT_MOUSE;
  input.mi.dx = std::clamp<LONG>(norm_x, 0, 65535);
  input.mi.dy = std::clamp<LONG>(norm_y, 0, 65535);
  input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE;
  return ::SendInput(1, &input, sizeof(INPUT)) == 1;
}

bool ClickButton(const std::string& button) {
  DWORD down = 0;
  DWORD up = 0;
  if (button == "left") {
    down = MOUSEEVENTF_LEFTDOWN;
    up = MOUSEEVENTF_LEFTUP;
  } else if (button == "right") {
    down = MOUSEEVENTF_RIGHTDOWN;
    up = MOUSEEVENTF_RIGHTUP;
  } else if (button == "middle") {
    down = MOUSEEVENTF_MIDDLEDOWN;
    up = MOUSEEVENTF_MIDDLEUP;
  } else {
    return false;
  }
  INPUT inputs[2]{};
  inputs[0].type = INPUT_MOUSE;
  inputs[0].mi.dwFlags = down;
  inputs[1].type = INPUT_MOUSE;
  inputs[1].mi.dwFlags = up;
  return ::SendInput(2, inputs, sizeof(INPUT)) == 2;
}

}  // namespace

DjInputChannel::DjInputChannel(flutter::BinaryMessenger* messenger)
    : channel_(messenger, "com.dhanunjay.dj/input",
               &flutter::StandardMethodCodec::GetInstance()) {
  channel_.SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

DjInputChannel::~DjInputChannel() {
  // Unregister first: destroying the MethodChannel does not unregister
  // the handler, and a late Dart call must not reach a dead object.
  channel_.SetMethodCallHandler(nullptr);
}

void DjInputChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();

  if (method == "moveMouse") {
    int64_t x = 0;
    int64_t y = 0;
    if (!GetIntArg(call, "x", &x) || !GetIntArg(call, "y", &y)) {
      result->Success(Err("moveMouse needs integer 'x' and 'y'."));
      return;
    }
    if (!MoveMouseAbsolute(static_cast<int>(x), static_cast<int>(y))) {
      result->Success(Err("Could not move the mouse."));
      return;
    }
    result->Success(Ok());
    return;
  }

  if (method == "click") {
    std::string button = "left";
    GetStringArg(call, "button", &button);  // Optional; default left.
    if (!ClickButton(LowerAscii(button))) {
      result->Success(
          Err("Unknown mouse button '" + button +
              "'. Use 'left', 'right', or 'middle'."));
      return;
    }
    result->Success(Ok());
    return;
  }

  if (method == "typeText") {
    std::string text;
    if (!GetStringArg(call, "text", &text)) {
      result->Success(Err("typeText needs a 'text' string."));
      return;
    }
    const std::wstring wide = WideFromUtf8(text);
    bool ok = true;
    for (wchar_t ch : wide) {
      INPUT input{};
      input.type = INPUT_KEYBOARD;
      input.ki.wScan = static_cast<WORD>(ch);
      input.ki.dwFlags = KEYEVENTF_UNICODE;
      if (::SendInput(1, &input, sizeof(INPUT)) != 1) {
        ok = false;
        break;
      }
      INPUT release = input;
      release.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
      if (::SendInput(1, &release, sizeof(INPUT)) != 1) {
        ok = false;
        break;
      }
    }
    if (!ok) {
      result->Success(Err("Typing failed part-way through the text."));
      return;
    }
    result->Success(Ok());
    return;
  }

  if (method == "pressKey") {
    std::string key;
    if (!GetStringArg(call, "key", &key) || Trim(key).empty()) {
      result->Success(Err("pressKey needs a 'key' string."));
      return;
    }
    if (!PressKeyName(key)) {
      result->Success(Err("Unknown key '" + key +
                          "'. See windows/README-DJ.md for the key list."));
      return;
    }
    result->Success(Ok());
    return;
  }

  result->Success(Err("Unknown input method: " + method + "."));
}

}  // namespace dj
