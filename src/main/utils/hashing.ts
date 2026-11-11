// DJ v3 — hashing helpers.

import * as crypto from 'crypto';
import * as fs from 'fs';

/** SHA-256 of a file's contents, read in 1 MB pieces. Null on error. */
export function sha256File(filePath: string): string | null {
  try {
    const hash = crypto.createHash('sha256');
    const fd = fs.openSync(filePath, 'r');
    try {
      const buf = Buffer.alloc(1024 * 1024);
      let n: number;
      do {
        n = fs.readSync(fd, buf, 0, buf.length, null);
        if (n > 0) hash.update(buf.subarray(0, n));
      } while (n > 0);
    } finally {
      fs.closeSync(fd);
    }
    return hash.digest('hex');
  } catch {
    return null;
  }
}

/** A short stable id for a file, from its full path. */
export function fileId(filePath: string): string {
  return crypto.createHash('sha1').update(filePath).digest('hex').slice(0, 16);
}

/** Human size, e.g. 2450 -> '2.4 KB'. */
export function humanSize(n: number): string {
  const units = ['B', 'KB', 'MB', 'GB'];
  let v = n;
  for (const unit of units) {
    if (v < 1024 || unit === 'GB') {
      return unit === 'B' ? `${v} B` : `${v.toFixed(1)} ${unit}`;
    }
    v /= 1024;
  }
  return `${v.toFixed(1)} GB`;
}
