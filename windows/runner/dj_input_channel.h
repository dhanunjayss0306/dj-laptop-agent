// DJ real input channel (Windows SendInput).
//
// MethodChannel "com.dhanunjay.dj/input": moveMouse(x, y), click(button),
// typeText(text), pressKey(key).
//
// SAFETY — the native side does exactly what Dart asks and nothing more.
// There is no step limit, no stuck detection, and no show-before-click
// rule here. All of that lives in Dart, in the caller, which must show the
// fake cursor first (com.dhanunjay.dj/cursor), cap automated steps, and
// never drive input into a password prompt or password manager. This file
// deliberately contains no foreground-window checks.
//
// Win32 APIs used: SendInput (MOUSEINPUT with MOUSEEVENTF_ABSOLUTE |
// MOUSEEVENTF_MOVE, normalized 0-65535 over the virtual screen;
// MOUSEEVENTF_LEFTDOWN/UP, RIGHTDOWN/UP, MIDDLEDOWN/UP; KEYBDINPUT with
// KEYEVENTF_UNICODE for typing, KEYEVENTF_KEYUP for release),
// GetSystemMetrics (SM_XVIRTUALSCREEN / SM_YVIRTUALSCREEN /
// SM_CXVIRTUALSCREEN / SM_CYVIRTUALSCREEN), MapVirtualKeyW,
// VkKeyScanW (single characters).

#ifndef RUNNER_DJ_INPUT_CHANNEL_H_
#define RUNNER_DJ_INPUT_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>

#include <memory>

namespace dj {

class DjInputChannel {
 public:
  explicit DjInputChannel(flutter::BinaryMessenger* messenger);
  ~DjInputChannel();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  flutter::MethodChannel<flutter::EncodableValue> channel_;
};

}  // namespace dj

#endif  // RUNNER_DJ_INPUT_CHANNEL_H_
