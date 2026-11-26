// DJ voice channel (Windows). See dj_voice_channel.h.
//
// SAPI TTS works offline with no extra downloads. Whisper STT is a sidecar
// hook only: it launches a whisper.cpp whisper-server the user installed
// next to the app, and never invents a transcript when it is absent.

#include "dj_voice_channel.h"

#include <flutter/standard_method_codec.h>

#include <sapi.h>
#include <winhttp.h>

#include <algorithm>
#include <cmath>
#include <cstddef>
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
constexpr const wchar_t kVoiceMsgClassName[] = L"DJ_VOICE_MSG_WINDOW";
constexpr DWORD kMicSampleRate = 16000;
constexpr WORD kMicChannels = 1;
constexpr WORD kMicBits = 16;

void RegisterVoiceMsgClass() {
  static bool registered = false;
  if (registered) return;
  WNDCLASSW wc{};
  wc.lpfnWndProc = DjVoiceChannel::VoiceWndProc;
  wc.hInstance = ::GetModuleHandle(nullptr);
  wc.lpszClassName = kVoiceMsgClassName;
  ::RegisterClassW(&wc);
  registered = true;
}

std::string Base64EncodeBytes(const std::vector<uint8_t>& data) {
  static constexpr char kAlphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve(((data.size() + 2) / 3) * 4);
  size_t i = 0;
  while (i < data.size()) {
    const uint32_t b0 = data[i++];
    const bool has1 = i < data.size();
    const uint32_t b1 = has1 ? data[i++] : 0u;
    const bool has2 = i < data.size();
    const uint32_t b2 = has2 ? data[i++] : 0u;
    const uint32_t triple = (b0 << 16) | (b1 << 8) | b2;
    out.push_back(kAlphabet[(triple >> 18) & 0x3Fu]);
    out.push_back(kAlphabet[(triple >> 12) & 0x3Fu]);
    out.push_back(has1 ? kAlphabet[(triple >> 6) & 0x3Fu] : '=');
    out.push_back(has2 ? kAlphabet[triple & 0x3Fu] : '=');
  }
  return out;
}

int Base64Val(unsigned char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  return -1;
}

std::vector<uint8_t> Base64DecodeBytes(const std::string& input) {
  std::vector<uint8_t> out;
  out.reserve((input.size() / 4) * 3);
  int val = 0;
  int valb = -8;
  for (unsigned char c : input) {
    const int d = Base64Val(c);
    if (d == -1) {
      if (c == '=') break;
      continue;
    }
    val = (val << 6) + d;
    valb += 6;
    if (valb >= 0) {
      out.push_back(static_cast<uint8_t>((val >> valb) & 0xFF));
      valb -= 8;
    }
  }
  return out;
}

void AppendLe16(std::vector<uint8_t>* buf, uint16_t v) {
  buf->push_back(static_cast<uint8_t>(v & 0xFFu));
  buf->push_back(static_cast<uint8_t>((v >> 8) & 0xFFu));
}

void AppendLe32(std::vector<uint8_t>* buf, uint32_t v) {
  buf->push_back(static_cast<uint8_t>(v & 0xFFu));
  buf->push_back(static_cast<uint8_t>((v >> 8) & 0xFFu));
  buf->push_back(static_cast<uint8_t>((v >> 16) & 0xFFu));
  buf->push_back(static_cast<uint8_t>((v >> 24) & 0xFFu));
}

std::vector<uint8_t> BuildPcmWav(const std::vector<int16_t>& samples) {
  const uint32_t data_bytes = static_cast<uint32_t>(samples.size() * 2);
  std::vector<uint8_t> wav;
  wav.reserve(44 + data_bytes);
  wav.insert(wav.end(), {'R', 'I', 'F', 'F'});
  AppendLe32(&wav, 36 + data_bytes);
  wav.insert(wav.end(), {'W', 'A', 'V', 'E', 'f', 'm', 't', ' '});
  AppendLe32(&wav, 16);
  AppendLe16(&wav, 1);
  AppendLe16(&wav, kMicChannels);
  AppendLe32(&wav, kMicSampleRate);
  AppendLe32(&wav, kMicSampleRate * kMicChannels * (kMicBits / 8));
  AppendLe16(&wav, static_cast<uint16_t>(kMicChannels * (kMicBits / 8)));
  AppendLe16(&wav, kMicBits);
  wav.insert(wav.end(), {'d', 'a', 't', 'a'});
  AppendLe32(&wav, data_bytes);
  if (data_bytes > 0) {
    const uint8_t* raw = reinterpret_cast<const uint8_t*>(samples.data());
    wav.insert(wav.end(), raw, raw + data_bytes);
  }
  return wav;
}

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
  std::vector<uint8_t> discarded_wav;
  int64_t discarded_ms = 0;
  StopRecordingInternal(&discarded_wav, &discarded_ms);
  ::PlaySoundW(nullptr, nullptr, 0);
  if (msg_hwnd_ != nullptr) {
    ::KillTimer(msg_hwnd_, kLevelTimerId);
    ::DestroyWindow(msg_hwnd_);
    msg_hwnd_ = nullptr;
  }
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

LRESULT CALLBACK DjVoiceChannel::VoiceWndProc(HWND hwnd, UINT message,
                                              WPARAM wparam, LPARAM lparam) {
  if (message == WM_TIMER && wparam == kLevelTimerId) {
    auto* self = reinterpret_cast<DjVoiceChannel*>(
        ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (self != nullptr && self->recording_.load()) {
      double level = 0.0;
      bool emit_silence = false;
      {
        std::lock_guard<std::mutex> lock(self->mic_mutex_);
        level = self->latest_level_;
        if (self->speech_seen_ && self->speech_ms_ >= 350 &&
            self->silence_ms_ >= 1300 && !self->silence_emitted_) {
          self->silence_emitted_ = true;
          emit_silence = true;
        }
      }
      self->channel_.InvokeMethod(
          "onAudioLevel",
          std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
              {flutter::EncodableValue("level"), flutter::EncodableValue(level)},
          }));
      if (emit_silence) {
        self->channel_.InvokeMethod(
            "onSilenceDetected",
            std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{}));
      }
    }
    return 0;
  }
  return ::DefWindowProcW(hwnd, message, wparam, lparam);
}

void DjVoiceChannel::EnsureTimerWindow() {
  if (msg_hwnd_ != nullptr) return;
  RegisterVoiceMsgClass();
  msg_hwnd_ = ::CreateWindowExW(0, kVoiceMsgClassName, L"", 0, 0, 0, 0, 0,
                                HWND_MESSAGE, nullptr,
                                ::GetModuleHandle(nullptr), nullptr);
  if (msg_hwnd_ != nullptr) {
    ::SetWindowLongPtrW(msg_hwnd_, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(this));
  }
}

void DjVoiceChannel::StopRecordingInternal(std::vector<uint8_t>* out_wav,
                                           int64_t* out_ms) {
  const bool was_recording = recording_.exchange(false);
  if (msg_hwnd_ != nullptr) {
    ::KillTimer(msg_hwnd_, kLevelTimerId);
  }
  if (record_thread_.joinable()) {
    record_thread_.join();
  }
  if (was_recording) {
    std::lock_guard<std::mutex> lock(mic_mutex_);
    *out_wav = BuildPcmWav(pcm_samples_);
    *out_ms = static_cast<int64_t>((pcm_samples_.size() * 1000) / kMicSampleRate);
    std::fill(pcm_samples_.begin(), pcm_samples_.end(), int16_t{0});
    pcm_samples_.clear();
    latest_level_ = 0.0;
    speech_seen_ = false;
    silence_emitted_ = false;
    speech_ms_ = 0;
    silence_ms_ = 0;
  } else {
    out_wav->clear();
    *out_ms = 0;
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

  if (method == "startListening") {
    if (recording_.load()) {
      result->Success(OkWithMessage("Already listening."));
      return;
    }
    if (::waveInGetNumDevs() == 0) {
      result->Success(Err("No microphone found on this laptop."));
      return;
    }
    WAVEFORMATEX wf{};
    wf.wFormatTag = WAVE_FORMAT_PCM;
    wf.nChannels = kMicChannels;
    wf.nSamplesPerSec = kMicSampleRate;
    wf.wBitsPerSample = kMicBits;
    wf.nBlockAlign = (wf.nChannels * wf.wBitsPerSample) / 8;
    wf.nAvgBytesPerSec = wf.nSamplesPerSec * wf.nBlockAlign;

    HWAVEIN probe_in = nullptr;
    const MMRESULT open_res = ::waveInOpen(
        &probe_in, WAVE_MAPPER, &wf, 0, 0, CALLBACK_NULL);
    if (open_res != MMSYSERR_NOERROR || probe_in == nullptr) {
      result->Success(Err("Could not open the microphone."));
      return;
    }
    {
      std::lock_guard<std::mutex> lock(mic_mutex_);
      pcm_samples_.clear();
      latest_level_ = 0.0;
      speech_seen_ = false;
      silence_emitted_ = false;
      speech_ms_ = 0;
      silence_ms_ = 0;
    }
    recording_.store(true);
    EnsureTimerWindow();
    if (msg_hwnd_ != nullptr) {
      ::SetTimer(msg_hwnd_, kLevelTimerId, 60, nullptr);
    }
    record_thread_ = std::thread([this, probe_in]() {
      constexpr int kBufCount = 4;
      constexpr DWORD kChunkSamples = 800;  // 50 ms at 16 kHz
      std::vector<std::vector<int16_t>> buffers(
          kBufCount, std::vector<int16_t>(kChunkSamples, 0));
      WAVEHDR headers[kBufCount]{};
      for (int i = 0; i < kBufCount; ++i) {
        headers[i].lpData = reinterpret_cast<LPSTR>(buffers[i].data());
        headers[i].dwBufferLength = kChunkSamples * sizeof(int16_t);
        ::waveInPrepareHeader(probe_in, &headers[i], sizeof(WAVEHDR));
        ::waveInAddBuffer(probe_in, &headers[i], sizeof(WAVEHDR));
      }
      ::waveInStart(probe_in);
      while (recording_.load()) {
        bool any_done = false;
        for (int i = 0; i < kBufCount; ++i) {
          if ((headers[i].dwFlags & WHDR_DONE) != 0) {
            any_done = true;
            const size_t count = headers[i].dwBytesRecorded / sizeof(int16_t);
            if (count > 0) {
              double sum_sq = 0.0;
              for (size_t s = 0; s < count; ++s) {
                const double v = static_cast<double>(buffers[i][s]) / 32768.0;
                sum_sq += v * v;
              }
              const double rms = std::sqrt(sum_sq / static_cast<double>(count));
              const double norm = std::min(1.0, rms * 8.0);
              std::lock_guard<std::mutex> lock(mic_mutex_);
              // Cap buffer at ~45 s to keep memory bounded.
              if (pcm_samples_.size() < kMicSampleRate * 45) {
                pcm_samples_.insert(
                    pcm_samples_.end(), buffers[i].begin(),
                    buffers[i].begin() + static_cast<std::ptrdiff_t>(count));
              }
              latest_level_ = norm;
              if (rms > 0.015) {
                speech_seen_ = true;
                speech_ms_ += 50;
                silence_ms_ = 0;
              } else if (speech_seen_) {
                silence_ms_ += 50;
              }
            }
            if (recording_.load()) {
              headers[i].dwFlags &= ~WHDR_DONE;
              headers[i].dwBytesRecorded = 0;
              ::waveInAddBuffer(probe_in, &headers[i], sizeof(WAVEHDR));
            }
          }
        }
        if (!any_done) {
          ::Sleep(15);
        }
      }
      ::waveInStop(probe_in);
      ::waveInReset(probe_in);
      for (int i = 0; i < kBufCount; ++i) {
        ::waveInUnprepareHeader(probe_in, &headers[i], sizeof(WAVEHDR));
      }
      ::waveInClose(probe_in);
    });
    result->Success(OkWithMessage("Listening."));
    return;
  }

  if (method == "stopListening") {
    std::vector<uint8_t> wav;
    int64_t duration_ms = 0;
    StopRecordingInternal(&wav, &duration_ms);
    flutter::EncodableMap out;
    out[flutter::EncodableValue("ok")] = flutter::EncodableValue(!wav.empty());
    out[flutter::EncodableValue("wavBase64")] =
        flutter::EncodableValue(Base64EncodeBytes(wav));
    out[flutter::EncodableValue("durationMs")] =
        flutter::EncodableValue(duration_ms);
    result->Success(flutter::EncodableValue(std::move(out)));
    return;
  }

  if (method == "playAudio") {
    std::string b64;
    if (!GetStringArg(call, "wavBase64", &b64) || b64.empty()) {
      result->Success(Err("playAudio needs 'wavBase64'."));
      return;
    }
    std::vector<uint8_t> decoded = Base64DecodeBytes(b64);
    if (decoded.size() <= 44) {
      result->Success(Err("playAudio received malformed WAV bytes."));
      return;
    }
    ::PlaySoundW(nullptr, nullptr, 0);
    playback_wav_ = std::move(decoded);
    const BOOL played = ::PlaySoundW(
        reinterpret_cast<LPCWSTR>(playback_wav_.data()), nullptr,
        SND_MEMORY | SND_ASYNC | SND_NODEFAULT);
    if (!played) {
      result->Success(Err("Could not play audio."));
      return;
    }
    result->Success(OkWithMessage("Playing."));
    return;
  }

  if (method == "stopSpeak" || method == "stopSpeaking") {
    ::PlaySoundW(nullptr, nullptr, 0);
    ISpVoice* voice = Voice();
    if (voice != nullptr) {
      voice->Speak(L"", SPF_ASYNC | SPF_PURGEBEFORESPEAK, nullptr);
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
