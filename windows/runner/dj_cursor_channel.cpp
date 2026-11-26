// DJ fake cursor overlay + screen annotations (Windows).
// See dj_cursor_channel.h.

#include "dj_cursor_channel.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <utility>

#include "dj_channel_utils.h"

namespace dj {
namespace {

constexpr const wchar_t kOverlayClassName[] = L"DJ_FAKE_CURSOR_OVERLAY";
// DJ blue #0071E3.
constexpr COLORREF kDjBlue = RGB(0x00, 0x71, 0xE3);
constexpr COLORREF kWhite = RGB(0xFF, 0xFF, 0xFF);
// Cursor-only overlay window size; large enough for the cursor marker plus
// multi-line live caption ("fake lyrics") bubbles.
constexpr int kOverlayWidth = 440;
constexpr int kOverlayHeight = 220;
// Translucent highlight fill: alpha ~70/255 over DJ blue.
constexpr uint32_t kHighlightFill = (70u << 24) | 0x000071E3u;
constexpr COLORREF kCaptionBg = RGB(0x16, 0x16, 0x1A);

void RegisterOverlayClass() {
  static bool registered = false;
  if (registered) {
    return;
  }
  WNDCLASSW wc{};
  wc.lpfnWndProc = DjCursorChannel::OverlayWndProc;
  wc.hInstance = ::GetModuleHandle(nullptr);
  wc.lpszClassName = kOverlayClassName;
  wc.hCursor = ::LoadCursor(nullptr, IDC_ARROW);
  wc.hbrBackground = nullptr;
  ::RegisterClassW(&wc);
  registered = true;
}

// Reads an int field from an annotation map (Dart ints arrive as int32
// or int64). Returns false when the field is missing or not an int.
bool GetMapInt(const flutter::EncodableMap& map, const char* key,
               int64_t* out) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return false;
  }
  if (const int32_t* v32 = std::get_if<int32_t>(&it->second)) {
    *out = *v32;
    return true;
  }
  if (const int64_t* v64 = std::get_if<int64_t>(&it->second)) {
    *out = *v64;
    return true;
  }
  return false;
}

// Reads a string field from an annotation map.
bool GetMapString(const flutter::EncodableMap& map, const char* key,
                  std::string* out) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return false;
  }
  const std::string* value = std::get_if<std::string>(&it->second);
  if (value == nullptr) {
    return false;
  }
  *out = *value;
  return true;
}

// Multi-line rounded caption bubble (Clicky/lyrics style) at (x, y).
void DrawCaptionCard(HDC dc, int x, int y, const std::wstring& text,
                     int max_width, int font_px) {
  if (text.empty()) return;
  HFONT font = ::CreateFontW(font_px, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                            CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                            DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
  const HGDIOBJ old_font = ::SelectObject(dc, font);
  const int pad_x = 12;
  const int pad_y = 8;
  RECT calc_rect{0, 0, max_width - pad_x * 2, 0};
  ::DrawTextW(dc, text.c_str(), static_cast<int>(text.size()), &calc_rect,
              DT_CALCRECT | DT_WORDBREAK | DT_LEFT);
  const int box_w = std::min(max_width, static_cast<int>(calc_rect.right) + pad_x * 2);
  const int box_h = std::min(190, static_cast<int>(calc_rect.bottom) + pad_y * 2);
  const HBRUSH bg_brush = ::CreateSolidBrush(kCaptionBg);
  const HPEN border_pen = ::CreatePen(PS_SOLID, 1, kDjBlue);
  const HGDIOBJ old_brush = ::SelectObject(dc, bg_brush);
  const HGDIOBJ old_pen = ::SelectObject(dc, border_pen);
  ::RoundRect(dc, x, y, x + box_w, y + box_h, 12, 12);
  RECT text_rect{x + pad_x, y + pad_y, x + box_w - pad_x, y + box_h - pad_y};
  ::SetTextColor(dc, kWhite);
  ::DrawTextW(dc, text.c_str(), static_cast<int>(text.size()), &text_rect,
              DT_WORDBREAK | DT_LEFT | DT_END_ELLIPSIS);
  ::SelectObject(dc, old_pen);
  ::SelectObject(dc, old_brush);
  ::SelectObject(dc, old_font);
  ::DeleteObject(font);
  ::DeleteObject(bg_brush);
  ::DeleteObject(border_pen);
}

// Small blue label bubble with white text at (x, y). Caller must have set
// BK mode to TRANSPARENT. Saves and restores every GDI object it selects.
void DrawLabelBubble(HDC dc, int x, int y, const std::wstring& text,
                     int font_px) {
  HFONT font = ::CreateFontW(font_px, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                            CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                            DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
  const HGDIOBJ old_font = ::SelectObject(dc, font);
  SIZE text_size{};
  ::GetTextExtentPoint32W(dc, text.c_str(), static_cast<int>(text.size()),
                          &text_size);
  const int pad_x = 10;
  const int pad_y = 6;
  const int bubble_w = text_size.cx + pad_x * 2;
  const int bubble_h = text_size.cy + pad_y * 2;
  const HBRUSH bubble_brush = ::CreateSolidBrush(kDjBlue);
  const HGDIOBJ old_brush = ::SelectObject(dc, bubble_brush);
  const HGDIOBJ old_pen = ::SelectObject(dc, ::GetStockObject(NULL_PEN));
  ::RoundRect(dc, x, y, x + bubble_w, y + bubble_h, 10, 10);
  ::SetTextColor(dc, kWhite);
  ::TextOutW(dc, x + pad_x, y + pad_y, text.c_str(),
             static_cast<int>(text.size()));
  ::SelectObject(dc, old_pen);
  ::SelectObject(dc, old_brush);
  ::SelectObject(dc, old_font);
  ::DeleteObject(font);
  ::DeleteObject(bubble_brush);
}

}  // namespace

DjCursorChannel::DjCursorChannel(flutter::BinaryMessenger* messenger)
    : channel_(messenger, "com.dhanunjay.dj/cursor",
               &flutter::StandardMethodCodec::GetInstance()) {
  channel_.SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

DjCursorChannel::~DjCursorChannel() {
  // Unregister first: destroying the MethodChannel does not unregister
  // the handler, and a late Dart call must not reach a dead object.
  channel_.SetMethodCallHandler(nullptr);
  StopAnimation();
  StopPulseTimer();
  if (overlay_ != nullptr) {
    ::DestroyWindow(overlay_);
    overlay_ = nullptr;
  }
}

LRESULT CALLBACK DjCursorChannel::OverlayWndProc(HWND hwnd, UINT message,
                                                 WPARAM wparam,
                                                 LPARAM lparam) {
  if (message == WM_TIMER) {
    auto* self = reinterpret_cast<DjCursorChannel*>(
        ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (self != nullptr) {
      if (wparam == kPulseTimerId) {
        self->pulse_tick_ = (self->pulse_tick_ + 1) % 360;
        if (self->visible_ &&
            (self->companion_state_ == CompanionState::kListening ||
             self->companion_state_ == CompanionState::kThinking)) {
          self->DrawOverlay();
        } else {
          self->StopPulseTimer();
        }
        return 0;
      }
      if (self->HasAnnotations()) {
        // Full-screen overlay: the window never moves; the marker is
        // redrawn inside it by DrawOverlay. Never slide the window.
        self->StopAnimation();
      } else {
        const DWORD now = ::GetTickCount();
        const DWORD elapsed = now - self->anim_start_;
        const double linear = std::min(
            1.0, static_cast<double>(elapsed) /
                     static_cast<double>(kAnimDurationMs));
        // Smoothstep easeInOut for Clicky-style Bezier arc flight.
        const double t = linear * linear * (3.0 - 2.0 * linear);
        const double omt = 1.0 - t;
        const int cur_x = static_cast<int>(
            omt * omt * self->from_x_ + 2.0 * omt * t * self->ctrl_x_ +
            t * t * self->x_);
        const int cur_y = static_cast<int>(
            omt * omt * self->from_y_ + 2.0 * omt * t * self->ctrl_y_ +
            t * t * self->y_);
        ::SetWindowPos(hwnd, HWND_TOPMOST, cur_x, cur_y, 0, 0,
                       SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
        if (linear >= 1.0) {
          self->StopAnimation();
        }
      }
    }
    return 0;
  }
  if (message == WM_DESTROY) {
    return 0;
  }
  return ::DefWindowProcW(hwnd, message, wparam, lparam);
}

void DjCursorChannel::EnsureWindow() {
  if (overlay_ != nullptr) {
    return;
  }
  RegisterOverlayClass();
  overlay_ = ::CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
      kOverlayClassName, L"", WS_POPUP, x_, y_, kOverlayWidth, kOverlayHeight,
      nullptr, nullptr, ::GetModuleHandle(nullptr), nullptr);
  if (overlay_ != nullptr) {
    ::SetWindowLongPtrW(overlay_, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(this));
    overlay_w_ = kOverlayWidth;
    overlay_h_ = kOverlayHeight;
  }
}

void DjCursorChannel::EnsureAnnotationWindow() {
  const int vx = ::GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int vy = ::GetSystemMetrics(SM_YVIRTUALSCREEN);
  const int vw = ::GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int vh = ::GetSystemMetrics(SM_CYVIRTUALSCREEN);
  if (overlay_ == nullptr) {
    RegisterOverlayClass();
    overlay_ = ::CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        kOverlayClassName, L"", WS_POPUP, vx, vy, vw, vh, nullptr, nullptr,
        ::GetModuleHandle(nullptr), nullptr);
    if (overlay_ != nullptr) {
      ::SetWindowLongPtrW(overlay_, GWLP_USERDATA,
                          reinterpret_cast<LONG_PTR>(this));
    }
  } else {
    // Same layered window, resized to the whole virtual screen. It stays
    // WS_EX_TRANSPARENT: annotations never intercept clicks.
    ::SetWindowPos(overlay_, HWND_TOPMOST, vx, vy, vw, vh,
                   SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_SHOWWINDOW);
  }
  if (overlay_ != nullptr) {
    overlay_w_ = vw;
    overlay_h_ = vh;
  }
}

void DjCursorChannel::RestoreCursorWindow() {
  if (overlay_ == nullptr) {
    return;
  }
  overlay_w_ = kOverlayWidth;
  overlay_h_ = kOverlayHeight;
  ::SetWindowPos(overlay_, HWND_TOPMOST, x_, y_, kOverlayWidth,
                 kOverlayHeight,
                 SWP_NOACTIVATE | SWP_NOOWNERZORDER |
                     (visible_ ? SWP_SHOWWINDOW : SWP_HIDEWINDOW));
}

void DjCursorChannel::DrawAnnotations(HDC mem_dc, int origin_x,
                                      int origin_y) {
  const HPEN blue_pen = ::CreatePen(PS_SOLID, 3, kDjBlue);
  const HBRUSH blue_brush = ::CreateSolidBrush(kDjBlue);
  const HGDIOBJ old_pen = ::SelectObject(mem_dc, blue_pen);
  const HGDIOBJ old_brush =
      ::SelectObject(mem_dc, ::GetStockObject(NULL_BRUSH));
  for (const Annotation& a : annotations_) {
    switch (a.type) {
      case Annotation::Type::kCircle: {
        const int cx = a.x - origin_x;
        const int cy = a.y - origin_y;
        ::Ellipse(mem_dc, cx - a.r, cy - a.r, cx + a.r, cy + a.r);
        break;
      }
      case Annotation::Type::kArrow: {
        const int x1 = a.x - origin_x;
        const int y1 = a.y - origin_y;
        const int x2 = a.x2 - origin_x;
        const int y2 = a.y2 - origin_y;
        ::MoveToEx(mem_dc, x1, y1, nullptr);
        ::LineTo(mem_dc, x2, y2);
        // Arrowhead: two points behind the tip, ~25 degrees off the line.
        const double angle =
            std::atan2(static_cast<double>(y2 - y1),
                       static_cast<double>(x2 - x1));
        constexpr double kHeadLen = 18.0;
        constexpr double kSpread = 0.436;  // ~25 degrees in radians.
        POINT head[3] = {
            {x2, y2},
            {x2 - static_cast<int>(kHeadLen * std::cos(angle - kSpread)),
             y2 - static_cast<int>(kHeadLen * std::sin(angle - kSpread))},
            {x2 - static_cast<int>(kHeadLen * std::cos(angle + kSpread)),
             y2 - static_cast<int>(kHeadLen * std::sin(angle + kSpread))}};
        ::SelectObject(mem_dc, blue_brush);
        ::Polygon(mem_dc, head, 3);
        ::SelectObject(mem_dc, ::GetStockObject(NULL_BRUSH));
        break;
      }
      case Annotation::Type::kRect: {
        // Border only here; the translucent fill is painted straight
        // into the DIB by ApplyHighlightFills after the alpha fix-up,
        // because GDI cannot paint translucently.
        const int rx = a.x - origin_x;
        const int ry = a.y - origin_y;
        ::Rectangle(mem_dc, rx, ry, rx + a.w, ry + a.h);
        break;
      }
      case Annotation::Type::kText: {
        DrawLabelBubble(mem_dc, a.x - origin_x, a.y - origin_y, a.text, 18);
        break;
      }
    }
  }
  ::SelectObject(mem_dc, old_brush);
  ::SelectObject(mem_dc, old_pen);
  ::DeleteObject(blue_pen);
  ::DeleteObject(blue_brush);
}

void DjCursorChannel::ApplyHighlightFills(uint32_t* pixels) {
  if (pixels == nullptr) {
    return;
  }
  const int vx = ::GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int vy = ::GetSystemMetrics(SM_YVIRTUALSCREEN);
  for (const Annotation& a : annotations_) {
    if (a.type != Annotation::Type::kRect) {
      continue;
    }
    // Inset 3 px so the fill stays inside the 3 px border, clipped to
    // the DIB. Overwrites whatever the GDI pass painted inside the rect.
    const int x0 = std::max(0, a.x - vx + 3);
    const int y0 = std::max(0, a.y - vy + 3);
    const int x1 = std::min(overlay_w_, a.x - vx + a.w - 3);
    const int y1 = std::min(overlay_h_, a.y - vy + a.h - 3);
    for (int y = y0; y < y1; ++y) {
      uint32_t* row = pixels + static_cast<size_t>(y) * overlay_w_;
      for (int x = x0; x < x1; ++x) {
        row[x] = kHighlightFill;
      }
    }
  }
}

void DjCursorChannel::DrawOverlay() {
  if (overlay_ == nullptr || overlay_w_ <= 0 || overlay_h_ <= 0) {
    return;
  }
  // Window origin in virtual-screen pixels: the virtual-screen origin
  // while annotations are shown (full-screen window), the cursor position
  // otherwise (small window whose top-left is the cursor tip).
  const int origin_x = HasAnnotations()
                           ? ::GetSystemMetrics(SM_XVIRTUALSCREEN)
                           : x_;
  const int origin_y = HasAnnotations()
                           ? ::GetSystemMetrics(SM_YVIRTUALSCREEN)
                           : y_;
  // 32-bit top-down DIB for per-pixel alpha via UpdateLayeredWindow.
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = overlay_w_;
  info.bmiHeader.biHeight = -overlay_h_;  // top-down
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  const HDC screen_dc = ::GetDC(nullptr);
  const HDC mem_dc = ::CreateCompatibleDC(screen_dc);
  const HBITMAP dib = ::CreateDIBSection(screen_dc, &info, DIB_RGB_COLORS,
                                         &bits, nullptr, 0);
  if (mem_dc == nullptr || dib == nullptr || bits == nullptr) {
    if (mem_dc != nullptr) {
      ::DeleteDC(mem_dc);
    }
    if (dib != nullptr) {
      ::DeleteObject(dib);
    }
    ::ReleaseDC(nullptr, screen_dc);
    return;
  }
  const HGDIOBJ old_bitmap = ::SelectObject(mem_dc, dib);
  // Clear to fully transparent.
  const size_t pixel_count =
      static_cast<size_t>(overlay_w_) * static_cast<size_t>(overlay_h_);
  std::fill_n(static_cast<uint32_t*>(bits), pixel_count, 0u);

  // Draw with GDI into the DIB. GDI ignores the alpha byte, so paint on a
  // solid-colour pass and then set alpha per pixel afterwards: pixels that
  // GDI painted are opaque, untouched pixels stay transparent.
  // (Simple and robust: track painted pixels by comparing against 0.)
  const HBRUSH blue_brush = ::CreateSolidBrush(kDjBlue);
  const HBRUSH white_brush = ::CreateSolidBrush(kWhite);
  const HPEN blue_pen = ::CreatePen(PS_SOLID, 1, kDjBlue);
  const HGDIOBJ old_brush = ::SelectObject(mem_dc, blue_brush);
  const HGDIOBJ old_pen = ::SelectObject(mem_dc, blue_pen);
  ::SetBkMode(mem_dc, TRANSPARENT);

  // Annotations first, cursor marker on top so it stays visible.
  if (HasAnnotations()) {
    DrawAnnotations(mem_dc, origin_x, origin_y);
  }

  if (visible_) {
    const int tip_x = x_ - origin_x;
    const int tip_y = y_ - origin_y;
    if (companion_state_ == CompanionState::kListening) {
      // 5-bar animated blue waveform replacing the triangle while listening.
      for (int i = 0; i < 5; ++i) {
        const double phase =
            static_cast<double>(pulse_tick_) * 0.25 + static_cast<double>(i) * 0.7;
        const int bar_h = 6 + static_cast<int>((std::sin(phase) + 1.0) * 7.0);
        const int bx = tip_x + i * 5;
        const int by = tip_y + 12 - bar_h / 2;
        ::RoundRect(mem_dc, bx, by, bx + 3, by + bar_h, 2, 2);
      }
    } else if (companion_state_ == CompanionState::kThinking) {
      // Orbiting blue ring indicator while thinking/reading screen.
      const HPEN ring_pen = ::CreatePen(PS_SOLID, 3, kDjBlue);
      const HGDIOBJ prev_pen = ::SelectObject(mem_dc, ring_pen);
      const HGDIOBJ prev_brush =
          ::SelectObject(mem_dc, ::GetStockObject(NULL_BRUSH));
      const double angle = static_cast<double>(pulse_tick_) * 0.2;
      const int cx = tip_x + 10;
      const int cy = tip_y + 10;
      const int x_start = cx + static_cast<int>(9.0 * std::cos(angle));
      const int y_start = cy + static_cast<int>(9.0 * std::sin(angle));
      const int x_end = cx + static_cast<int>(9.0 * std::cos(angle + 3.8));
      const int y_end = cy + static_cast<int>(9.0 * std::sin(angle + 3.8));
      ::Arc(mem_dc, cx - 9, cy - 9, cx + 9, cy + 9, x_start, y_start, x_end,
            y_end);
      ::SelectObject(mem_dc, prev_brush);
      ::SelectObject(mem_dc, prev_pen);
      ::DeleteObject(ring_pen);
    } else {
      // Triangle pointer, tip at (x_, y_).
      POINT triangle[3] = {{tip_x, tip_y},
                           {tip_x, tip_y + 24},
                           {tip_x + 8, tip_y + 17}};
      ::Polygon(mem_dc, triangle, 3);
      ::SelectObject(mem_dc, white_brush);
      POINT notch[3] = {{tip_x + 3, tip_y + 4},
                        {tip_x + 3, tip_y + 16},
                        {tip_x + 7, tip_y + 13}};
      ::Polygon(mem_dc, notch, 3);
      ::SelectObject(mem_dc, blue_brush);
    }

    if (!caption_text_.empty()) {
      DrawCaptionCard(mem_dc, tip_x + 28, tip_y + 4, caption_text_, 360, 16);
    } else if (!label_.empty()) {
      DrawLabelBubble(mem_dc, tip_x + 20, tip_y, label_, 20);
    }
  }

  ::SelectObject(mem_dc, old_brush);
  ::SelectObject(mem_dc, old_pen);
  ::DeleteObject(blue_brush);
  ::DeleteObject(white_brush);
  ::DeleteObject(blue_pen);

  // Fix up alpha: any pixel GDI painted (non-zero RGB) becomes opaque.
  uint32_t* pixels = static_cast<uint32_t*>(bits);
  for (size_t i = 0; i < pixel_count; ++i) {
    if ((pixels[i] & 0x00FFFFFFu) != 0) {
      pixels[i] |= 0xFF000000u;
    }
  }
  // Translucent highlight fills go in after the fix-up, so their
  // ~27%-opaque alpha survives (the fix-up would force them opaque).
  ApplyHighlightFills(pixels);

  POINT src_point{0, 0};
  SIZE size{overlay_w_, overlay_h_};
  BLENDFUNCTION blend{};
  blend.BlendOp = AC_SRC_OVER;
  blend.BlendFlags = 0;
  blend.SourceConstantAlpha = 255;
  blend.AlphaFormat = AC_SRC_ALPHA;
  ::UpdateLayeredWindow(overlay_, screen_dc, nullptr, &size, mem_dc,
                        &src_point, 0, &blend, ULW_ALPHA);
  ::SelectObject(mem_dc, old_bitmap);
  ::DeleteObject(dib);
  ::DeleteDC(mem_dc);
  ::ReleaseDC(nullptr, screen_dc);
}

void DjCursorChannel::StartAnimation(int to_x, int to_y) {
  from_x_ = x_;
  from_y_ = y_;
  x_ = to_x;
  y_ = to_y;
  const int dx = to_x - from_x_;
  const int dy = to_y - from_y_;
  const double dist = std::hypot(static_cast<double>(dx), static_cast<double>(dy));
  const int arc_height = std::min(static_cast<int>(dist * 0.2), 80);
  ctrl_x_ = (from_x_ + to_x) / 2;
  ctrl_y_ = (from_y_ + to_y) / 2 - arc_height;
  anim_start_ = ::GetTickCount();
  animating_ = true;
  if (overlay_ != nullptr) {
    ::SetTimer(overlay_, kAnimTimerId, 16, nullptr);  // ~60 fps.
  }
}

void DjCursorChannel::StopAnimation() {
  if (animating_ && overlay_ != nullptr) {
    ::KillTimer(overlay_, kAnimTimerId);
  }
  animating_ = false;
}

void DjCursorChannel::StartPulseTimer() {
  if (!pulse_timer_active_ && overlay_ != nullptr) {
    ::SetTimer(overlay_, kPulseTimerId, 45, nullptr);
    pulse_timer_active_ = true;
  }
}

void DjCursorChannel::StopPulseTimer() {
  if (pulse_timer_active_ && overlay_ != nullptr) {
    ::KillTimer(overlay_, kPulseTimerId);
  }
  pulse_timer_active_ = false;
}

void DjCursorChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();

  if (method == "showCursor" || method == "moveCursor") {
    int64_t x = 0;
    int64_t y = 0;
    std::string label;
    if (!GetIntArg(call, "x", &x) || !GetIntArg(call, "y", &y)) {
      result->Success(Err(method + " needs integer 'x' and 'y'."));
      return;
    }
    GetStringArg(call, "label", &label);  // Optional.
    const bool was_visible = visible_;
    label_ = WideFromUtf8(label);
    if (HasAnnotations()) {
      // The overlay is full-screen; the cursor just moves inside it.
      // No slide: the window itself must not move.
      StopAnimation();
      EnsureAnnotationWindow();
      if (overlay_ == nullptr) {
        result->Success(Err("Could not create the cursor overlay window."));
        return;
      }
      x_ = static_cast<int>(x);
      y_ = static_cast<int>(y);
      visible_ = true;
      DrawOverlay();
      result->Success(Ok());
      return;
    }
    EnsureWindow();
    if (overlay_ == nullptr) {
      result->Success(Err("Could not create the cursor overlay window."));
      return;
    }
    // The overlay may still be full-screen sized from annotations that
    // were cleared while the cursor was hidden; shrink it back first.
    RestoreCursorWindow();
    if (method == "showCursor" || !was_visible) {
      StopAnimation();
      x_ = static_cast<int>(x);
      y_ = static_cast<int>(y);
      ::SetWindowPos(overlay_, HWND_TOPMOST, x_, y_, 0, 0,
                     SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER |
                         SWP_SHOWWINDOW);
      visible_ = true;
      DrawOverlay();
    } else {
      // Smooth slide to the new position; the timer moves the window.
      StartAnimation(static_cast<int>(x), static_cast<int>(y));
      DrawOverlay();
    }
    result->Success(Ok());
    return;
  }

  if (method == "hideCursor") {
    StopAnimation();
    StopPulseTimer();
    visible_ = false;
    companion_state_ = CompanionState::kHidden;
    caption_text_.clear();
    // Annotations persist until clearAnnotations OR the cursor is hidden.
    annotations_.clear();
    if (overlay_ != nullptr) {
      RestoreCursorWindow();
      ::ShowWindow(overlay_, SW_HIDE);
    }
    result->Success(Ok());
    return;
  }

  if (method == "setCompanionState") {
    std::string state;
    if (!GetStringArg(call, "state", &state)) {
      result->Success(Err("setCompanionState needs a 'state' string."));
      return;
    }
    std::string text;
    GetStringArg(call, "text", &text);
    if (state == "hidden") {
      StopAnimation();
      StopPulseTimer();
      visible_ = false;
      companion_state_ = CompanionState::kHidden;
      caption_text_.clear();
      if (overlay_ != nullptr && !HasAnnotations()) {
        ::ShowWindow(overlay_, SW_HIDE);
      } else if (overlay_ != nullptr) {
        DrawOverlay();
      }
      result->Success(Ok());
      return;
    }
    if (state == "listening") {
      companion_state_ = CompanionState::kListening;
    } else if (state == "thinking") {
      companion_state_ = CompanionState::kThinking;
    } else if (state == "responding") {
      companion_state_ = CompanionState::kResponding;
    } else {
      companion_state_ = CompanionState::kIdle;
    }
    caption_text_ = WideFromUtf8(text);
    if (!visible_) {
      POINT pt{};
      if (::GetCursorPos(&pt)) {
        x_ = pt.x + 24;
        y_ = pt.y + 18;
      }
    }
    EnsureWindow();
    if (overlay_ == nullptr) {
      result->Success(Err("Could not create the cursor overlay window."));
      return;
    }
    if (!HasAnnotations()) {
      RestoreCursorWindow();
      ::SetWindowPos(overlay_, HWND_TOPMOST, x_, y_, 0, 0,
                     SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER |
                         SWP_SHOWWINDOW);
    }
    visible_ = true;
    if (companion_state_ == CompanionState::kListening ||
        companion_state_ == CompanionState::kThinking) {
      StartPulseTimer();
    } else {
      StopPulseTimer();
    }
    DrawOverlay();
    result->Success(Ok());
    return;
  }

  if (method == "annotate") {
    const flutter::EncodableMap* args =
        std::get_if<flutter::EncodableMap>(call.arguments());
    const flutter::EncodableList* list = nullptr;
    if (args != nullptr) {
      const auto it = args->find(flutter::EncodableValue("annotations"));
      if (it != args->end()) {
        list = std::get_if<flutter::EncodableList>(&it->second);
      }
    }
    if (list == nullptr) {
      result->Success(Err("annotate needs an 'annotations' list."));
      return;
    }
    // Replaces the current annotations. Unknown types and malformed
    // entries are skipped, never an error for the whole call.
    std::vector<Annotation> parsed;
    for (const auto& item : *list) {
      const flutter::EncodableMap* m =
          std::get_if<flutter::EncodableMap>(&item);
      if (m == nullptr) {
        continue;
      }
      std::string type;
      if (!GetMapString(*m, "type", &type)) {
        continue;
      }
      Annotation a;
      int64_t v = 0;
      if (type == "circle") {
        if (!GetMapInt(*m, "x", &v)) continue;
        a.x = static_cast<int>(v);
        if (!GetMapInt(*m, "y", &v)) continue;
        a.y = static_cast<int>(v);
        if (!GetMapInt(*m, "r", &v) || v <= 0) continue;
        a.r = static_cast<int>(v);
        a.type = Annotation::Type::kCircle;
      } else if (type == "arrow") {
        if (!GetMapInt(*m, "x1", &v)) continue;
        a.x = static_cast<int>(v);
        if (!GetMapInt(*m, "y1", &v)) continue;
        a.y = static_cast<int>(v);
        if (!GetMapInt(*m, "x2", &v)) continue;
        a.x2 = static_cast<int>(v);
        if (!GetMapInt(*m, "y2", &v)) continue;
        a.y2 = static_cast<int>(v);
        a.type = Annotation::Type::kArrow;
      } else if (type == "rect") {
        if (!GetMapInt(*m, "x", &v)) continue;
        a.x = static_cast<int>(v);
        if (!GetMapInt(*m, "y", &v)) continue;
        a.y = static_cast<int>(v);
        if (!GetMapInt(*m, "w", &v) || v <= 0) continue;
        a.w = static_cast<int>(v);
        if (!GetMapInt(*m, "h", &v) || v <= 0) continue;
        a.h = static_cast<int>(v);
        a.type = Annotation::Type::kRect;
      } else if (type == "text") {
        if (!GetMapInt(*m, "x", &v)) continue;
        a.x = static_cast<int>(v);
        if (!GetMapInt(*m, "y", &v)) continue;
        a.y = static_cast<int>(v);
        std::string text;
        if (!GetMapString(*m, "text", &text) || text.empty()) continue;
        a.text = WideFromUtf8(text);
        a.type = Annotation::Type::kText;
      } else {
        continue;
      }
      parsed.push_back(std::move(a));
    }
    annotations_ = std::move(parsed);
    if (annotations_.empty()) {
      // An empty list clears, same as clearAnnotations.
      if (visible_) {
        StopAnimation();
        RestoreCursorWindow();
        DrawOverlay();
      } else if (overlay_ != nullptr) {
        ::ShowWindow(overlay_, SW_HIDE);
      }
      result->Success(Ok());
      return;
    }
    EnsureAnnotationWindow();
    if (overlay_ == nullptr) {
      result->Success(Err("Could not create the annotation overlay window."));
      return;
    }
    DrawOverlay();
    result->Success(Ok());
    return;
  }

  if (method == "clearAnnotations") {
    annotations_.clear();
    if (overlay_ != nullptr) {
      if (visible_) {
        StopAnimation();
        RestoreCursorWindow();
        DrawOverlay();
      } else {
        ::ShowWindow(overlay_, SW_HIDE);
      }
    }
    result->Success(Ok());
    return;
  }

  result->Success(Err("Unknown cursor method: " + method + "."));
}

}  // namespace dj
