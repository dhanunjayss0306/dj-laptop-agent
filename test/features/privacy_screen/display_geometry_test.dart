// Tests for lib/features/privacy_screen/display_geometry.dart.
// Design ported from SafeScreen by kv4u (MIT).
//
// The arithmetic decides whether a monitor stays exposed while the user
// is away, so it is tested rather than only eyeballed on a desk. The
// key case is mixed DPI: unioning logical pixels directly would leave
// a whole readable strip of monitor.

import 'package:dj/features/privacy_screen/display_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('computeCoverRect', () {
    test('one display returns its own rectangle', () {
      final CoverRect? cover = computeCoverRect(
        const [
          DisplayBounds(
              left: 0, top: 0, width: 1920, height: 1080, scaleFactor: 1),
        ],
        windowScaleFactor: 1,
      );
      expect(cover, isNotNull);
      expect(cover!.left, 0);
      expect(cover.top, 0);
      expect(cover.width, 1920);
      expect(cover.height, 1080);
    });

    test('two displays side by side union their widths', () {
      final CoverRect? cover = computeCoverRect(
        const [
          DisplayBounds(
              left: 0, top: 0, width: 1920, height: 1080, scaleFactor: 1),
          DisplayBounds(
              left: 1920, top: 0, width: 1920, height: 1080, scaleFactor: 1),
        ],
        windowScaleFactor: 1,
      );
      expect(cover, isNotNull);
      expect(cover!.width, 3840);
      expect(cover.height, 1080);
    });

    test('a monitor to the left gives a negative left edge', () {
      final CoverRect? cover = computeCoverRect(
        const [
          DisplayBounds(
              left: -1920, top: 0, width: 1920, height: 1080, scaleFactor: 1),
          DisplayBounds(
              left: 0, top: 0, width: 1920, height: 1080, scaleFactor: 1),
        ],
        windowScaleFactor: 1,
      );
      expect(cover, isNotNull);
      expect(cover!.left, -1920);
      expect(cover.width, 3840);
    });

    test('mixed DPI converts through physical pixels, not logical ones', () {
      // Display A: 1920x1080 @1.0 at (0,0).
      // Display B: 1920x1080 @1.5 at logical (1920,0) — physically
      // 2880..5760. Unioning the logical values would give 3840 wide;
      // the true union is 5760 wide.
      final CoverRect? cover = computeCoverRect(
        const [
          DisplayBounds(
              left: 0, top: 0, width: 1920, height: 1080, scaleFactor: 1),
          DisplayBounds(
              left: 1920,
              top: 0,
              width: 1920,
              height: 1080,
              scaleFactor: 1.5),
        ],
        windowScaleFactor: 1,
      );
      expect(cover, isNotNull);
      expect(cover!.width, 5760);
      expect(cover.height, 1620);
    });

    test('the window scale factor converts the union once at the end', () {
      final CoverRect? cover = computeCoverRect(
        const [
          DisplayBounds(
              left: 0, top: 0, width: 1920, height: 1080, scaleFactor: 1),
        ],
        windowScaleFactor: 2,
      );
      expect(cover, isNotNull);
      expect(cover!.width, 960);
      expect(cover.height, 540);
    });

    test('no displays, bad scale, or all-bad displays give null', () {
      expect(
        computeCoverRect(const [], windowScaleFactor: 1),
        isNull,
      );
      expect(
        computeCoverRect(
          const [
            DisplayBounds(
                left: 0, top: 0, width: 1920, height: 1080, scaleFactor: 1),
          ],
          windowScaleFactor: 0,
        ),
        isNull,
      );
      expect(
        computeCoverRect(
          const [
            DisplayBounds(
                left: 0, top: 0, width: 0, height: 1080, scaleFactor: 1),
          ],
          windowScaleFactor: 1,
        ),
        isNull,
      );
      expect(
        computeCoverRect(
          const [
            DisplayBounds(
                left: 0,
                top: 0,
                width: 1920,
                height: 1080,
                scaleFactor: -1),
          ],
          windowScaleFactor: 1,
        ),
        isNull,
      );
    });

    test('one bad display is skipped, the good one still covers', () {
      final CoverRect? cover = computeCoverRect(
        const [
          DisplayBounds(
              left: 0, top: 0, width: 0, height: 1080, scaleFactor: 1),
          DisplayBounds(
              left: 0, top: 0, width: 1920, height: 1080, scaleFactor: 1),
        ],
        windowScaleFactor: 1,
      );
      expect(cover, isNotNull);
      expect(cover!.width, 1920);
    });
  });
}
