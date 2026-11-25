// Screen Q&A — ask DJ about what is on the screen.
//
// Capture happens ONLY when the user presses the hotkey or asks about
// the screen. DJ never watches the screen continuously.
//
// PRIVACY RULE (hard): the screenshot bytes live in memory only and are
// NEVER written to disk. They are dropped (reference released) as soon
// as the answer is back — see the try/finally in [ask]. Only the
// plain-text answer is ever kept (in chat / memory files).
//
// VISION: a screenshot is sent to the model through the Cloudflare
// Worker (/chat) as an `image_url` part with a `data:image/png;base64`
// URL — see [makeWorkerVisionChat] and [ChatMessage.imageBase64].
// The Worker forwards it to OpenAI/OpenRouter as-is and converts it
// to an Anthropic image block for Anthropic. The configured model
// MUST be vision-capable (for example gpt-4o or claude-sonnet-4);
// a text-only model rejects the image and ScreenQA reports that
// plainly. When no model is running (Core only), ScreenQA says so
// plainly and falls back to asking the user to describe what they
// see, then points from their words ([pointFromWords] — a rough
// screen region only, never a precise claim).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/worker_client.dart';
import '../platform/cursor_channel.dart';
import '../platform/screen_channel.dart';
import '../platform/voice_channel.dart';

/// One point the model named, in virtual-screen pixels.
class ScreenPoint {
  const ScreenPoint({required this.x, required this.y, required this.label});
  final int x;
  final int y;
  final String label;
}

/// What ScreenQA answered, and how it got there.
class ScreenAnswer {
  const ScreenAnswer({
    required this.text,
    required this.points,
    required this.modelUsed,
    required this.fallbackUsed,
  });
  final String text;
  final List<ScreenPoint> points;

  /// True when a vision model actually looked at the screenshot.
  final bool modelUsed;

  /// True when DJ fell back to the Core-only path (no model / no vision).
  final bool fallbackUsed;
}

/// A vision call: PNG bytes + question in, plain answer text out.
/// The answer may carry [POINT:x,y:label] tags; ScreenQA parses them.
///
/// Plug this in once the Worker gains a vision endpoint. Until then
/// pass null and ScreenQA uses the Core-only fallback.
typedef VisionChat = Future<String> Function({
  required Uint8List png,
  required String question,
  required int width,
  required int height,
});

/// A [VisionChat] backed by the Cloudflare Worker: sends the PNG
/// screenshot plus the question to [model] on [provider] and joins
/// the streamed reply into one string. The model must be
/// vision-capable; a text-only model rejects the image and the error
/// surfaces plainly (ScreenQA reports it, never fakes an answer).
///
/// The screenshot bytes are base64-encoded in memory only and are
/// never written to disk.
VisionChat makeWorkerVisionChat(
  WorkerClient client, {
  required CloudProvider provider,
  required String model,
}) {
  return ({
    required Uint8List png,
    required String question,
    required int width,
    required int height,
  }) async {
    final chunks = await client
        .chat(
          provider: provider,
          model: model,
          messages: [
            const ChatMessage(
              role: 'system',
              content:
                  'You are DJ, a screen assistant. Answer about the screenshot. '
                  'When the user asks where to click, name the element and add a '
                  '[POINT:x,y:label] tag with its position in screenshot pixels.',
            ),
            ChatMessage(
              role: 'user',
              content: question,
              imageBase64: base64Encode(png),
              imageMimeType: 'image/png',
            ),
          ],
        )
        .toList();
    return chunks.join();
  };
}

/// Parses `[POINT:x,y:label]` tags out of a model reply. The label is
/// optional — `[POINT:120,300]` parses with an empty label.
List<ScreenPoint> parsePoints(String text) {
  final matches = RegExp(r'\[POINT:(\d+),(\d+)(?::([^\]]+))?\]')
      .allMatches(text)
      .toList();
  return matches
      .map((m) => ScreenPoint(
            x: int.parse(m.group(1)!),
            y: int.parse(m.group(2)!),
            label: (m.group(3) ?? '').trim(),
          ))
      .toList();
}

/// The reply with its [POINT:...] tags stripped out, for speaking/showing.
String stripPointTags(String text) =>
    text.replaceAll(RegExp(r'\[POINT:\d+,\d+(?::[^\]]+)?\]'), '').trim();

class ScreenQA {
  ScreenQA({
    required ScreenChannel screen,
    required CursorChannel cursor,
    required VoiceChannel voice,
    this.visionChat,
    this.modelUp,
  })  : _screen = screen,
        _cursor = cursor,
        _voice = voice;

  final ScreenChannel _screen;
  final CursorChannel _cursor;
  final VoiceChannel _voice;

  /// The vision function, or null when no vision endpoint exists.
  final VisionChat? visionChat;

  /// True when a model is up (Cloud or Local layer). Null/unset means
  /// "unknown" and is treated as no model — Core-only fallback.
  final bool Function()? modelUp;

  /// Ask about the screen. Captures once, answers, drops the bytes.
  ///
  /// [speakAnswer] speaks the answer through the voice channel (SAPI).
  Future<ScreenAnswer> ask(String question, {bool speakAnswer = false}) async {
    final capture = await _screen.captureScreen();
    if (capture == null) {
      return const ScreenAnswer(
        text: 'I could not capture the screen just now. Try again in a moment.',
        points: [],
        modelUsed: false,
        fallbackUsed: true,
      );
    }

    // Screenshot bytes: memory only, never written to disk. The
    // reference is released in the finally block below.
    Uint8List? png = capture.png;
    try {
      final hasModel = modelUp?.call() ?? false;
      if (visionChat == null || !hasModel) {
        return const ScreenAnswer(
          text: 'No model is running right now, so I cannot see your screen. '
              'Tell me what you see — for example "there is a Save button at the top right" — '
              'and I will point at it from your words.',
          points: [],
          modelUsed: false,
          fallbackUsed: true,
        );
      }
      final reply = await visionChat!(
        png: png,
        question: question,
        width: capture.width,
        height: capture.height,
      );
      final points = parsePoints(reply);
      final text = stripPointTags(reply);
      if (points.isNotEmpty) {
        final first = points.first;
        await _cursor.showCursor(first.x, first.y, first.label);
      }
      if (speakAnswer && text.isNotEmpty) {
        await _voice.speak(text);
      }
      return ScreenAnswer(
        text: text,
        points: points,
        modelUsed: true,
        fallbackUsed: false,
      );
    } on UnsupportedError catch (e) {
      return ScreenAnswer(
        text: 'I cannot see your screen yet: ${e.message}',
        points: const [],
        modelUsed: false,
        fallbackUsed: true,
      );
    } catch (e) {
      return ScreenAnswer(
        text: 'Something went wrong while looking at the screen: $e',
        points: const [],
        modelUsed: false,
        fallbackUsed: true,
      );
    } finally {
      // Drop the screenshot bytes right after the answer.
      png = null;
    }
  }

  /// Core-only fallback: point at a rough region from the user's own
  /// words ("top left", "bottom right", "in the middle"). This is a
  /// region guess, not a precise location — DJ says so in the reply.
  /// Returns the point in screen pixels for the given screen size.
  ScreenPoint pointFromWords(
    String description, {
    required int width,
    required int height,
  }) {
    final low = description.toLowerCase();
    final top = low.contains('top');
    final bottom = low.contains('bottom');
    final left = low.contains('left');
    final right = low.contains('right');
    final x = left
        ? (width * 0.15).round()
        : right
            ? (width * 0.85).round()
            : (width / 2).round();
    final y = top
        ? (height * 0.15).round()
        : bottom
            ? (height * 0.85).round()
            : (height / 2).round();
    return ScreenPoint(x: x, y: y, label: description.trim());
  }

  /// Ask from the user's description instead of a screenshot: points
  /// at the rough region and moves the fake cursor there.
  Future<ScreenPoint> pointAtDescription(
    String description, {
    required int width,
    required int height,
  }) async {
    final point = pointFromWords(description, width: width, height: height);
    await _cursor.showCursor(point.x, point.y, point.label);
    return point;
  }
}
