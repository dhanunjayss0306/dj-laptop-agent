# Third-party notices

DJ includes work from other open-source projects. This file lists them
and their licenses.

## SafeScreen

DJ's Privacy Screen feature is based on SafeScreen by kv4u
(https://github.com/kv4u/safescreen), MIT license. The design — on-device
BlazeFace detection, pure-Dart head-pose estimation and gaze state
machine, in-memory Media Foundation capture, and the multi-monitor
blackout geometry — was ported from SafeScreen and adapted to DJ. DJ's
implementation is DJ's own code written from that design; the MIT
attribution below is kept as the license requires.

```
MIT License

Copyright (c) 2026 SafeScreen contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## BlazeFace face-detection model

The Privacy Screen's face detector uses the BlazeFace model from Google
MediaPipe, which ships inside the `face_detection_tflite` Flutter
package (`assets/models/face_detection_front.tflite`). The model is
bundled with the app by the Flutter tool — DJ downloads no model at
runtime. BlazeFace is released under the Apache License 2.0
(https://github.com/google-ai-edge/mediapipe/blob/master/LICENSE).
