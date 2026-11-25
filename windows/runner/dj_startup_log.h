// DJ startup diagnostic log (Windows runner). See dj_startup_log.h.
//
// Every launch appends timestamped lines to `dj_startup.log` next to
// the exe — the same file the Dart side writes to (see
// lib/core/startup_log.dart) — so one file shows both sides of a hung
// startup: whether the window/engine/channels came up, whether the
// first Flutter frame arrived, and whether the platform thread was
// still pumping messages when the frame was late.

#ifndef RUNNER_DJ_STARTUP_LOG_H_
#define RUNNER_DJ_STARTUP_LOG_H_

namespace dj {

// Appends one timestamped line to dj_startup.log next to the exe and
// flushes it (open/append/close per line), so lines survive a hang or
// a kill. Never throws; a failed write is silently dropped.
void DjLogStartup(const char* step);

}  // namespace dj

#endif  // RUNNER_DJ_STARTUP_LOG_H_
