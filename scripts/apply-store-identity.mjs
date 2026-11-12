// DJ v3.4 — apply the Microsoft Store identity to package.json.
//
// The Store identity only exists once the user reserves the app name
// in Partner Center. Until then package.json carries obvious
// REPLACE-WITH placeholders and any MSIX build fails loudly here
// instead of shipping a package with a fake identity.
//
// Values come from environment variables (the GitHub Actions workflow
// fills them from its workflow_dispatch inputs):
//   STORE_DISPLAY_NAME            — Store listing name, e.g. "DJ"
//                                   (may have to change if "DJ" is taken)
//   STORE_PACKAGE_NAME            — Package Name from the reservation,
//                                   e.g. "Dhanunjay.DJFiles"
//   STORE_PUBLISHER_ID            — Publisher ID from the reservation,
//                                   the full string starting with "CN="
//   STORE_PUBLISHER_DISPLAY_NAME   — Publisher display name, e.g. "Dhanunjay"
//   STORE_APPLICATION_ID          — optional, defaults to "Dhanunjay.DJ"
//
// Run:  STORE_PACKAGE_NAME=... STORE_PUBLISHER_ID=CN=... \
//         STORE_PUBLISHER_DISPLAY_NAME=... node scripts/apply-store-identity.mjs
// It edits package.json in place (build.appx only) and prints what changed.

import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pkgPath = path.join(root, 'package.json');

const displayName = process.env.STORE_DISPLAY_NAME?.trim() || 'DJ';
const packageName = process.env.STORE_PACKAGE_NAME?.trim() || '';
const publisherId = process.env.STORE_PUBLISHER_ID?.trim() || '';
const publisherDisplayName =
  process.env.STORE_PUBLISHER_DISPLAY_NAME?.trim() || '';
const applicationId =
  process.env.STORE_APPLICATION_ID?.trim() || 'Dhanunjay.DJ';

function fail(message) {
  console.error(`apply-store-identity: ${message}`);
  process.exit(1);
}

// Partner Center package names look like "Publisher.AppName":
// letters, digits, periods, hyphens, underscores only.
if (!packageName || /REPLACE/i.test(packageName)) {
  fail(
    'STORE_PACKAGE_NAME is missing — set it to the Package Name from the Partner Center app reservation.',
  );
}
if (!/^[A-Za-z0-9][A-Za-z0-9.\-_]*$/.test(packageName)) {
  fail(
    `STORE_PACKAGE_NAME "${packageName}" is not a valid Store package name (letters, digits, . - _ only).`,
  );
}
if (!publisherId || /REPLACE/i.test(publisherId)) {
  fail(
    'STORE_PUBLISHER_ID is missing — set it to the Publisher ID from the Partner Center reservation (the full string starting with "CN=").',
  );
}
if (!/^CN=/i.test(publisherId)) {
  fail(
    `STORE_PUBLISHER_ID "${publisherId}" does not start with "CN=" — use the full Publisher ID string from Partner Center.`,
  );
}
if (!publisherDisplayName || /REPLACE/i.test(publisherDisplayName)) {
  fail(
    'STORE_PUBLISHER_DISPLAY_NAME is missing — set it to the Publisher display name from the Partner Center reservation.',
  );
}
if (!displayName) fail('STORE_DISPLAY_NAME must not be empty.');
if (!applicationId) fail('STORE_APPLICATION_ID must not be empty.');

const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf-8'));
pkg.build = pkg.build ?? {};
pkg.build.appx = {
  ...(pkg.build.appx ?? {}),
  applicationId,
  displayName,
  identityName: packageName,
  publisher: publisherId,
  publisherDisplayName,
};
fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n', 'utf-8');

console.log('apply-store-identity: Store identity applied to package.json');
console.log(`  displayName:           ${displayName}`);
console.log(`  identityName:          ${packageName}`);
console.log(`  publisher:             ${publisherId}`);
console.log(`  publisherDisplayName:  ${publisherDisplayName}`);
console.log(`  applicationId:         ${applicationId}`);
