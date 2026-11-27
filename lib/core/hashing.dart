// Pure-Dart SHA-1 and SHA-256 (no crypto package — DJ Core has no
// new dependencies). Used for duplicate detection (SHA-256 of file
// contents, 1 MB chunks) and fileId (SHA-1 of the full path, first
// 16 hex chars). Port of src/main/utils/hashing.ts.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;
int _rotl(int x, int n) => ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF;

List<int> _pad(Uint8List data) {
  final bitLen = data.length * 8;
  final out = <int>[...data, 0x80];
  while (out.length % 64 != 56) {
    out.add(0);
  }
  // 64-bit big-endian length.
  for (var i = 7; i >= 0; i--) {
    out.add((bitLen >> (i * 8)) & 0xFF);
  }
  return out;
}

const _k256 = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

String sha256Bytes(Uint8List data) {
  var h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
  var h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;
  final padded = _pad(data);
  for (var off = 0; off < padded.length; off += 64) {
    final w = List<int>.filled(64, 0);
    for (var i = 0; i < 16; i++) {
      w[i] = (padded[off + i * 4] << 24) |
          (padded[off + i * 4 + 1] << 16) |
          (padded[off + i * 4 + 2] << 8) |
          padded[off + i * 4 + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }
    var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e) & g);
      final t1 = (h + s1 + ch + _k256[i] + w[i]) & 0xFFFFFFFF;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xFFFFFFFF;
      h = g; g = f; f = e; e = (d + t1) & 0xFFFFFFFF;
      d = c; c = b; b = a; a = (t1 + t2) & 0xFFFFFFFF;
    }
    h0 = (h0 + a) & 0xFFFFFFFF; h1 = (h1 + b) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF; h3 = (h3 + d) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF; h5 = (h5 + f) & 0xFFFFFFFF;
    h6 = (h6 + g) & 0xFFFFFFFF; h7 = (h7 + h) & 0xFFFFFFFF;
  }
  return [h0, h1, h2, h3, h4, h5, h6, h7]
      .map((v) => v.toRadixString(16).padLeft(8, '0'))
      .join();
}

String sha1Hex(String input) {
  final data = Uint8List.fromList(utf8.encode(input));
  var h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE;
  var h3 = 0x10325476, h4 = 0xC3D2E1F0;
  final padded = _pad(data);
  for (var off = 0; off < padded.length; off += 64) {
    final w = List<int>.filled(80, 0);
    for (var i = 0; i < 16; i++) {
      w[i] = (padded[off + i * 4] << 24) |
          (padded[off + i * 4 + 1] << 16) |
          (padded[off + i * 4 + 2] << 8) |
          padded[off + i * 4 + 3];
    }
    for (var i = 16; i < 80; i++) {
      w[i] = _rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }
    var a = h0, b = h1, c = h2, d = h3, e = h4;
    for (var i = 0; i < 80; i++) {
      int f, k;
      if (i < 20) {
        f = (b & c) | ((~b) & d);
        k = 0x5A827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      final temp = (_rotl(a, 5) + f + e + k + w[i]) & 0xFFFFFFFF;
      e = d; d = c; c = _rotl(b, 30); b = a; a = temp;
    }
    h0 = (h0 + a) & 0xFFFFFFFF; h1 = (h1 + b) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF; h3 = (h3 + d) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF;
  }
  return [h0, h1, h2, h3, h4]
      .map((v) => v.toRadixString(16).padLeft(8, '0'))
      .join();
}

/// SHA-256 of a file's contents, read in 1 MB pieces. Null on error.
String? sha256File(String filePath) {
  try {
    final file = File(filePath);
    final raf = file.openSync(mode: FileMode.read);
    try {
      // Stream through a single digest by hashing incrementally:
      // read all bytes in 1 MB chunks and accumulate into a buffer
      // only for hashing — files here are capped at 500 MB by the
      // caller, and this keeps the implementation dependency-free.
      // To avoid holding a whole file in memory, hash chunk-wise
      // via a small incremental wrapper below.
      final hasher = _Sha256Incremental();
      final buf = Uint8List(1024 * 1024);
      int n;
      do {
        n = raf.readIntoSync(buf);
        if (n > 0) hasher.update(buf.sublist(0, n));
      } while (n > 0);
      return hasher.digestHex();
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return null;
  }
}

/// Fast partial hash (first + last [sampleBytes]) to eliminate non-matching
/// large files without reading the entire file. Returns null on error.
String? quickFileSignature(String filePath, {int sampleBytes = 8192}) {
  try {
    final file = File(filePath);
    final len = file.lengthSync();
    if (len <= sampleBytes * 2) return sha256File(filePath);
    final raf = file.openSync(mode: FileMode.read);
    try {
      final hasher = _Sha256Incremental();
      final head = Uint8List(sampleBytes);
      final hRead = raf.readIntoSync(head);
      if (hRead > 0) hasher.update(head.sublist(0, hRead));
      raf.setPositionSync(len - sampleBytes);
      final tail = Uint8List(sampleBytes);
      final tRead = raf.readIntoSync(tail);
      if (tRead > 0) hasher.update(tail.sublist(0, tRead));
      return hasher.digestHex();
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return null;
  }
}

/// Non-blocking [quickFileSignature] executed in a background isolate.
Future<String?> quickFileSignatureAsync(String filePath,
    {int sampleBytes = 8192}) {
  return Isolate.run(
    () => quickFileSignature(filePath, sampleBytes: sampleBytes),
  );
}

/// Non-blocking [sha256File] executed in a background isolate so large
/// duplicate scans never freeze the UI thread.
Future<String?> sha256FileAsync(String filePath) {
  return Isolate.run(() => sha256File(filePath));
}

/// Incremental SHA-256: buffers complete 64-byte blocks, pads at the end.
class _Sha256Incremental {
  final _buf = <int>[];
  int _totalLen = 0;
  int _h0 = 0x6a09e667, _h1 = 0xbb67ae85, _h2 = 0x3c6ef372, _h3 = 0xa54ff53a;
  int _h4 = 0x510e527f, _h5 = 0x9b05688c, _h6 = 0x1f83d9ab, _h7 = 0x5be0cd19;

  void update(List<int> data) {
    _totalLen += data.length;
    _buf.addAll(data);
    while (_buf.length >= 64) {
      _compressBlock(_buf.sublist(0, 64));
      _buf.removeRange(0, 64);
    }
  }

  void _compressBlock(List<int> block) {
    final w = List<int>.filled(64, 0);
    for (var i = 0; i < 16; i++) {
      w[i] = (block[i * 4] << 24) |
          (block[i * 4 + 1] << 16) |
          (block[i * 4 + 2] << 8) |
          block[i * 4 + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }
    var a = _h0, b = _h1, c = _h2, d = _h3, e = _h4, f = _h5, g = _h6, h = _h7;
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e) & g);
      final t1 = (h + s1 + ch + _k256[i] + w[i]) & 0xFFFFFFFF;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xFFFFFFFF;
      h = g; g = f; f = e; e = (d + t1) & 0xFFFFFFFF;
      d = c; c = b; b = a; a = (t1 + t2) & 0xFFFFFFFF;
    }
    _h0 = (_h0 + a) & 0xFFFFFFFF; _h1 = (_h1 + b) & 0xFFFFFFFF;
    _h2 = (_h2 + c) & 0xFFFFFFFF; _h3 = (_h3 + d) & 0xFFFFFFFF;
    _h4 = (_h4 + e) & 0xFFFFFFFF; _h5 = (_h5 + f) & 0xFFFFFFFF;
    _h6 = (_h6 + g) & 0xFFFFFFFF; _h7 = (_h7 + h) & 0xFFFFFFFF;
  }

  String digestHex() {
    final bitLen = _totalLen * 8;
    final tail = <int>[..._buf, 0x80];
    while (tail.length % 64 != 56) {
      tail.add(0);
    }
    for (var i = 7; i >= 0; i--) {
      tail.add((bitLen >> (i * 8)) & 0xFF);
    }
    for (var off = 0; off < tail.length; off += 64) {
      _compressBlock(tail.sublist(off, off + 64));
    }
    return [_h0, _h1, _h2, _h3, _h4, _h5, _h6, _h7]
        .map((v) => v.toRadixString(16).padLeft(8, '0'))
        .join();
  }
}

/// A short stable id for a file, from its full path.
String fileId(String filePath) => sha1Hex(filePath).substring(0, 16);

/// Human size, e.g. 2450 -> '2.4 KB'.
String humanSize(int n) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var v = n.toDouble();
  for (final unit in units) {
    if (v < 1024 || unit == 'GB') {
      return unit == 'B' ? '$n B' : '${v.toStringAsFixed(1)} $unit';
    }
    v /= 1024;
  }
  return '${v.toStringAsFixed(1)} GB';
}
