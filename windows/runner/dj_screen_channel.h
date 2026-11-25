// DJ screen capture channel (Windows).
//
// MethodChannel "com.dhanunjay.dj/screen", method captureScreen.
// Captures the full virtual desktop (all monitors) to PNG bytes using
// Win32 BitBlt from the desktop DC, encoded with GDI+.
//
// Win32 APIs used: GetSystemMetrics (SM_XVIRTUALSCREEN / SM_YVIRTUALSCREEN /
// SM_CXVIRTUALSCREEN / SM_CYVIRTUALSCREEN), GetDC(NULL), CreateCompatibleDC,
// CreateCompatibleBitmap, BitBlt (SRCCOPY), EnumDisplayMonitors +
// GetMonitorInfoW (monitor bounds), Gdiplus::Bitmap + PNG encoder via
// GetImageEncoders (IStream on a global memory block).
//
// Returns {"ok": true, "png": Uint8List, "width": int, "height": int,
// "monitors": [{"x","y","width","height","isPrimary"}]}.
// v1 is full-screen only; no region cropping.

#ifndef RUNNER_DJ_SCREEN_CHANNEL_H_
#define RUNNER_DJ_SCREEN_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>

#include <windows.h>

#include <memory>

namespace dj {

class DjScreenChannel {
 public:
  explicit DjScreenChannel(flutter::BinaryMessenger* messenger);
  ~DjScreenChannel();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  flutter::MethodChannel<flutter::EncodableValue> channel_;
  ULONG_PTR gdiplus_token_ = 0;
};

}  // namespace dj

#endif  // RUNNER_DJ_SCREEN_CHANNEL_H_
