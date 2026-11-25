// Tests for lib/features/privacy_screen/bmp_encoder.dart.
// Design ported from SafeScreen by kv4u (MIT).
//
// The native capture path hands back raw BGRA rows; the detector only
// accepts an encoded image, so the rows are wrapped in a BMP container
// in memory. BMP is right here precisely because it is not a
// compression format: a 54-byte header and a row copy, nothing on disk.

import 'dart:typed_data';

import 'package:dj/features/privacy_screen/bmp_encoder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('encodeBgraAsBmp', () {
    test('a 1x1 image is a 54-byte header plus one pixel', () {
      final Uint8List? bmp = encodeBgraAsBmp(
        Uint8List.fromList([0x11, 0x22, 0x33, 0xFF]),
        width: 1,
        height: 1,
      );
      expect(bmp, isNotNull);
      expect(bmp!.length, bmpHeaderSize + 4);
      // 'BM'
      expect(bmp[0], 0x42);
      expect(bmp[1], 0x4D);
      // Pixel data offset at bytes 10-13.
      final ByteData header = ByteData.view(bmp.buffer, 0, bmpHeaderSize);
      expect(header.getUint32(10, Endian.little), bmpHeaderSize);
      // Width and height.
      expect(header.getInt32(18, Endian.little), 1);
      expect(header.getInt32(22, Endian.little), 1);
      // Bits per pixel: 32.
      expect(header.getUint16(28, Endian.little), 32);
      // The pixel itself, unchanged, at the end.
      expect(bmp.sublist(bmpHeaderSize), [0x11, 0x22, 0x33, 0xFF]);
    });

    test('rows are written bottom-up', () {
      // Input row 0 is the top of the image, row 1 the bottom.
      final Uint8List? bmp = encodeBgraAsBmp(
        Uint8List.fromList([
          1, 2, 3, 4, 5, 6, 7, 8, // top row (2 pixels)
          9, 10, 11, 12, 13, 14, 15, 16, // bottom row
        ]),
        width: 2,
        height: 2,
      );
      expect(bmp, isNotNull);
      final Uint8List pixels = bmp!.sublist(bmpHeaderSize);
      // BMP row 0 is the bottom of the image: the input's second row.
      expect(pixels.sublist(0, 8), [9, 10, 11, 12, 13, 14, 15, 16]);
      expect(pixels.sublist(8, 16), [1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('a padded stride reads only the real pixels of each row', () {
      final Uint8List? bmp = encodeBgraAsBmp(
        Uint8List.fromList([
          1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 0, // row 0 + 4 pad bytes
          9, 10, 11, 12, 13, 14, 15, 16, 0, 0, 0, 0, // row 1 + pad
        ]),
        width: 2,
        height: 2,
        stride: 12,
      );
      expect(bmp, isNotNull);
      expect(bmp!.length, bmpHeaderSize + 16);
      expect(bmp.sublist(bmpHeaderSize, bmpHeaderSize + 8),
          [9, 10, 11, 12, 13, 14, 15, 16]);
    });

    test('a negative stride means the source is already bottom-up', () {
      final Uint8List? bmp = encodeBgraAsBmp(
        Uint8List.fromList([
          9, 10, 11, 12, 13, 14, 15, 16, // already the bottom row
          1, 2, 3, 4, 5, 6, 7, 8, // already the top row
        ]),
        width: 2,
        height: 2,
        stride: -8,
      );
      expect(bmp, isNotNull);
      // No flip: the first row in the buffer is the first row in the BMP.
      expect(bmp!.sublist(bmpHeaderSize, bmpHeaderSize + 8),
          [9, 10, 11, 12, 13, 14, 15, 16]);
    });

    test('invalid inputs give null, never a malformed image', () {
      expect(encodeBgraAsBmp(Uint8List(4), width: 0, height: 1), isNull);
      expect(encodeBgraAsBmp(Uint8List(4), width: 1, height: 0), isNull);
      // Buffer too short for the claimed size.
      expect(encodeBgraAsBmp(Uint8List(4), width: 2, height: 2), isNull);
      // Stride narrower than a row of pixels.
      expect(
        encodeBgraAsBmp(Uint8List(16), width: 2, height: 2, stride: 4),
        isNull,
      );
    });
  });
}
