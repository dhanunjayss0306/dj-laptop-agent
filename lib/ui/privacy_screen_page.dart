// Privacy Screen page.
//
// The laptop webcam watches whether the user is looking at the screen.
// Look away, walk off, or a second face appears over the shoulder —
// the whole screen goes black until only the user is looking again.
// If the camera or detector fails, the screen protects itself.
//
// White flat design law, like the rest of DJ. Based on SafeScreen by
// kv4u (MIT) — see THIRD_PARTY_NOTICES.md. Fully local: no network, no
// keys, no telemetry. Frames never leave this laptop and are never saved.
import 'dart:io';

import 'package:flutter/material.dart';

import '../features/privacy_screen/head_pose.dart';
import '../features/privacy_screen/privacy_screen_controller.dart';
import '../features/privacy_screen/privacy_screen_service.dart';
import '../theme.dart';
import 'app_state.dart';

class PrivacyScreenPage extends StatelessWidget {
  const PrivacyScreenPage({super.key, required this.app});

  final DjAppState app;

  PrivacyScreenController get _controller => app.privacyScreen;

  @override
  Widget build(BuildContext context) {
    final PrivacyScreenController controller = _controller;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Privacy Screen',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              const Text(
                'Your webcam watches whether you are looking at the screen. '
                'Look away, walk off, or someone looks over your shoulder — '
                'the screen goes black until only you are looking again.',
              ),
              const SizedBox(height: 16),
              if (!Platform.isWindows) _laptopOnlyCard(),
              if (Platform.isWindows) ...[
                _statusCard(controller),
                const SizedBox(height: 12),
                _settingsCard(controller),
                const SizedBox(height: 12),
                _howItWorksCard(),
              ],
              const SizedBox(height: 12),
              _aboutCard(),
            ],
          ),
        );
      },
    );
  }

  Widget _laptopOnlyCard() {
    return _card(
      title: 'Laptop-only',
      child: const Text(
        'Privacy Screen is laptop-only. It needs a Windows laptop with a '
        'webcam, so it does not run on this phone.',
      ),
    );
  }

  Widget _statusCard(PrivacyScreenController controller) {
    final PrivacyScreenService service = controller.service;
    final bool running = controller.isRunning;
    final bool overrideOn = controller.isOverrideOn;
    return _card(
      title: 'Status',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            controller.statusMessage,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: overrideOn
                  ? DjColors.amber
                  : controller.isProtected
                      ? DjColors.red
                      : DjColors.ink,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            running
                ? (overrideOn
                    ? 'Protection is paused. The screen stays visible until '
                        'you resume.'
                    : controller.isBlackedOut
                        ? 'The screen is black. Look at the screen to reveal it.'
                        : 'You are looking at the screen.')
                : 'Protection is off. The screen never blacks out while it is off.',
          ),
          if (overrideOn) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF8E1),
                border: Border.all(color: DjColors.amber),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    kPrivacyOverrideMessage,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () => controller.setOverride(false),
                    child: const Text('Resume protection'),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              ElevatedButton(
                onPressed: controller.isStarting
                    ? null
                    : running
                        ? () => controller.stopProtection()
                        : () => controller.startProtection(),
                child: Text(
                  controller.isStarting
                      ? 'Starting...'
                      : running
                          ? 'Stop protection'
                          : 'Start protection',
                ),
              ),
              if (overrideOn) ...[
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => controller.setOverride(false),
                  child: const Text('Resume protection'),
                ),
              ],
            ],
          ),
          if (controller.error != null) ...[
            const SizedBox(height: 8),
            Text(
              controller.error!,
              style: const TextStyle(color: DjColors.red),
            ),
          ],
          if (controller.hotkeyError != null) ...[
            const SizedBox(height: 8),
            Text(controller.hotkeyError!),
          ],
          if (running) ...[
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 8),
            Text('Camera: ${service.cameraName ?? 'starting...'}'),
            if (service.isVirtualCamera) ...[
              const SizedBox(height: 4),
              const Text(
                'This is virtual-camera software, not a real webcam. '
                'Background blur or replacement in it can hide a person '
                'standing behind you, so shoulder-surfer detection cannot '
                'be relied on while this camera is in use.',
                style: TextStyle(color: DjColors.amber),
              ),
            ],
            if (service.effects.hidesOthers) ...[
              const SizedBox(height: 4),
              Text(
                'Camera effects on (${service.effects.summary}). They can '
                'hide a person standing behind you, so shoulder-surfer '
                'detection is limited while they are on. Turn them off in '
                'Windows Settings > Bluetooth & devices > Cameras.',
                style: const TextStyle(color: DjColors.amber),
              ),
            ],
            if (!service.isPitchCalibrated) ...[
              const SizedBox(height: 4),
              const Text(
                'Learning your neutral head position — look straight at the '
                'screen for a few seconds.',
              ),
            ],
            if (service.lastPose != null) ...[
              const SizedBox(height: 4),
              Text(
                'Head: ${_poseLine(service.lastPose!)}',
              ),
            ],
            const SizedBox(height: 12),
            _preview(controller),
          ],
        ],
      ),
    );
  }

  String _poseLine(HeadPose pose) {
    String dir(double v, String left, String right) {
      if (v > 8) return left;
      if (v < -8) return right;
      return 'straight';
    }

    return 'turned ${dir(pose.yaw, 'left', 'right')}, '
        'tilted ${dir(pose.roll, 'left', 'right')}';
  }

  Widget _preview(PrivacyScreenController controller) {
    final bytes = controller.service.lastFrameBytes;
    if (bytes == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'What the camera sees (kept in memory only, never saved):',
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image.memory(
            bytes,
            width: 320,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  Widget _settingsCard(PrivacyScreenController controller) {
    final settings = controller.settings;
    return _card(
      title: 'Settings',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Start protection when DJ starts'),
              ),
              Switch(
                value: settings.startOnLaunch,
                onChanged: (value) => controller.setStartOnLaunch(value),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'When on, protection starts by itself every time DJ opens.',
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(
                child: Text('Warn about a second face'),
              ),
              Switch(
                value: settings.detectShoulderSurfers,
                onChanged: (value) =>
                    controller.setDetectShoulderSurfers(value),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'When on, the screen blacks out if someone else appears in '
            'view. When off, only your own looking away blacks it out.',
          ),
          const SizedBox(height: 16),
          Text(
            'Sensitivity: ${_sensitivityLabel(settings.sensitivity)}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          Slider(
            value: settings.sensitivity,
            onChanged: (value) => controller.setSensitivity(value),
          ),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Lenient'),
              Text('Strict'),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Strict hides the screen sooner when you turn away. Lenient '
            'gives you more room to move before it hides.',
          ),
          const SizedBox(height: 16),
          const Text(
            'Override shortcut: Ctrl+Alt+P (fixed)',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text(
            'Press Ctrl+Alt+P anywhere — even while the screen is black — '
            'to pause protection and reveal the screen. Press it again to '
            'resume. Only this shortcut reveals the screen; any other key '
            'does nothing. The shortcut cannot be changed in Settings.',
          ),
        ],
      ),
    );
  }

  String _sensitivityLabel(double value) {
    if (value < 0.33) return 'Lenient';
    if (value < 0.66) return 'Balanced';
    return 'Strict';
  }

  Widget _howItWorksCard() {
    return _card(
      title: 'How it works',
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '1. Your webcam reads a frame every 0.2 seconds (0.4 while the '
            'screen is already black).',
          ),
          SizedBox(height: 4),
          Text(
            '2. A small face model on this laptop finds your face and '
            'works out which way your head is turned. No photo ever leaves '
            'the laptop.',
          ),
          SizedBox(height: 4),
          Text(
            '3. One bad frame hides the screen. Several good frames in a '
            'row are needed to show it again.',
          ),
          SizedBox(height: 4),
          Text(
            '4. If the camera or the detector fails, the screen stays '
            'black. It never stays open because it could not see.',
          ),
          SizedBox(height: 4),
          Text(
            '5. Press Ctrl+Alt+P to pause protection when someone may '
            'look with you. Press it again to resume.',
          ),
        ],
      ),
    );
  }

  Widget _aboutCard() {
    return _card(
      title: 'About',
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Based on SafeScreen by kv4u, MIT license. '
            'Face detection uses the BlazeFace model (Google MediaPipe), '
            'which ships inside the app — no download, no account, no key.',
          ),
          SizedBox(height: 8),
          Text(
            'Fully local: no network, no keys, no telemetry. Camera frames '
            'stay in memory and are never saved to disk.',
          ),
        ],
      ),
    );
  }

  Widget _card({required String title, required Widget child}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}
