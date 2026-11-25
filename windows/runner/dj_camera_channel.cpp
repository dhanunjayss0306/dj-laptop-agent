// In-memory webcam capture via Media Foundation. See dj_camera_channel.h.
//
// Design ported from SafeScreen by kv4u (MIT) — see THIRD_PARTY_NOTICES.md.
// DJ's own implementation of that design: same threading architecture
// (dedicated capture thread, replies delivered on the platform thread via
// a window message), DJ channel name and reply shape, plus listDevices.

#include "dj_camera_channel.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>

// <initguid.h> instantiates the DEFINE_GUID symbols from the KS headers
// below (notably KSPROPERTYSETID_ExtendedCameraControl) in this
// translation unit. Without it the GUID is only an extern declaration
// and the link needs ksguid.lib, which the Windows SDK does not ship;
// with it no extra library is required.
#include <initguid.h>

// ks.h must precede ksmedia.h and ksproxy.h.
#include <ks.h>
#include <ksmedia.h>
#include <ksproxy.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <shlwapi.h>
#include <wrl/client.h>

#include <cctype>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "dj_channel_utils.h"

using Microsoft::WRL::ComPtr;

namespace {

bool EqualsIgnoreCase(const std::string& a, const std::string& b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); i++) {
    if (std::tolower(static_cast<unsigned char>(a[i])) !=
        std::tolower(static_cast<unsigned char>(b[i]))) {
      return false;
    }
  }
  return true;
}

// Reads a string attribute from a device activation object as UTF-8.
std::string DeviceString(IMFActivate* device, const GUID& key) {
  wchar_t* value = nullptr;
  UINT32 len = 0;
  if (FAILED(device->GetAllocatedString(key, &value, &len))) {
    return std::string();
  }
  std::string utf8 = dj::Utf8FromWide(std::wstring(value, len));
  CoTaskMemFree(value);
  return utf8;
}

// Enumerates video capture devices. On success returns true and fills
// |names| (friendly names) and |paths| (device paths, the exact identity
// used to open a specific camera). The caller owns the IMFActivate
// pointers in |out| and must release them.
bool EnumDevices(std::vector<IMFActivate*>* out, std::vector<std::string>* names,
                 std::vector<std::string>* paths) {
  ComPtr<IMFAttributes> config;
  HRESULT hr = MFCreateAttributes(&config, 1);
  if (FAILED(hr)) return false;
  config->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                  MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
  IMFActivate** devices = nullptr;
  UINT32 count = 0;
  hr = MFEnumDeviceSources(config.Get(), &devices, &count);
  if (FAILED(hr) || count == 0) {
    if (devices != nullptr) CoTaskMemFree(devices);
    return false;
  }
  for (UINT32 i = 0; i < count; i++) {
    out->push_back(devices[i]);
    names->push_back(
        DeviceString(devices[i], MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME));
    paths->push_back(DeviceString(
        devices[i], MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK));
  }
  CoTaskMemFree(devices);
  return true;
}

// Owns the Media Foundation reader for one camera.
//
// Used only from the capture thread. ReadSample blocks until a frame is
// available, roughly one frame interval for a running camera. The first
// read after Start is slower because the sensor is still waking up, so
// Start performs one discarded read and absorbs that delay there rather
// than letting the first grab() appear to hang.
class DjCamera {
 public:
  ~DjCamera() { Stop(); }

  // Opens the camera whose device path is |device_id|, or failing that
  // whose friendly name is |preferred_name|. With neither given, opens
  // the first.
  //
  // If a camera was asked for and is not found, this fails rather than
  // opening another one. Silently opening "the first camera" could hand
  // the detector a virtual camera — exactly what the Dart side chose to
  // avoid.
  bool Start(const std::string& device_id, const std::string& preferred_name,
             std::string* device_out, int* width_out, int* height_out,
             std::string* error_out) {
    Stop();

    HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
    if (FAILED(hr)) {
      *error_out = "MFStartup failed";
      return false;
    }
    mf_started_ = true;

    std::vector<IMFActivate*> devices;
    std::vector<std::string> names;
    std::vector<std::string> paths;
    if (!EnumDevices(&devices, &names, &paths)) {
      *error_out = "no video capture devices";
      return false;
    }
    const UINT32 count = static_cast<UINT32>(devices.size());

    const bool wants_specific = !device_id.empty() || !preferred_name.empty();
    int by_id = -1;
    int by_name = -1;
    for (UINT32 i = 0; i < count; i++) {
      if (by_id < 0 && !device_id.empty() &&
          EqualsIgnoreCase(paths[i], device_id)) {
        by_id = static_cast<int>(i);
      }
      if (by_name < 0 && !preferred_name.empty() && names[i] == preferred_name) {
        by_name = static_cast<int>(i);
      }
    }

    int chosen_index = by_id >= 0 ? by_id : by_name;
    if (chosen_index < 0) {
      if (wants_specific) {
        for (UINT32 i = 0; i < count; i++) devices[i]->Release();
        *error_out = "requested camera not found";
        return false;
      }
      chosen_index = 0;
    }
    const UINT32 chosen = static_cast<UINT32>(chosen_index);
    const std::string chosen_name = names[chosen];

    ComPtr<IMFMediaSource> source;
    hr = devices[chosen]->ActivateObject(IID_PPV_ARGS(&source));
    for (UINT32 i = 0; i < count; i++) devices[i]->Release();
    if (FAILED(hr)) {
      *error_out = "could not activate camera";
      return false;
    }

    // Kept for QueryEffects. Optional: a camera that does not expose its
    // controls still captures, it just cannot be asked about effects.
    source.As(&ks_);

    ComPtr<IMFAttributes> reader_attrs;
    hr = MFCreateAttributes(&reader_attrs, 1);
    if (SUCCEEDED(hr)) {
      // Lets the reader insert a converter, so RGB32 can be requested
      // whether the sensor speaks NV12, YUY2 or MJPG.
      reader_attrs->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
    }

    hr = MFCreateSourceReaderFromMediaSource(source.Get(), reader_attrs.Get(),
                                             &reader_);
    if (FAILED(hr)) {
      *error_out = "could not create source reader";
      return false;
    }

    ComPtr<IMFMediaType> rgb;
    hr = MFCreateMediaType(&rgb);
    if (FAILED(hr)) {
      *error_out = "MFCreateMediaType failed";
      return false;
    }
    rgb->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    rgb->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    hr = reader_->SetCurrentMediaType(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr,
        rgb.Get());
    if (FAILED(hr)) {
      *error_out = "camera would not provide RGB32";
      return false;
    }

    ComPtr<IMFMediaType> current;
    hr = reader_->GetCurrentMediaType(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), &current);
    if (FAILED(hr)) {
      *error_out = "could not read negotiated media type";
      return false;
    }

    UINT32 w = 0;
    UINT32 h = 0;
    MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &w, &h);
    if (w == 0 || h == 0) {
      *error_out = "camera reported a zero frame size";
      return false;
    }
    width_ = static_cast<int>(w);
    height_ = static_cast<int>(h);

    UINT32 raw_stride = 0;
    if (SUCCEEDED(current->GetUINT32(MF_MT_DEFAULT_STRIDE, &raw_stride))) {
      stride_ = static_cast<int>(static_cast<INT32>(raw_stride));
    } else {
      stride_ = width_ * 4;
    }

    // Absorb sensor warm-up here rather than in the first grab().
    std::vector<uint8_t> discard;
    int dw = 0;
    int dh = 0;
    int ds = 0;
    Grab(&discard, &dw, &dh, &ds);

    *device_out = chosen_name;
    *width_out = width_;
    *height_out = height_;
    return true;
  }

  // Reads one frame. Returns false when no usable frame arrived.
  bool Grab(std::vector<uint8_t>* out, int* width, int* height, int* stride) {
    if (!reader_) return false;

    DWORD stream_flags = 0;
    ComPtr<IMFSample> sample;
    HRESULT hr = reader_->ReadSample(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0, nullptr,
        &stream_flags, nullptr, &sample);
    if (FAILED(hr) || sample == nullptr) return false;

    ComPtr<IMFMediaBuffer> buffer;
    hr = sample->ConvertToContiguousBuffer(&buffer);
    if (FAILED(hr)) return false;

    BYTE* data = nullptr;
    DWORD max_len = 0;
    DWORD current_len = 0;
    hr = buffer->Lock(&data, &max_len, &current_len);
    if (FAILED(hr)) return false;

    out->assign(data, data + current_len);
    buffer->Unlock();

    *width = width_;
    *height = height_;
    *stride = stride_;
    return true;
  }

  // Asks the camera whether it is applying effects that can remove a
  // second person from the picture. Each value is 1 (on), 0 (off) or -1
  // (the camera did not say). See lib/features/privacy_screen/
  // camera_effects.dart for why these two and not eye-contact correction.
  //
  // Windows Studio Effects and capable drivers expose these through the
  // standard extended camera controls, and they can be toggled at any
  // time from Settings or the quick-settings flyout, so the Dart side
  // asks periodically.
  void QueryEffects(int* blur, int* framing) {
    *blur = -1;
    *framing = -1;
    if (!ks_) return;
#ifdef KSCAMERA_EXTENDEDPROP_BACKGROUNDSEGMENTATION_BLUR
    ULONGLONG blur_mask = KSCAMERA_EXTENDEDPROP_BACKGROUNDSEGMENTATION_BLUR;
#ifdef KSCAMERA_EXTENDEDPROP_BACKGROUNDSEGMENTATION_SHALLOWFOCUS
    // "Portrait" blur. MASK is not included: it only attaches a
    // segmentation mask as metadata and leaves the picture itself
    // untouched.
    blur_mask |= KSCAMERA_EXTENDEDPROP_BACKGROUNDSEGMENTATION_SHALLOWFOCUS;
#endif
    *blur = ExtendedFlag(
        KSPROPERTY_CAMERACONTROL_EXTENDED_BACKGROUNDSEGMENTATION, blur_mask);
#endif
#ifdef KSCAMERA_EXTENDEDPROP_DIGITALWINDOW_AUTOFACEFRAMING
    *framing = ExtendedFlag(KSPROPERTY_CAMERACONTROL_EXTENDED_DIGITALWINDOW,
                            KSCAMERA_EXTENDEDPROP_DIGITALWINDOW_AUTOFACEFRAMING);
#endif
  }

  void Stop() {
    ks_.Reset();
    reader_.Reset();
    if (mf_started_) {
      MFShutdown();
      mf_started_ = false;
    }
    width_ = 0;
    height_ = 0;
    stride_ = 0;
  }

 private:
  // Reads one extended camera control and reports whether any bit of
  // |on_mask| is set: 1 on, 0 off, -1 not answered.
  int ExtendedFlag(ULONG id, ULONGLONG on_mask) {
    KSPROPERTY prop = {};
    prop.Set = KSPROPERTYSETID_ExtendedCameraControl;
    prop.Id = id;
    prop.Flags = KSPROPERTY_TYPE_GET;

    // The header, plus room for whichever payload this control carries;
    // the digital window's is larger than a plain value.
    alignas(8) BYTE buffer[sizeof(KSCAMERA_EXTENDEDPROP_HEADER) + 256] = {};
    ULONG returned = 0;
    HRESULT hr = ks_->KsProperty(&prop, sizeof(prop), buffer, sizeof(buffer),
                                 &returned);
    if (FAILED(hr)) return -1;

    // Where the header sits is not something to assume. Through this path
    // the Windows Studio Effects pipeline returns it 16 bytes into the
    // buffer, after a block of zeros, while the WinRT camera API strips
    // that prefix. Reading from offset 0 there took the header's version
    // and size fields for its flags and capability, and reported blur
    // that was on as off. So accept a header only where it is
    // self-consistent: version 1 (the only one defined) and a size that
    // fits in what was returned.
    const KSCAMERA_EXTENDEDPROP_HEADER* header = nullptr;
    for (ULONG offset : {0UL, 16UL}) {
      if (returned < offset + sizeof(KSCAMERA_EXTENDEDPROP_HEADER)) continue;
      const auto* candidate =
          reinterpret_cast<const KSCAMERA_EXTENDEDPROP_HEADER*>(buffer +
                                                                offset);
      if (candidate->Version == 1 &&
          candidate->Size >= sizeof(KSCAMERA_EXTENDEDPROP_HEADER) &&
          offset + candidate->Size <= returned) {
        header = candidate;
        break;
      }
    }
    if (header == nullptr) return -1;

    // A camera that cannot apply the effect at all is not applying it.
    if ((header->Capability & on_mask) == 0) return 0;
    return (header->Flags & on_mask) != 0 ? 1 : 0;
  }

  ComPtr<IKsControl> ks_;
  ComPtr<IMFSourceReader> reader_;
  bool mf_started_ = false;
  int width_ = 0;
  int height_ = 0;
  int stride_ = 0;
};

// ---------------------------------------------------------------------------
// Threading (see dj_camera_channel.h): the capture thread owns Media
// Foundation; replies are queued and delivered on the platform thread.
// ---------------------------------------------------------------------------

using MethodResultPtr =
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>;

struct Job {
  enum class Kind { kListDevices, kStart, kGrab, kEffects, kStop, kQuit };
  Kind kind = Kind::kQuit;
  std::string device_id;
  std::string preferred_name;
  MethodResultPtr result;
};

// A finished reply, ready to be delivered on the platform thread.
// Always a DJ {"ok": bool, ...} map — never result->Error — so the Dart
// side receives a Map instead of a thrown PlatformException.
struct Reply {
  MethodResultPtr result;
  flutter::EncodableValue value;
};

class CaptureWorker {
 public:
  explicit CaptureWorker(HWND window) : window_(window) {
    thread_ = std::thread([this] { Run(); });
  }

  ~CaptureWorker() { Shutdown(); }

  CaptureWorker(const CaptureWorker&) = delete;
  CaptureWorker& operator=(const CaptureWorker&) = delete;

  void Post(Job job) {
    {
      std::lock_guard<std::mutex> lock(mu_);
      jobs_.push_back(std::move(job));
    }
    cv_.notify_one();
  }

  // Platform thread only: hands finished replies back to Dart.
  void DeliverReplies() {
    std::deque<Reply> ready;
    {
      std::lock_guard<std::mutex> lock(mu_);
      ready.swap(replies_);
    }
    for (Reply& r : ready) {
      if (r.result) r.result->Success(r.value);
    }
  }

  // Stops the camera and joins the thread. Replies not yet delivered are
  // dropped: the engine they would go to is being torn down.
  void Shutdown() {
    if (!thread_.joinable()) return;
    Post(Job{});  // kQuit
    thread_.join();
    std::lock_guard<std::mutex> lock(mu_);
    replies_.clear();
    jobs_.clear();
  }

 private:
  void Run() {
    const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    DjCamera camera;
    bool started = false;

    for (;;) {
      Job job;
      {
        std::unique_lock<std::mutex> lock(mu_);
        cv_.wait(lock, [this] { return !jobs_.empty(); });
        job = std::move(jobs_.front());
        jobs_.pop_front();
      }
      if (job.kind == Job::Kind::kQuit) break;

      flutter::EncodableValue value = Handle(&camera, &started, job);
      Reply reply;
      reply.result = std::move(job.result);
      reply.value = std::move(value);
      {
        std::lock_guard<std::mutex> lock(mu_);
        replies_.push_back(std::move(reply));
      }
      ::PostMessage(window_, kDjCameraDoneMessage, 0, 0);
    }

    camera.Stop();
    if (SUCCEEDED(co)) CoUninitialize();
  }

  static flutter::EncodableValue Handle(DjCamera* camera, bool* started,
                                        const Job& job) {
    switch (job.kind) {
      case Job::Kind::kListDevices: {
        // Media Foundation must be up before enumerating.
        HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
        if (FAILED(hr)) return dj::Err("MFStartup failed");
        std::vector<IMFActivate*> devices;
        std::vector<std::string> names;
        std::vector<std::string> paths;
        if (!EnumDevices(&devices, &names, &paths)) {
          MFShutdown();
          return dj::Err("no video capture devices");
        }
        flutter::EncodableList list;
        for (size_t i = 0; i < devices.size(); i++) {
          flutter::EncodableMap entry;
          entry[flutter::EncodableValue("name")] =
              flutter::EncodableValue(names[i]);
          entry[flutter::EncodableValue("deviceId")] =
              flutter::EncodableValue(paths[i]);
          list.push_back(flutter::EncodableValue(entry));
          devices[i]->Release();
        }
        MFShutdown();
        flutter::EncodableMap out;
        out[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
        out[flutter::EncodableValue("devices")] =
            flutter::EncodableValue(list);
        return flutter::EncodableValue(out);
      }

      case Job::Kind::kStart: {
        std::string device;
        std::string error;
        int w = 0;
        int h = 0;
        if (!camera->Start(job.device_id, job.preferred_name, &device, &w, &h,
                           &error)) {
          camera->Stop();
          *started = false;
          return dj::Err(error);
        }
        *started = true;
        flutter::EncodableMap out;
        out[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
        out[flutter::EncodableValue("device")] =
            flutter::EncodableValue(device);
        out[flutter::EncodableValue("width")] = flutter::EncodableValue(w);
        out[flutter::EncodableValue("height")] = flutter::EncodableValue(h);
        return flutter::EncodableValue(out);
      }

      case Job::Kind::kGrab: {
        if (!*started) {
          return dj::Err("camera is not running");
        }
        std::vector<uint8_t> bytes;
        int w = 0;
        int h = 0;
        int s = 0;
        if (!camera->Grab(&bytes, &w, &h, &s)) {
          // No frame this time. The Dart side treats that as a detector
          // blind spot and therefore protects the screen.
          return dj::Ok();
        }
        flutter::EncodableMap out;
        out[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
        out[flutter::EncodableValue("bytes")] =
            flutter::EncodableValue(bytes);
        out[flutter::EncodableValue("width")] = flutter::EncodableValue(w);
        out[flutter::EncodableValue("height")] = flutter::EncodableValue(h);
        out[flutter::EncodableValue("stride")] = flutter::EncodableValue(s);
        return flutter::EncodableValue(out);
      }

      case Job::Kind::kEffects: {
        int blur = -1;
        int framing = -1;
        if (*started) camera->QueryEffects(&blur, &framing);
        // Unanswered is sent as null, never as false: "the camera did
        // not say" must not read as "off".
        auto encode = [](int v) {
          return v < 0 ? flutter::EncodableValue()
                       : flutter::EncodableValue(v == 1);
        };
        flutter::EncodableMap out;
        out[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
        out[flutter::EncodableValue("backgroundBlur")] = encode(blur);
        out[flutter::EncodableValue("autoFraming")] = encode(framing);
        return flutter::EncodableValue(out);
      }

      case Job::Kind::kStop:
        camera->Stop();
        *started = false;
        return dj::Ok();

      case Job::Kind::kQuit:
        break;
    }
    return dj::Ok();
  }

  HWND window_;
  std::mutex mu_;
  std::condition_variable cv_;
  std::deque<Job> jobs_;
  std::deque<Reply> replies_;
  // Declared last so every member above exists before the thread starts.
  std::thread thread_;
};

std::unique_ptr<CaptureWorker> g_worker;

// The channel must outlive RegisterDjCameraChannel for the handler to keep
// receiving messages, so it is retained until ShutdownDjCamera.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

}  // namespace

void RegisterDjCameraChannel(flutter::BinaryMessenger* messenger,
                             HWND window) {
  g_worker = std::make_unique<CaptureWorker>(window);
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.dhanunjay.dj/privacy_camera",
      &flutter::StandardMethodCodec::GetInstance());

  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         MethodResultPtr result) {
        if (!g_worker) {
          result->Success(dj::Err("capture has been shut down"));
          return;
        }
        const std::string& method = call.method_name();
        Job job;
        job.result = std::move(result);

        if (method == "listDevices") {
          job.kind = Job::Kind::kListDevices;
        } else if (method == "start") {
          job.kind = Job::Kind::kStart;
          std::string value;
          if (dj::GetStringArg(call, "deviceId", &value)) {
            job.device_id = value;
          }
          if (dj::GetStringArg(call, "deviceName", &value)) {
            job.preferred_name = value;
          }
        } else if (method == "grab") {
          job.kind = Job::Kind::kGrab;
        } else if (method == "effects") {
          job.kind = Job::Kind::kEffects;
        } else if (method == "stop") {
          job.kind = Job::Kind::kStop;
        } else {
          job.result->Success(
              dj::Err("Unknown privacy camera method: " + method + "."));
          return;
        }
        g_worker->Post(std::move(job));
      });
}

bool HandleDjCameraMessage(UINT message) {
  if (message != kDjCameraDoneMessage) return false;
  if (g_worker) g_worker->DeliverReplies();
  return true;
}

void ShutdownDjCamera() {
  g_channel.reset();
  g_worker.reset();
}
