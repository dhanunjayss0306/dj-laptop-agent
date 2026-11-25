#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdlib>
#include <utility>
#include <vector>

#include "flutter_window.h"
#include "dj_startup_log.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  dj::DjLogStartup("wWinMain entered");
  // Single instance: if DJ is already running, bring its window to
  // the front instead of starting a second copy (second copies create
  // extra tray icons and fight over the hotkey). The mutex is released
  // automatically when the first instance exits.
  HANDLE single_instance = ::CreateMutexW(nullptr, FALSE, L"DJAppSingleInstance");
  if (single_instance != nullptr &&
      ::GetLastError() == ERROR_ALREADY_EXISTS) {
    dj::DjLogStartup("single-instance: another DJ is running, exiting");
    ::CloseHandle(single_instance);
    HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW",
                                  L"DJ \u2014 your files, found");
    if (existing != nullptr) {
      ::ShowWindow(existing, SW_RESTORE);
      ::ShowWindow(existing, SW_SHOW);
      ::SetForegroundWindow(existing);
      ::SetFocus(existing);
    }
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  // DJ window size from PORTING-SPEC.md §0: 880 x 720, no application menu.
  Win32Window::Size size(880, 720);
  dj::DjLogStartup("window.Create started");
  if (!window.Create(L"DJ \u2014 your files, found", origin, size)) {
    dj::DjLogStartup("window.Create FAILED");
    return EXIT_FAILURE;
  }
  dj::DjLogStartup("window.Create returned");
  window.SetQuitOnClose(true);

  dj::DjLogStartup("message loop entered");
  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }
  dj::DjLogStartup("message loop exited");

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
