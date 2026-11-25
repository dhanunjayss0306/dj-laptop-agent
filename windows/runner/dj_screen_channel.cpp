// DJ screen capture channel (Windows). See dj_screen_channel.h.

#include "dj_screen_channel.h"

#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <gdiplus.h>

#include <cstdint>
#include <vector>

#include "dj_channel_utils.h"

namespace dj {
namespace {

// Finds the CLSID of the PNG image encoder. Returns false when not found.
bool GetPngEncoderClsid(CLSID* clsid) {
  UINT num_encoders = 0;
  UINT size = 0;
  if (::Gdiplus::GetImageEncodersSize(&num_encoders, &size) !=
          ::Gdiplus::Ok ||
      size == 0) {
    return false;
  }
  std::vector<uint8_t> buffer(size);
  ::Gdiplus::ImageCodecInfo* encoders =
      reinterpret_cast<::Gdiplus::ImageCodecInfo*>(buffer.data());
  if (::Gdiplus::GetImageEncoders(num_encoders, size, encoders) !=
      ::Gdiplus::Ok) {
    return false;
  }
  for (UINT i = 0; i < num_encoders; ++i) {
    if (std::wstring(encoders[i].MimeType) == L"image/png") {
      *clsid = encoders[i].Clsid;
      return true;
    }
  }
  return false;
}

struct MonitorInfo {
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
  bool is_primary = false;
};

BOOL CALLBACK CollectMonitor(HMONITOR monitor, HDC /*dc*/, LPRECT /*rect*/,
                             LPARAM data) {
  auto* monitors = reinterpret_cast<std::vector<MonitorInfo>*>(data);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (::GetMonitorInfoW(monitor, &info)) {
    MonitorInfo entry;
    entry.x = static_cast<int>(info.rcMonitor.left);
    entry.y = static_cast<int>(info.rcMonitor.top);
    entry.width =
        static_cast<int>(info.rcMonitor.right - info.rcMonitor.left);
    entry.height =
        static_cast<int>(info.rcMonitor.bottom - info.rcMonitor.top);
    entry.is_primary = (info.dwFlags & MONITORINFOF_PRIMARY) != 0;
    monitors->push_back(entry);
  }
  return TRUE;
}

}  // namespace

DjScreenChannel::DjScreenChannel(flutter::BinaryMessenger* messenger)
    : channel_(messenger, "com.dhanunjay.dj/screen",
               &flutter::StandardMethodCodec::GetInstance()) {
  ::Gdiplus::GdiplusStartupInput startup_input;
  ::Gdiplus::GdiplusStartup(&gdiplus_token_, &startup_input, nullptr);
  channel_.SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

DjScreenChannel::~DjScreenChannel() {
  // Unregister first: destroying the MethodChannel does not unregister
  // the handler, and a late Dart call must not reach a dead object.
  channel_.SetMethodCallHandler(nullptr);
  if (gdiplus_token_ != 0) {
    ::Gdiplus::GdiplusShutdown(gdiplus_token_);
    gdiplus_token_ = 0;
  }
}

void DjScreenChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() != "captureScreen") {
    result->Success(Err("Unknown screen method: " + call.method_name() + "."));
    return;
  }

  const int vx = ::GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int vy = ::GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int vw = ::GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int vh = ::GetSystemMetrics(SM_CYVIRTUALSCREEN);
  if (vw <= 0 || vh <= 0) {
    result->Success(Err("Could not read the screen size."));
    return;
  }

  const HDC screen_dc = ::GetDC(nullptr);
  if (screen_dc == nullptr) {
    result->Success(Err("Could not get the desktop device context."));
    return;
  }
  const HDC mem_dc = ::CreateCompatibleDC(screen_dc);
  const HBITMAP bitmap =
      ::CreateCompatibleBitmap(screen_dc, vw, vh);
  if (mem_dc == nullptr || bitmap == nullptr) {
    if (mem_dc != nullptr) {
      ::DeleteDC(mem_dc);
    }
    if (bitmap != nullptr) {
      ::DeleteObject(bitmap);
    }
    ::ReleaseDC(nullptr, screen_dc);
    result->Success(Err("Could not create the capture bitmap."));
    return;
  }
  const HGDIOBJ old_bitmap = ::SelectObject(mem_dc, bitmap);
  const BOOL blitted = ::BitBlt(mem_dc, 0, 0, vw, vh, screen_dc, vx, vy,
                                SRCCOPY);
  ::SelectObject(mem_dc, old_bitmap);
  ::DeleteDC(mem_dc);
  ::ReleaseDC(nullptr, screen_dc);
  if (!blitted) {
    ::DeleteObject(bitmap);
    result->Success(Err("Screen capture failed (" + LastErrorMessage() + ")."));
    return;
  }

  // Encode the bitmap as PNG into memory with GDI+.
  CLSID png_clsid{};
  if (!GetPngEncoderClsid(&png_clsid)) {
    ::DeleteObject(bitmap);
    result->Success(Err("No PNG encoder is available on this system."));
    return;
  }
  ::Gdiplus::Bitmap image(bitmap, nullptr);
  IStream* stream = nullptr;
  if (::CreateStreamOnHGlobal(nullptr, TRUE, &stream) != S_OK ||
      stream == nullptr) {
    ::DeleteObject(bitmap);
    result->Success(Err("Could not create the PNG output stream."));
    return;
  }
  const ::Gdiplus::Status save_status = image.Save(stream, &png_clsid, nullptr);
  ::DeleteObject(bitmap);
  if (save_status != ::Gdiplus::Ok) {
    stream->Release();
    result->Success(Err("Could not encode the screenshot as PNG."));
    return;
  }
  HGLOBAL global = nullptr;
  if (::GetHGlobalFromStream(stream, &global) != S_OK || global == nullptr) {
    stream->Release();
    result->Success(Err("Could not read the encoded PNG bytes."));
    return;
  }
  const size_t png_size = ::GlobalSize(global);
  const void* png_data = ::GlobalLock(global);
  std::vector<uint8_t> png_bytes;
  if (png_data != nullptr && png_size > 0) {
    const uint8_t* bytes = static_cast<const uint8_t*>(png_data);
    png_bytes.assign(bytes, bytes + png_size);
    ::GlobalUnlock(global);
  }
  stream->Release();
  if (png_bytes.empty()) {
    result->Success(Err("The screenshot encoded to zero bytes."));
    return;
  }

  std::vector<MonitorInfo> monitors;
  ::EnumDisplayMonitors(nullptr, nullptr, CollectMonitor,
                        reinterpret_cast<LPARAM>(&monitors));
  flutter::EncodableList monitor_list;
  for (const MonitorInfo& monitor : monitors) {
    flutter::EncodableMap entry;
    entry[flutter::EncodableValue("x")] =
        flutter::EncodableValue(static_cast<int32_t>(monitor.x));
    entry[flutter::EncodableValue("y")] =
        flutter::EncodableValue(static_cast<int32_t>(monitor.y));
    entry[flutter::EncodableValue("width")] =
        flutter::EncodableValue(static_cast<int32_t>(monitor.width));
    entry[flutter::EncodableValue("height")] =
        flutter::EncodableValue(static_cast<int32_t>(monitor.height));
    entry[flutter::EncodableValue("isPrimary")] =
        flutter::EncodableValue(monitor.is_primary);
    monitor_list.push_back(flutter::EncodableValue(std::move(entry)));
  }

  flutter::EncodableMap out;
  out[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
  out[flutter::EncodableValue("png")] =
      flutter::EncodableValue(std::move(png_bytes));
  out[flutter::EncodableValue("width")] =
      flutter::EncodableValue(static_cast<int32_t>(vw));
  out[flutter::EncodableValue("height")] =
      flutter::EncodableValue(static_cast<int32_t>(vh));
  out[flutter::EncodableValue("monitors")] =
      flutter::EncodableValue(std::move(monitor_list));
  result->Success(flutter::EncodableValue(std::move(out)));
}

}  // namespace dj
