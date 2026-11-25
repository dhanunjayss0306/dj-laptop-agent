// DJ startup diagnostic log. See dj_startup_log.h.

#include "dj_startup_log.h"

#include <windows.h>

#include <cstdio>

#include "dj_channel_utils.h"

namespace dj {

void DjLogStartup(const char* step) {
  const std::string dir = ExeDirectoryUtf8();
  if (dir.empty() || step == nullptr) {
    return;
  }
  const std::string path = dir + "\\dj_startup.log";
  // Open/append/close per line: each line is flushed to disk the
  // moment it is written, so the log survives a hang or a kill.
  FILE* file = nullptr;
  if (::fopen_s(&file, path.c_str(), "a") != 0 || file == nullptr) {
    return;
  }
  SYSTEMTIME now{};
  ::GetLocalTime(&now);
  std::fprintf(file, "[%04u-%02u-%02u %02u:%02u:%02u.%03u] native: %s\n",
               static_cast<unsigned>(now.wYear),
               static_cast<unsigned>(now.wMonth),
               static_cast<unsigned>(now.wDay),
               static_cast<unsigned>(now.wHour),
               static_cast<unsigned>(now.wMinute),
               static_cast<unsigned>(now.wSecond),
               static_cast<unsigned>(now.wMilliseconds), step);
  std::fflush(file);
  std::fclose(file);
}

}  // namespace dj
