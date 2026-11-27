// DJ fake cursor overlay + screen annotations (Windows).
//
// MethodChannel "com.dhanunjay.dj/cursor": showCursor(x, y, label),
// moveCursor(x, y, label), hideCursor(), annotate(annotations),
// clearAnnotations().
//
// A transparent, always-on-top, click-through layered window that draws a
// small blue (DJ blue #0071E3) cursor marker: a triangle pointer plus a
// label bubble. It NEVER moves the real mouse and NEVER intercepts clicks:
//   WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW
//   (no taskbar icon), drawn with UpdateLayeredWindow from a 32-bit DIB.
// moveCursor animates the marker with a smooth slide (~300 ms, 60 fps
// timer). Coordinates are virtual-screen pixels; the triangle tip sits
// exactly at (x, y).
//
// Annotations are drawn on the SAME layered window, in the same DJ blue,
// on top of everything, and the window stays click-through
// (WS_EX_TRANSPARENT) while they are shown. Shapes (each is one map in
// the "annotations" list; unknown/malformed entries are skipped):
//   circle    {type: "circle", x, y, r}            outline circle
//   arrow     {type: "arrow", x1, y1, x2, y2}      line + arrowhead
//   rect      {type: "rect", x, y, w, h}           translucent blue fill
//                                                 + solid border
//   text      {type: "text", x, y, text}           small blue label bubble
// annotate() replaces the current annotations and shows them even when
// the cursor itself is hidden. They persist until clearAnnotations() is
// called or the cursor is hidden (hideCursor() also clears them). While
// annotations are shown the overlay covers the whole virtual screen, so
// moveCursor jumps instead of sliding (the window no longer moves).

#ifndef RUNNER_DJ_CURSOR_CHANNEL_H_
#define RUNNER_DJ_CURSOR_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>
#include <windows.h>

namespace dj {

class DjCursorChannel {
 public:
  explicit DjCursorChannel(flutter::BinaryMessenger* messenger);
  ~DjCursorChannel();

  // Window procedure for the overlay window. Forwards to the instance.
  static LRESULT CALLBACK OverlayWndProc(HWND hwnd, UINT message,
                                         WPARAM wparam, LPARAM lparam);
  // Window procedure for the clickable top-center Dynamic Island pill.
  static LRESULT CALLBACK IslandWndProc(HWND hwnd, UINT message,
                                        WPARAM wparam, LPARAM lparam);

 private:
  // One annotation shape. Coordinates are virtual-screen pixels.
  struct Annotation {
    enum class Type { kCircle, kArrow, kRect, kText };
    Type type = Type::kCircle;
    int x = 0;   // circle centre / rect top-left / text origin
    int y = 0;   // circle centre / rect top-left / text origin
    int r = 0;   // circle radius
    int x2 = 0;  // arrow end
    int y2 = 0;  // arrow end
    int w = 0;   // rect width
    int h = 0;   // rect height
    std::wstring text;  // text label
  };

  // Companion visual state for Fake DJ + live caption bubble.
  enum class CompanionState { kHidden, kIdle, kListening, kThinking, kResponding };

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void EnsureWindow();
  void EnsureIslandWindow();
  void UpdateIslandWindow();
  // Repositions/resizes the overlay to cover the whole virtual screen
  // for annotations. Creates it if needed.
  void EnsureAnnotationWindow();
  // Repositions/resizes the overlay back to the small cursor-sized window
  // at (x_ - kCursorMargin, y_ - kCursorMargin).
  void RestoreCursorWindow();
  void DrawOverlay();
  void DrawIsland();
  // Draws the annotation shapes into the DIB device context. (origin_x,
  // origin_y) is the virtual-screen position of the DIB's (0, 0) pixel,
  // so every annotation coordinate is offset by it.
  void DrawAnnotations(HDC mem_dc, int origin_x, int origin_y);
  // Translucent blue fill for highlight rects, applied straight to the
  // DIB pixels after the GDI pass (GDI cannot paint translucently).
  // |pixels| is the overlay_w_ x overlay_h_ pixel buffer.
  void ApplyHighlightFills(uint32_t* pixels);
  void StartAnimation(int to_x, int to_y);
  void StopAnimation();
  void StartPulseTimer();
  void StopPulseTimer();
  void StartFollowTimer();
  void StopFollowTimer();
  bool HasAnnotations() const { return !annotations_.empty(); }

  flutter::MethodChannel<flutter::EncodableValue> channel_;
  HWND overlay_ = nullptr;
  HWND island_ = nullptr;
  int island_w_ = 248;
  int island_h_ = 36;
  bool visible_ = false;
  int x_ = 0;
  int y_ = 0;
  std::wstring label_;
  CompanionState companion_state_ = CompanionState::kHidden;
  std::wstring caption_text_;
  double audio_level_ = 0.0;
  bool follow_cursor_ = false;
  int pulse_tick_ = 0;
  bool pulse_timer_active_ = false;
  bool follow_timer_active_ = false;
  // Current overlay size. Cursor-only: kOverlayWidth x kOverlayHeight.
  // With annotations: the whole virtual screen.
  int overlay_w_ = 0;
  int overlay_h_ = 0;
  std::vector<Annotation> annotations_;
  // Animation state: Bezier arc slide from (from_x_, from_y_) to (x_, y_).
  bool animating_ = false;
  int from_x_ = 0;
  int from_y_ = 0;
  int ctrl_x_ = 0;
  int ctrl_y_ = 0;
  DWORD anim_start_ = 0;
  static constexpr UINT_PTR kAnimTimerId = 1;
  static constexpr UINT_PTR kPulseTimerId = 2;
  static constexpr UINT_PTR kFollowTimerId = 3;
  static constexpr DWORD kAnimDurationMs = 420;
};

}  // namespace dj

#endif  // RUNNER_DJ_CURSOR_CHANNEL_H_
