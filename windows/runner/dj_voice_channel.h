// DJ voice channel (Windows).
//
// MethodChannel "com.dhanunjay.dj/voice": speak(text), stopSpeak(),
// startWhisper(modelPath), transcribe(audioPath), whisperStatus(modelPath).
//
// Two independent pieces:
// 1. Text-to-speech via Windows SAPI (ISpVoice). Fully implemented here,
//    works offline, no downloads. speak() uses SPF_ASYNC so it returns
//    immediately; stopSpeak() halts it (SPF_PURGEBEFORESPEAK with empty
//    text). Requires sapi.lib and COM initialized (main.cpp does
//    CoInitializeEx at startup).
// 2. Speech-to-text via a local whisper.cpp sidecar. startWhisper()
//    launches whisper-server (if whisper-server.exe + a ggml model exist
//    next to the app) on http://127.0.0.1:8080; transcribe() POSTs the
//    audio file to /inference as multipart/form-data (WinHttp) and returns
//    the "text" field. When the binary or model is missing, startWhisper
//    returns {"ok": false, "message": "whisper not installed — see
//    WINDOWS-BUILD.md"}. DJ NEVER fakes a transcript: a missing sidecar
//    is a plain failure, never invented text.
//
// Win32 APIs used: SAPI ISpVoice (sapi.h), CreateProcessW (sidecar),
// WinHttp (winhttp.h: WinHttpOpen/Connect/OpenRequest/SendRequest/
// ReceiveResponse/ReadData) for the inference POST.

#ifndef RUNNER_DJ_VOICE_CHANNEL_H_
#define RUNNER_DJ_VOICE_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>
#include <windows.h>

// ISpVoice is declared here, not in <windows.h>: this header must include
// <sapi.h> itself so it compiles standalone (a missing sapi.h here was the
// same class of bug as the dj_screen_channel ULONG_PTR failure).
#include <sapi.h>

namespace dj {

class DjVoiceChannel {
 public:
  explicit DjVoiceChannel(flutter::BinaryMessenger* messenger);
  ~DjVoiceChannel();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Finds whisper-server.exe: <exe dir>\whisper-server.exe, then
  // <exe dir>\whisper\whisper-server.exe. Empty when not found.
  std::string FindWhisperServer() const;
  bool IsWhisperRunning() const;
  // One persistent SAPI voice for the life of the channel: speak() and
  // stopSpeak() must share it, because a new ISpVoice cannot stop
  // another instance's speech. Created lazily on first use.
  ISpVoice* Voice();

  flutter::MethodChannel<flutter::EncodableValue> channel_;
  PROCESS_INFORMATION whisper_process_{};
  bool whisper_running_ = false;
  ISpVoice* voice_ = nullptr;
};

}  // namespace dj

#endif  // RUNNER_DJ_VOICE_CHANNEL_H_
