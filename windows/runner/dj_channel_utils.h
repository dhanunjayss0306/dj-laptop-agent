// DJ Windows runner helpers shared by the dj_*_channel files.
//
// Small inline helpers only: UTF-8 <-> UTF-16 conversion, Win32 error
// text, and MethodChannel reply builders. No third-party libraries;
// Win32 APIs only.
//
// Every channel replies with an EncodableMap:
//   success: {"ok": true, ...data}
//   failure: {"ok": false, "message": "<human-readable reason>"}
// A handler must always call result->Success (never result->Error) so the
// Dart side receives a Map instead of a thrown PlatformException.

#ifndef RUNNER_DJ_CHANNEL_UTILS_H_
#define RUNNER_DJ_CHANNEL_UTILS_H_

#include <flutter/encodable_value.h>
#include <flutter/method_result.h>

#include <cstdint>
#include <string>
#include <variant>
#include <vector>
#include <windows.h>

namespace dj {

// UTF-8 (std::string, as used by the Dart StandardMethodCodec) -> UTF-16.
inline std::wstring WideFromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int needed = ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1,
                                           nullptr, 0);
  if (needed <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(needed), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, wide.data(), needed);
  // MultiByteToWideChar writes its own NUL; drop the extra one.
  if (!wide.empty() && wide.back() == L'\0') {
    wide.pop_back();
  }
  return wide;
}

// UTF-16 -> UTF-8.
inline std::string Utf8FromWide(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  const int needed = ::WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1,
                                           nullptr, 0, nullptr, nullptr);
  if (needed <= 0) {
    return std::string();
  }
  std::string utf8(static_cast<size_t>(needed), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, utf8.data(), needed,
                        nullptr, nullptr);
  if (!utf8.empty() && utf8.back() == '\0') {
    utf8.pop_back();
  }
  return utf8;
}

// Human-readable text for the last Win32 error (GetLastError()).
inline std::string LastErrorMessage() {
  const DWORD code = ::GetLastError();
  if (code == 0) {
    return "unknown error";
  }
  wchar_t* buffer = nullptr;
  const DWORD chars = ::FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, code, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
      reinterpret_cast<LPWSTR>(&buffer), 0, nullptr);
  std::string message;
  if (chars != 0 && buffer != nullptr) {
    message = Utf8FromWide(std::wstring(buffer, chars));
    // Trim trailing CR/LF that FormatMessage appends.
    while (!message.empty() &&
           (message.back() == '\n' || message.back() == '\r' ||
            message.back() == ' ')) {
      message.pop_back();
    }
  } else {
    message = "error " + std::to_string(code);
  }
  if (buffer != nullptr) {
    ::LocalFree(buffer);
  }
  return message;
}

// Directory containing the running exe (no trailing backslash), UTF-8.
inline std::string ExeDirectoryUtf8() {
  wchar_t buffer[MAX_PATH] = {};
  const DWORD len = ::GetModuleFileNameW(nullptr, buffer, MAX_PATH);
  if (len == 0 || len >= MAX_PATH) {
    return std::string();
  }
  std::wstring path(buffer, len);
  const size_t slash = path.find_last_of(L"\\/");
  if (slash != std::wstring::npos) {
    path = path.substr(0, slash);
  }
  return Utf8FromWide(path);
}

// True when |path| (UTF-8) names an existing file or directory.
inline bool PathExistsUtf8(const std::string& path) {
  if (path.empty()) {
    return false;
  }
  const DWORD attrs = ::GetFileAttributesW(WideFromUtf8(path).c_str());
  return attrs != INVALID_FILE_ATTRIBUTES;
}

// --- MethodChannel reply builders ---------------------------------------
// EncodableMap keys must be EncodableValue; values the same.

inline flutter::EncodableValue Ok() {
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("ok"), flutter::EncodableValue(true)},
  });
}

inline flutter::EncodableValue OkWithMessage(const std::string& message) {
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("ok"), flutter::EncodableValue(true)},
      {flutter::EncodableValue("message"),
       flutter::EncodableValue(message)},
  });
}

inline flutter::EncodableValue Err(const std::string& message) {
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("ok"), flutter::EncodableValue(false)},
      {flutter::EncodableValue("message"),
       flutter::EncodableValue(message)},
  });
}

// Reads a string argument from a method call; returns false when the
// argument is missing or not a string.
inline bool GetStringArg(const flutter::MethodCall<flutter::EncodableValue>& call,
                         const std::string& name, std::string* out) {
  const flutter::EncodableMap* args =
      std::get_if<flutter::EncodableMap>(call.arguments());
  if (args == nullptr) {
    return false;
  }
  const auto it = args->find(flutter::EncodableValue(name));
  if (it == args->end()) {
    return false;
  }
  const std::string* value = std::get_if<std::string>(&it->second);
  if (value == nullptr) {
    return false;
  }
  *out = *value;
  return true;
}

// Reads a bool argument; returns false when missing or not a bool.
inline bool GetBoolArg(const flutter::MethodCall<flutter::EncodableValue>& call,
                       const std::string& name, bool* out) {
  const flutter::EncodableMap* args =
      std::get_if<flutter::EncodableMap>(call.arguments());
  if (args == nullptr) {
    return false;
  }
  const auto it = args->find(flutter::EncodableValue(name));
  if (it == args->end()) {
    return false;
  }
  const bool* value = std::get_if<bool>(&it->second);
  if (value == nullptr) {
    return false;
  }
  *out = *value;
  return true;
}

// Reads an int argument (Dart int arrives as int32 or int64); returns false
// when missing or not an int.
inline bool GetIntArg(const flutter::MethodCall<flutter::EncodableValue>& call,
                      const std::string& name, int64_t* out) {
  const flutter::EncodableMap* args =
      std::get_if<flutter::EncodableMap>(call.arguments());
  if (args == nullptr) {
    return false;
  }
  const auto it = args->find(flutter::EncodableValue(name));
  if (it == args->end()) {
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

// Reads a string-list argument (Dart List<String> arrives as
// EncodableList of strings). Missing argument -> empty list, returns true.
inline bool GetStringListArg(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    const std::string& name, std::vector<std::string>* out) {
  out->clear();
  const flutter::EncodableMap* args =
      std::get_if<flutter::EncodableMap>(call.arguments());
  if (args == nullptr) {
    return true;
  }
  const auto it = args->find(flutter::EncodableValue(name));
  if (it == args->end()) {
    return true;
  }
  const flutter::EncodableList* list =
      std::get_if<flutter::EncodableList>(&it->second);
  if (list == nullptr) {
    return false;
  }
  for (const auto& item : *list) {
    const std::string* s = std::get_if<std::string>(&item);
    if (s != nullptr) {
      out->push_back(*s);
    }
  }
  return true;
}

}  // namespace dj

#endif  // RUNNER_DJ_CHANNEL_UTILS_H_
