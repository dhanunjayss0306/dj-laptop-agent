// In-memory webcam capture via Media Foundation (Privacy Screen).
//
// Design ported from SafeScreen by kv4u (MIT) — see THIRD_PARTY_NOTICES.md.
// This file is DJ's own implementation of that design, adapted to DJ's
// channel conventions (channel "com.dhanunjay.dj/privacy_camera", replies
// always {"ok": bool, ...} per dj_channel_utils.h) and extended with a
// listDevices method, which DJ needs because it has no camera_windows
// fallback to enumerate devices.
//
// Why Media Foundation instead of the Flutter camera plugin: the
// plugin's only way to obtain a frame is takePicture(), which encodes a
// JPEG to disk before Dart ever sees it. For a feature whose whole
// purpose is privacy, writing thousands of photographs of the user to
// the filesystem is the wrong default, however quickly they are erased
// afterwards. This reads frames straight out of Media Foundation into a
// buffer and hands them to Dart over a method channel. Nothing touches
// the disk.
//
// Threading: ReadSample blocks until the sensor delivers the next frame,
// roughly one frame interval. Doing that on the platform thread would
// freeze the UI for that long on every grab, so a dedicated capture
// thread owns Media Foundation outright: it creates the reader, reads
// from it and shuts it down, in its own multithreaded COM apartment.
// Flutter replies must be sent on the platform thread, so the capture
// thread never touches a MethodResult: it queues the finished reply and
// posts kDjCameraDoneMessage to the runner window, whose message handler
// (on the platform thread) calls HandleDjCameraMessage to deliver it.
//
// Methods:
//   listDevices()            -> {ok, devices: [{name, deviceId}]}
//   start(deviceId?, deviceName?) -> {ok, device, width, height}
//   grab()                   -> {ok, bytes, width, height, stride}
//                              (ok with no bytes = no frame this time)
//   effects()                -> {ok, backgroundBlur, autoFraming}
//                              (null = the camera did not answer)
//   stop()                   -> {ok}

#ifndef RUNNER_DJ_CAMERA_CHANNEL_H_
#define RUNNER_DJ_CAMERA_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

// Posted by the capture thread to the runner window when a reply is ready.
// The window's message handler must pass it to HandleDjCameraMessage.
// WM_APP + 0x5C is free in this runner (the tray uses WM_APP + 100).
constexpr UINT kDjCameraDoneMessage = WM_APP + 0x5C;

// Registers the "com.dhanunjay.dj/privacy_camera" method channel on the
// engine's messenger. |window| receives kDjCameraDoneMessage, so replies
// can be delivered on the platform thread.
void RegisterDjCameraChannel(flutter::BinaryMessenger* messenger,
                             HWND window);

// Call from the runner window's message handler. Returns true if |message|
// was the capture thread's reply notification and has been handled.
bool HandleDjCameraMessage(UINT message);

// Stops the camera and joins the capture thread. Call before the engine
// is destroyed.
void ShutdownDjCamera();

#endif  // RUNNER_DJ_CAMERA_CHANNEL_H_
