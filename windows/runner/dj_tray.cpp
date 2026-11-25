// DJ system tray (Windows). See dj_tray.h.

#include "dj_tray.h"

#include <shellapi.h>

#include "dj_channel_utils.h"

namespace dj {
namespace {

constexpr const wchar_t kTrayTooltip[] = L"DJ - your files, found";

// Finds the tray icon file, or empty when there is none (=> no tray).
std::wstring FindTrayIconFile() {
  const std::string dir = ExeDirectoryUtf8();
  if (dir.empty()) {
    return std::wstring();
  }
  const std::string direct = dir + "\\tray-icon.ico";
  if (PathExistsUtf8(direct)) {
    return WideFromUtf8(direct);
  }
  const std::string resources = dir + "\\resources\\tray-icon.ico";
  if (PathExistsUtf8(resources)) {
    return WideFromUtf8(resources);
  }
  return std::wstring();
}

}  // namespace

DjTray::DjTray(HWND window, std::function<void()> on_open,
               std::function<void()> on_quit)
    : window_(window), on_open_(std::move(on_open)),
      on_quit_(std::move(on_quit)) {}

DjTray::~DjTray() {
  Destroy();
}

bool DjTray::Create() {
  if (active_) {
    return true;
  }
  const std::wstring icon_path = FindTrayIconFile();
  if (icon_path.empty()) {
    return false;  // No icon file => no tray (Electron rule, §1.8).
  }
  icon_ = static_cast<HICON>(::LoadImageW(
      nullptr, icon_path.c_str(), IMAGE_ICON, 0, 0,
      LR_LOADFROMFILE | LR_DEFAULTSIZE));
  if (icon_ == nullptr) {
    return false;
  }
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = 1;
  data.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
  data.uCallbackMessage = kTrayCallbackMessage;
  data.hIcon = icon_;
  ::wcscpy_s(data.szTip, kTrayTooltip);
  if (!::Shell_NotifyIconW(NIM_ADD, &data)) {
    ::DestroyIcon(icon_);
    icon_ = nullptr;
    return false;
  }
  active_ = true;
  return true;
}

void DjTray::Destroy() {
  if (!active_) {
    return;
  }
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = 1;
  ::Shell_NotifyIconW(NIM_DELETE, &data);
  active_ = false;
  if (icon_ != nullptr) {
    ::DestroyIcon(icon_);
    icon_ = nullptr;
  }
}

bool DjTray::HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                           LPARAM lparam) {
  if (message == kTrayCallbackMessage) {
    const UINT event = LOWORD(lparam);
    if (event == WM_LBUTTONUP) {
      // Plain click on the icon = Open DJ.
      if (on_open_) {
        on_open_();
      }
      return true;
    }
    if (event == WM_RBUTTONUP) {
      HMENU menu = ::CreatePopupMenu();
      if (menu == nullptr) {
        return true;
      }
      ::AppendMenuW(menu, MF_STRING, kMenuOpenId, L"Open DJ");
      ::AppendMenuW(menu, MF_STRING, kMenuQuitId, L"Quit DJ");
      // The menu needs the window in the foreground, or it may not close
      // when the user clicks elsewhere (standard TrackPopupMenu pattern).
      ::SetForegroundWindow(hwnd);
      POINT cursor{};
      ::GetCursorPos(&cursor);
      ::TrackPopupMenu(menu, TPM_LEFTALIGN | TPM_BOTTOMALIGN | TPM_RIGHTBUTTON,
                       cursor.x, cursor.y, 0, hwnd, nullptr);
      ::PostMessageW(hwnd, WM_NULL, 0, 0);
      ::DestroyMenu(menu);
      return true;
    }
    return true;
  }
  if (message == WM_COMMAND) {
    const UINT id = LOWORD(wparam);
    if (id == kMenuOpenId) {
      if (on_open_) {
        on_open_();
      }
      return true;
    }
    if (id == kMenuQuitId) {
      if (on_quit_) {
        on_quit_();
      }
      return true;
    }
  }
  return false;
}

}  // namespace dj
