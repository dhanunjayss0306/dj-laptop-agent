// DJ voice channel (Windows). See dj_voice_channel.h.
//
// SAPI TTS works offline with no extra downloads. Whisper STT is a sidecar
// hook only: it launches a whisper.cpp whisper-server the user installed
// next to the app, and never invents a transcript when it is absent.

#include "dj_voice_channel.h"

#include <flutter/standard_method_codec.h>

#include <sapi.h>
#include <winhttp.h>

#include <cstring>
#include <fstream>
#include <string>
#include <utility>
#include <vector>

#include "dj_channel_utils.h"

namespace dj {
namespace {

constexpr const char* kWhisperMissingMessage =
    "whisper not installed — see WINDOWS-BUILD.md";
constexpr const wchar_t* kWhisperHost = L"127.0.0.1";
constexpr INTERNET_PORT kWhisperPort = 8080;

// Extracts the value of the "text" string field from a small JSON object.
// Minimal on purpose (no JSON library in the runner): finds "text", then
// parses the following JSON string, honouring \" \\ \/ \n \r \t and \uXXXX
// escapes. Returns false when the field is absent or malformed.
bool ExtractJsonTextField(const std::string& json, std::string* out) {
  const size_t key = json.find("\"text\"");
  if (key == std::string::npos) {
    return false;
  }
  size_t i = json.find(':', key + 6);
  if (i == std::string::npos) {
    return false;
  }
  ++i;
  while (i < json.size() &&
         (json[i] == ' ' || json[i] == '\t' || json[i] == '\n' ||
          json[i] == '\r')) {
    ++i;
  }
  if (i >= json.size() || json[i] != '"') {
    return false;
  }
  ++i;
  std::string text;
  while (i < json.size() && json[i] != '"') {
    if (json[i] == '\\' && i + 1 < json.size()) {
      const char esc = json[i + 1];
      if (esc == 'n') {
        text += '\n';
        i += 2;
      } else if (esc == 'r') {
        text += '\r';
        i += 2;
      } else if (esc == 't') {
        text += '\t';
        i += 2;
      } else if (esc == 'u' && i + 5 < json.size()) {
        // \uXXXX -> UTF-8. Only the BMP is handled; whisper output is
        // plain text, so surrogate pairs are rare here.
        unsigned code = 0;
        bool hex_ok = true;
        for (int k = 0; k < 4; ++k) {
          const char h = json[i + 2 + k];
          code <<= 4;
          if (h >= '0' && h <= '9') {
            code += static_cast<unsigned>(h - '0');
          } else if (h >= 'a' && h <= 'f') {
            code += static_cast<unsigned>(h - 'a' + 10);
          } else if (h >= 'A' && h <= 'F') {
            code += static_cast<unsigned>(h - 'A' + 10);
          } else {
            hex_ok = false;
          }
        }
        if (!hex_ok) {
          return false;
        }
        if (code < 0x80) {
          text += static_cast<char>(code);
        } else if (code < 0x800) {
          text += static_cast<char>(0xC0 | (code >> 6));
          text += static_cast<char>(0x80 | (code & 0x3F));
        } else {
          text += static_cast<char>(0xE0 | (code >> 12));
          text += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
          text += static_cast<char>(0x80 | (code & 0x3F));
        }
        i += 6;
      } else {
        // \" \\ \/ and anything else: keep the escaped char as-is.
        text += esc;
        i += 2;
      }
    } else {
      text += json[i];
      ++i;
    }
  }
  if (i >= json.size()) {
    return false;
  }
  *out = text;
  return true;
}

// Reads a whole file into memory. False when it cannot be opened/read.
bool ReadWholeFile(const std::string& path, std::vector<uint8_t>* out) {
  std::ifstream file(WideFromUtf8(path), std::ios::binary | std::ios::ate);
  if (!file) {
    return false;
  }
  const std::streamoff size = file.tellg();
  if (size < 0) {
    return false;
  }
  out->resize(static_cast<size_t>(size));
  file.seekg(0, std::ios::beg);
  if (size > 0) {
    file.read(reinterpret_cast<char*>(out->data()), size);
    if (!file) {
      return false;
    }
  }
  return true;
}

}  // namespace

DjVoiceChannel::DjVoiceChannel(flutter::BinaryMessenger* messenger)
    : channel_(messenger, "com.dhanunjay.dj/voice",
               &flutter::StandardMethodCodec::GetInstance()) {
  channel_.SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

DjVoiceChannel::~DjVoiceChannel() {
  // Unregister first: destroying the MethodChannel does not unregister
  // the handler, and a late Dart call must not reach a dead object.
  channel_.SetMethodCallHandler(nullptr);
  if (voice_ != nullptr) {
    voice_->Release();
    voice_ = nullptr;
  }
  if (whisper_running_) {
    ::TerminateProcess(whisper_process_.hProcess, 0);
    ::CloseHandle(whisper_process_.hProcess);
    ::CloseHandle(whisper_process_.hThread);
    whisper_running_ = false;
  }
}

ISpVoice* DjVoiceChannel::Voice() {
  if (voice_ != nullptr) {
    return voice_;
  }
  ISpVoice* created = nullptr;
  const HRESULT hr = ::CoCreateInstance(CLSID_SpVoice, nullptr, CLSCTX_ALL,
                                        IID_PPV_ARGS(&created));
  if (FAILED(hr) || created == nullptr) {
    return nullptr;
  }
  voice_ = created;
  return voice_;
}

std::string DjVoiceChannel::FindWhisperServer() const {
  const std::string dir = ExeDirectoryUtf8();
  if (dir.empty()) {
    return std::string();
  }
  const std::string direct = dir + "\\whisper-server.exe";
  if (PathExistsUtf8(direct)) {
    return direct;
  }
  const std::string subdir = dir + "\\whisper\\whisper-server.exe";
  if (PathExistsUtf8(subdir)) {
    return subdir;
  }
  return std::string();
}

bool DjVoiceChannel::IsWhisperRunning() const {
  if (!whisper_running_) {
    return false;
  }
  DWORD exit_code = 0;
  if (!::GetExitCodeProcess(whisper_process_.hProcess, &exit_code)) {
    return false;
  }
  return exit_code == STILL_ACTIVE;
}

void DjVoiceChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();

  if (method == "speak") {
    std::string text;
    if (!GetStringArg(call, "text", &text) || text.empty()) {
      result->Success(Err("speak needs a non-empty 'text' string."));
      return;
    }
    // SAPI: one persistent voice for the channel (see dj_voice_channel.h).
    // COM is initialized by main.cpp (CoInitializeEx, apartment-threaded);
    // ISpVoice works in an STA.
    ISpVoice* voice = Voice();
    if (voice == nullptr) {
      result->Success(Err("Windows speech (SAPI) is not available on this "
                          "computer (" +
                          LastErrorMessage() + ")."));
      return;
    }
    // SPF_ASYNC: Speak returns immediately; audio plays in the background.
    // SPF_IS_NOT_XML: the text is plain speech text, not SAPI XML markup.
    HRESULT hr = voice->Speak(WideFromUtf8(text).c_str(),
                              SPF_ASYNC | SPF_IS_NOT_XML, nullptr);
    if (FAILED(hr)) {
      result->Success(
          Err("Windows speech failed (" + LastErrorMessage() + ")."));
      return;
    }
    result->Success(OkWithMessage("Speaking."));
    return;
  }

  if (method == "stopSpeak") {
    ISpVoice* voice = Voice();
    if (voice == nullptr) {
      result->Success(Err("Windows speech (SAPI) is not available."));
      return;
    }
    // Speaking empty text with PURGEBEFORESPEAK clears the queue.
    HRESULT hr = voice->Speak(L"", SPF_ASYNC | SPF_PURGEBEFORESPEAK, nullptr);
    if (FAILED(hr)) {
      result->Success(
          Err("Could not stop speech (" + LastErrorMessage() + ")."));
      return;
    }
    result->Success(Ok());
    return;
  }

  if (method == "whisperStatus") {
    std::string model_path;
    GetStringArg(call, "modelPath", &model_path);  // Optional.
    const std::string server = FindWhisperServer();
    flutter::EncodableMap out;
    out[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
    out[flutter::EncodableValue("serverFound")] =
        flutter::EncodableValue(!server.empty());
    out[flutter::EncodableValue("serverPath")] =
        flutter::EncodableValue(server);
    out[flutter::EncodableValue("modelFound")] = flutter::EncodableValue(
        !model_path.empty() && PathExistsUtf8(model_path));
    out[flutter::EncodableValue("running")] =
        flutter::EncodableValue(IsWhisperRunning());
    result->Success(flutter::EncodableValue(std::move(out)));
    return;
  }

  if (method == "startWhisper") {
    std::string model_path;
    if (!GetStringArg(call, "modelPath", &model_path) ||
        model_path.empty()) {
      result->Success(Err("startWhisper needs a 'modelPath' string."));
      return;
    }
    if (IsWhisperRunning()) {
      result->Success(OkWithMessage("whisper-server is already running."));
      return;
    }
    if (whisper_running_) {
      // A previous sidecar exited on its own; close its handles first.
      ::CloseHandle(whisper_process_.hProcess);
      ::CloseHandle(whisper_process_.hThread);
      whisper_process_ = PROCESS_INFORMATION{};
      whisper_running_ = false;
    }
    const std::string server = FindWhisperServer();
    if (server.empty()) {
      result->Success(Err(kWhisperMissingMessage));
      return;
    }
    if (!PathExistsUtf8(model_path)) {
      result->Success(Err(std::string("Whisper model not found: ") +
                          model_path + ". " + kWhisperMissingMessage));
      return;
    }
    // whisper-server --model <ggml model> --host 127.0.0.1 --port 8080
    // (localhost only; the server never listens on the network).
    std::wstring command_line = L"\"";
    command_line += WideFromUtf8(server);
    command_line += L"\" --model \"";
    command_line += WideFromUtf8(model_path);
    command_line += L"\" --host 127.0.0.1 --port 8080";
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    // CREATE_NO_WINDOW: the sidecar runs without a console window.
    const BOOL ok = ::CreateProcessW(
        nullptr, command_line.data(), nullptr, nullptr, FALSE,
        CREATE_NO_WINDOW, nullptr, nullptr, &startup, &whisper_process_);
    if (!ok) {
      result->Success(Err(std::string("Could not start whisper-server (") +
                          LastErrorMessage() + ")."));
      return;
    }
    whisper_running_ = true;
    result->Success(
        OkWithMessage("whisper-server started on 127.0.0.1:8080."));
    return;
  }

  if (method == "transcribe") {
    std::string audio_path;
    if (!GetStringArg(call, "audioPath", &audio_path) ||
        audio_path.empty()) {
      result->Success(Err("transcribe needs an 'audioPath' string."));
      return;
    }
    if (!IsWhisperRunning()) {
      result->Success(
          Err(std::string("whisper-server is not running. Call startWhisper "
                          "first. ") +
              kWhisperMissingMessage));
      return;
    }
    std::vector<uint8_t> audio;
    if (!ReadWholeFile(audio_path, &audio)) {
      result->Success(
          Err("Could not read the audio file: " + audio_path + "."));
      return;
    }
    // POST multipart/form-data to /inference. Field name "file", filename
    // from the audio path's basename.
    const std::string boundary = "----dj-whisper-boundary";
    std::string filename = audio_path;
    const size_t slash = filename.find_last_of("\\/");
    if (slash != std::string::npos) {
      filename = filename.substr(slash + 1);
    }
    std::string body;
    body += "--" + boundary + "\r\n";
    body += "Content-Disposition: form-data; name=\"file\"; filename=\"" +
            filename + "\"\r\n";
    body += "Content-Type: application/octet-stream\r\n\r\n";
    const size_t header_len = body.size();
    body.resize(header_len + audio.size());
    if (!audio.empty()) {
      std::memcpy(&body[header_len], audio.data(), audio.size());
    }
    body += "\r\n--" + boundary + "--\r\n";

    HINTERNET session = ::WinHttpOpen(
        L"DJ whisper client", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (session == nullptr) {
      result->Success(
          Err("Could not open an HTTP session (" + LastErrorMessage() + ")."));
      return;
    }
    HINTERNET connection = ::WinHttpConnect(session, kWhisperHost,
                                            kWhisperPort, 0);
    if (connection == nullptr) {
      ::WinHttpCloseHandle(session);
      result->Success(Err("Could not connect to whisper-server at "
                          "127.0.0.1:8080 (" +
                          LastErrorMessage() + ")."));
      return;
    }
    HINTERNET request = ::WinHttpOpenRequest(
        connection, L"POST", L"/inference", nullptr, WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES, 0);
    if (request == nullptr) {
      ::WinHttpCloseHandle(connection);
      ::WinHttpCloseHandle(session);
      result->Success(Err("Could not open the inference request (" +
                          LastErrorMessage() + ")."));
      return;
    }
    const std::wstring content_type = WideFromUtf8(
        "Content-Type: multipart/form-data; boundary=" + boundary + "\r\n");
    const BOOL sent = ::WinHttpSendRequest(
        request, content_type.c_str(), static_cast<DWORD>(content_type.size()),
        const_cast<char*>(body.data()), static_cast<DWORD>(body.size()),
        static_cast<DWORD>(body.size()), 0);
    if (!sent || !::WinHttpReceiveResponse(request, nullptr)) {
      ::WinHttpCloseHandle(request);
      ::WinHttpCloseHandle(connection);
      ::WinHttpCloseHandle(session);
      result->Success(Err("whisper-server did not answer the transcription "
                          "request (" +
                          LastErrorMessage() + ")."));
      return;
    }
    std::string response;
    DWORD available = 0;
    DWORD read = 0;
    char chunk[4096];
    while (::WinHttpQueryDataAvailable(request, &available) && available > 0) {
      while (available > 0) {
        const DWORD to_read =
            available < sizeof(chunk)
                ? available
                : static_cast<DWORD>(sizeof(chunk));
        if (!::WinHttpReadData(request, chunk, to_read, &read) || read == 0) {
          break;
        }
        response.append(chunk, read);
        available -= read;
      }
    }
    ::WinHttpCloseHandle(request);
    ::WinHttpCloseHandle(connection);
    ::WinHttpCloseHandle(session);
    std::string text;
    if (!ExtractJsonTextField(response, &text)) {
      result->Success(Err("whisper-server replied, but the reply had no "
                          "transcript text."));
      return;
    }
    flutter::EncodableMap out;
    out[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
    out[flutter::EncodableValue("text")] = flutter::EncodableValue(text);
    result->Success(flutter::EncodableValue(std::move(out)));
    return;
  }

  result->Success(Err("Unknown voice method: " + method + "."));
}

}  // namespace dj
