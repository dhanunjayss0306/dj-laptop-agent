// DJ system channel (Windows). See dj_system_channel.h for the API list.

#include "dj_system_channel.h"

#include <flutter/standard_method_codec.h>

#include <shlobj.h>
#include <shellapi.h>

#include <cstdint>

#include "dj_channel_utils.h"

namespace dj {
namespace {

// Run-key location for start-at-login. Value name "DJ".
constexpr const wchar_t kRunKeyPath[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr const wchar_t kRunValueName[] = L"DJ";

// CPU% from two GetSystemTimes samples 500 ms apart (same approach as the
// Electron app's two os.cpus() samples). Returns -1.0 when unmeasurable
// (identical/backwards samples); the Dart side then reports CPU as
// unavailable instead of inventing a number.
double SampleCpuPercent() {
  FILETIME idle1{}, kernel1{}, user1{};
  if (!::GetSystemTimes(&idle1, &kernel1, &user1)) {
    return -1.0;
  }
  ::Sleep(500);
  FILETIME idle2{}, kernel2{}, user2{};
  if (!::GetSystemTimes(&idle2, &kernel2, &user2)) {
    return -1.0;
  }
  const auto to_u64 = [](const FILETIME& ft) {
    ULARGE_INTEGER v{};
    v.LowPart = ft.dwLowDateTime;
    v.HighPart = ft.dwHighDateTime;
    return v.QuadPart;
  };
  const uint64_t idle_delta = to_u64(idle2) - to_u64(idle1);
  const uint64_t kernel_delta = to_u64(kernel2) - to_u64(kernel1);
  const uint64_t user_delta = to_u64(user2) - to_u64(user1);
  const uint64_t total_delta = kernel_delta + user_delta;
  if (total_delta == 0 || idle_delta > total_delta) {
    return -1.0;
  }
  return 100.0 *
         (1.0 - static_cast<double>(idle_delta) /
                    static_cast<double>(total_delta));
}

flutter::EncodableValue OpenWithShell(const std::string& path,
                                      const std::string& what) {
  if (path.empty()) {
    return Err("No " + what + " path was given.");
  }
  const std::wstring wide = WideFromUtf8(path);
  // ShellExecuteW returns > 32 on success; <= 32 is an error code.
  const HINSTANCE rc =
      ::ShellExecuteW(nullptr, L"open", wide.c_str(), nullptr, nullptr,
                      SW_SHOWNORMAL);
  const INT_PTR code = reinterpret_cast<INT_PTR>(rc);
  if (code <= 32) {
    return Err("I could not open that " + what + ": Windows error " +
               std::to_string(code) + " (" + LastErrorMessage() + ").");
  }
  return OkWithMessage("Opened " + path + ".");
}

}  // namespace

DjSystemChannel::DjSystemChannel(flutter::BinaryMessenger* messenger)
    : channel_(messenger, "com.dhanunjay.dj/system",
               &flutter::StandardMethodCodec::GetInstance()) {
  channel_.SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

DjSystemChannel::~DjSystemChannel() {
  // Unregister first: destroying the MethodChannel does not unregister
  // the handler, and a late Dart call must not reach a dead object.
  channel_.SetMethodCallHandler(nullptr);
}

void DjSystemChannel::NotifyTrayHidden() {
  channel_.InvokeMethod(
      "onTrayHidden",
      std::make_unique<flutter::EncodableValue>(flutter::EncodableValue(
          flutter::EncodableMap{})));
}

void DjSystemChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();

  if (method == "openFile") {
    std::string path;
    if (!GetStringArg(call, "path", &path)) {
      result->Success(Err("openFile needs a 'path' string."));
      return;
    }
    result->Success(OpenWithShell(path, "file"));
    return;
  }

  if (method == "openFolder") {
    std::string path;
    if (!GetStringArg(call, "path", &path)) {
      result->Success(Err("openFolder needs a 'path' string."));
      return;
    }
    result->Success(OpenWithShell(path, "folder"));
    return;
  }

  if (method == "openApp") {
    std::string exe;
    std::vector<std::string> args;
    if (!GetStringArg(call, "exe", &exe) ||
        !GetStringListArg(call, "args", &args)) {
      result->Success(Err("openApp needs an 'exe' string and 'args' list."));
      return;
    }
    if (exe.empty()) {
      result->Success(Err("I could not find an app called '' on this laptop."));
      return;
    }
    // Build a command line: quoted exe + quoted args. CreateProcessW takes
    // a mutable buffer; quote every element so paths with spaces work.
    std::wstring command_line = L"\"";
    command_line += WideFromUtf8(exe);
    command_line += L"\"";
    for (const std::string& arg : args) {
      command_line += L" \"";
      command_line += WideFromUtf8(arg);
      command_line += L"\"";
    }
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    // DETACHED_PROCESS: no console window, fully detached like
    // Node spawn({detached: true, stdio: 'ignore'}).
    const BOOL ok = ::CreateProcessW(
        nullptr, command_line.data(), nullptr, nullptr, FALSE,
        DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP, nullptr, nullptr,
        &startup, &process);
    if (!ok) {
      result->Success(Err("I could not find an app called '" + exe +
                          "' on this laptop. (" + LastErrorMessage() + ")"));
      return;
    }
    ::CloseHandle(process.hProcess);
    ::CloseHandle(process.hThread);
    result->Success(OkWithMessage("Opened " + exe + "."));
    return;
  }

  if (method == "deleteToTrash") {
    // Dart sends {'paths': [...]} (SystemOps.deleteToTrash takes a list,
    // like Electron's single trash(existing) call). A single {'path': ...}
    // is also accepted for convenience.
    std::vector<std::string> paths;
    std::string single_path;
    if (GetStringListArg(call, "paths", &paths) && paths.empty() &&
        GetStringArg(call, "path", &single_path) && !single_path.empty()) {
      paths.push_back(single_path);
    }
    if (paths.empty()) {
      result->Success(Err("deleteToTrash needs a 'paths' list."));
      return;
    }
    // Build the double-null-terminated list SHFileOperationW requires,
    // skipping paths that are already gone (per-path error in the reply).
    std::wstring multi;
    std::vector<std::string> gone;
    for (const std::string& path : paths) {
      if (!PathExistsUtf8(path)) {
        gone.push_back(path);
        continue;
      }
      multi += WideFromUtf8(path);
      multi.push_back(L'\0');
    }
    if (multi.empty()) {
      result->Success(Err("Nothing to delete — every file is already gone."));
      return;
    }
    multi.push_back(L'\0');  // Second NUL terminates the list.
    SHFILEOPSTRUCTW op{};
    op.wFunc = FO_DELETE;
    op.pFrom = multi.c_str();
    // FOF_ALLOWUNDO = Recycle Bin (never permanent delete).
    // FOF_NOCONFIRMATION | FOF_SILENT: DJ already confirmed with the user
    // in its own dialog; Windows must not ask again.
    op.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT;
    const int rc = ::SHFileOperationW(&op);
    if (rc != 0 || op.fAnyOperationsAborted) {
      result->Success(Err("Could not move files to the Recycle Bin "
                          "(Windows error " +
                          std::to_string(rc) + ")."));
      return;
    }
    if (!gone.empty()) {
      std::string message = "Moved to the Recycle Bin. Already gone:";
      for (const std::string& path : gone) {
        message += " " + path + ";";
      }
      result->Success(OkWithMessage(message));
      return;
    }
    result->Success(OkWithMessage("Moved to the Recycle Bin."));
    return;
  }

  if (method == "getSystemStats") {
    SYSTEM_INFO sys_info{};
    ::GetSystemInfo(&sys_info);
    MEMORYSTATUSEX mem{};
    mem.dwLength = sizeof(mem);
    const BOOL mem_ok = ::GlobalMemoryStatusEx(&mem);
    const double cpu = SampleCpuPercent();  // -1.0 when unmeasurable.
    flutter::EncodableMap out;
    out[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
    if (cpu < 0.0) {
      out[flutter::EncodableValue("cpuPercent")] =
          flutter::EncodableValue();  // null: unmeasurable, never invented.
    } else {
      out[flutter::EncodableValue("cpuPercent")] =
          flutter::EncodableValue(cpu);
    }
    out[flutter::EncodableValue("cpuCores")] =
        flutter::EncodableValue(static_cast<int32_t>(sys_info.dwNumberOfProcessors));
    out[flutter::EncodableValue("totalMemBytes")] = flutter::EncodableValue(
        static_cast<int64_t>(mem_ok ? mem.ullTotalPhys : 0));
    out[flutter::EncodableValue("freeMemBytes")] = flutter::EncodableValue(
        static_cast<int64_t>(mem_ok ? mem.ullAvailPhys : 0));
    out[flutter::EncodableValue("uptimeSeconds")] = flutter::EncodableValue(
        static_cast<int64_t>(::GetTickCount64() / 1000));
    out[flutter::EncodableValue("platform")] =
        flutter::EncodableValue(std::string("windows"));
    result->Success(flutter::EncodableValue(std::move(out)));
    return;
  }

  if (method == "setStartAtLogin") {
    bool enabled = false;
    if (!GetBoolArg(call, "enabled", &enabled)) {
      result->Success(Err("setStartAtLogin needs an 'enabled' boolean."));
      return;
    }
    wchar_t exe_path[MAX_PATH] = {};
    const DWORD len = ::GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
    if (len == 0 || len >= MAX_PATH) {
      result->Success(Err("Could not find DJ's own exe path (" +
                          LastErrorMessage() + ")."));
      return;
    }
    HKEY key = nullptr;
    const LSTATUS open_rc = ::RegOpenKeyExW(
        HKEY_CURRENT_USER, kRunKeyPath, 0, KEY_SET_VALUE, &key);
    if (open_rc != ERROR_SUCCESS || key == nullptr) {
      result->Success(Err("Could not open the Windows Run key (" +
                          LastErrorMessage() + ")."));
      return;
    }
    LSTATUS rc = ERROR_SUCCESS;
    if (enabled) {
      const std::wstring value(exe_path, len);
      rc = ::RegSetValueExW(key, kRunValueName, 0, REG_SZ,
                            reinterpret_cast<const BYTE*>(value.c_str()),
                            static_cast<DWORD>((value.size() + 1) *
                                               sizeof(wchar_t)));
    } else {
      rc = ::RegDeleteValueW(key, kRunValueName);
      if (rc == ERROR_FILE_NOT_FOUND) {
        rc = ERROR_SUCCESS;  // Already off; that is the requested state.
      }
    }
    ::RegCloseKey(key);
    if (rc != ERROR_SUCCESS) {
      result->Success(Err("Could not change start-at-login (" +
                          LastErrorMessage() + ")."));
      return;
    }
    flutter::EncodableMap out;
    out[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
    out[flutter::EncodableValue("enabled")] = flutter::EncodableValue(enabled);
    out[flutter::EncodableValue("message")] = flutter::EncodableValue(
        enabled ? "DJ will start when Windows starts."
                : "DJ will not start when Windows starts.");
    result->Success(flutter::EncodableValue(std::move(out)));
    return;
  }

  if (method == "getHomeDir") {
    PWSTR folder = nullptr;
    const HRESULT hr =
        ::SHGetKnownFolderPath(FOLDERID_Profile, 0, nullptr, &folder);
    if (FAILED(hr) || folder == nullptr) {
      result->Success(
          Err("Could not find the user profile folder (" +
              LastErrorMessage() + ")."));
      return;
    }
    const std::string home = Utf8FromWide(std::wstring(folder));
    ::CoTaskMemFree(folder);
    flutter::EncodableMap out;
    out[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
    out[flutter::EncodableValue("path")] = flutter::EncodableValue(home);
    result->Success(flutter::EncodableValue(std::move(out)));
    return;
  }

  if (method == "getDownloadsDir") {
    PWSTR folder = nullptr;
    const HRESULT hr =
        ::SHGetKnownFolderPath(FOLDERID_Downloads, 0, nullptr, &folder);
    if (FAILED(hr) || folder == nullptr) {
      result->Success(Err("Could not find the Downloads folder (" +
                          LastErrorMessage() + ")."));
      return;
    }
    const std::string downloads = Utf8FromWide(std::wstring(folder));
    ::CoTaskMemFree(folder);
    flutter::EncodableMap out;
    out[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
    out[flutter::EncodableValue("path")] = flutter::EncodableValue(downloads);
    result->Success(flutter::EncodableValue(std::move(out)));
    return;
  }

  if (method == "pickFolder") {
    // IFileDialog with FOS_PICKFOLDERS. Runs on the UI thread (the
    // platform channel already runs there); the dialog is modal to the
    // DJ window. Returns path, or ok:false 'cancelled' when dismissed.
    IFileDialog* dialog = nullptr;
    HRESULT hr = ::CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                    CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
    if (FAILED(hr) || dialog == nullptr) {
      result->Success(
          Err("Could not open the folder picker (" + LastErrorMessage() + ")."));
      return;
    }
    DWORD options = 0;
    hr = dialog->GetOptions(&options);
    if (SUCCEEDED(hr)) {
      dialog->SetOptions(options | FOS_PICKFOLDERS);
    }
    hr = dialog->Show(nullptr);
    if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
      dialog->Release();
      flutter::EncodableMap out;
      out[flutter::EncodableValue("ok")] = flutter::EncodableValue(false);
      out[flutter::EncodableValue("message")] =
          flutter::EncodableValue(std::string("cancelled"));
      out[flutter::EncodableValue("path")] = flutter::EncodableValue();
      result->Success(flutter::EncodableValue(std::move(out)));
      return;
    }
    if (FAILED(hr)) {
      dialog->Release();
      result->Success(
          Err("The folder picker failed (" + LastErrorMessage() + ")."));
      return;
    }
    IShellItem* item = nullptr;
    hr = dialog->GetResult(&item);
    dialog->Release();
    if (FAILED(hr) || item == nullptr) {
      result->Success(
          Err("The folder picker returned no folder (" +
              LastErrorMessage() + ")."));
      return;
    }
    PWSTR display_path = nullptr;
    hr = item->GetDisplayName(SIGDN_FILESYSPATH, &display_path);
    item->Release();
    if (FAILED(hr) || display_path == nullptr) {
      result->Success(Err("Could not read the picked folder path (" +
                          LastErrorMessage() + ")."));
      return;
    }
    const std::string path = Utf8FromWide(std::wstring(display_path));
    ::CoTaskMemFree(display_path);
    flutter::EncodableMap out;
    out[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
    out[flutter::EncodableValue("path")] = flutter::EncodableValue(path);
    result->Success(flutter::EncodableValue(std::move(out)));
    return;
  }

  result->Success(Err("Unknown system method: " + method + "."));
}

}  // namespace dj
