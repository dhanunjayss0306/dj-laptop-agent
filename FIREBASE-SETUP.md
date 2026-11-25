# DJ account + sync — Firebase setup

**You do these steps yourself, on your own Google account. Muse only
wrote the code; it did not create any Firebase or Google account or
project.**

## The choice, and why

**Firebase Auth (email/password) + Cloud Firestore, free Spark plan.**

- One same DJ login (an email + password you choose) on the Windows
  laptop and the Android phone. Sign in once on each device; DJ's
  routines, settings, summaries and memory sync between them.
- No social login (no Google/Apple sign-in). It is your own DJ login.
- Why Firebase and not hand-rolled auth: hand-rolled login is risky
  to get right (password storage, resets, tokens). Firebase Auth is
  proven, free at this scale, and does exactly this: one login, two
  devices, real-time sync. DJ's Core never needs the account — DJ
  works fully offline without one; the account is only for sync.
- Free Spark plan covers this usage (a handful of small documents
  per user, synced occasionally). If you ever outgrow it, Firebase
  will tell you in the console — nothing breaks, sync just stops
  until you upgrade.

## What syncs, and what never leaves the device

Syncs (under `users/{uid}/context/`): `routines`, `settings`
(Worker URL, cloud provider, local-model choice, preferences —
**not** folder paths, those are device-specific and stay local),
`summaries` (short text summaries only), `memory` (MEMORY.md +
daily notes).

Never uploads: file contents, full chat transcripts, screenshots,
folder paths, passwords, API keys. This is enforced in code
(`validateSyncPayload` in `lib/features/account/sync_service.dart`)
and covered by tests.

Conflict rule: last-write-wins per document, by `updatedAt`
timestamp. Ties go to the remote copy. Offline writes are queued
by Firestore's offline persistence and sent when back online.

## Steps (do them in order)

### 1. Create the Firebase project

1. Go to <https://console.firebase.google.com> and sign in with your
   Google account.
2. Click **Add project** (or **Create a project**). Name it `dj`
   (any name works). Click through; turn off Google Analytics when
   asked (DJ does not need it). Click **Create project**.

### 2. Enable Email/Password sign-in

1. In the Firebase console, open **Build → Authentication**.
2. Click **Get started**, then the **Sign-in method** tab.
3. Open **Email/Password**, switch it **on**, click **Save**.
4. Leave Google/Apple sign-in **off** — DJ uses email + password only.

### 3. Create the Firestore database

1. Open **Build → Firestore Database**, click **Create database**.
2. Choose **Start in production mode** (not test mode), click Next.
3. Location: pick **asia-south1 (Mumbai)** — closest to you.
   Click **Enable**. (The location cannot be changed later.)

### 4. Paste the security rules

1. In Firestore Database, open the **Rules** tab.
2. Replace everything with this block and click **Publish**:

```js
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // Each user can only read/write their own documents.
    // Nobody (not even another DJ user) can see anyone else's data.
    match /users/{uid}/{document=**} {
      allow read, write: if request.auth != null
        && request.auth.uid == uid;
    }
  }
}
```

### 5. Add the Android app

1. In **Project settings** (gear icon) → **Your apps**, click the
   Android icon.
2. Android package name: `com.dhanunjay.dj` (this is already the
   package name in `android/app/build.gradle.kts` — use exactly this).
3. App nickname: `DJ Android`. Skip the SHA-1 (not needed).
4. Download **`google-services.json`** and put it in
   `dj-flutter/android/app/google-services.json` (next to
   `build.gradle.kts`). Do **not** commit a fake one — this file
   comes from your project.
5. You can skip the remaining SDK-setup steps in the console wizard;
   the Flutter code already includes the Firebase packages.

### 6. Windows — no separate Firebase app needed

There is no "Windows app" in Firebase. Windows uses the **same**
Firebase project through the Dart SDK, with the web-equivalent
config. Recommended way:

1. On your laptop, install the FlutterFire CLI once:
   `dart pub global activate flutterfire_cli`
2. From the `dj-flutter` folder, run:
   `flutterfire configure`
   Pick your `dj` project, and select **android** and **windows**
   when it asks for platforms. This creates
   `lib/firebase_options.dart` with the real config for both.
3. Manual alternative (if the CLI does not work): create
   `lib/firebase_options.dart` by hand from the web app config in
   Project settings → Your apps → Web app, following the
   `DefaultFirebaseOptions` shape the FlutterFire docs show. The
   CLI way is recommended — fewer typos.

### 7. Wire Firebase into the app (one-time code step)

In `lib/main.dart`, before `runApp(...)`, add:

```dart
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'features/account/account.dart';

await Firebase.initializeApp(
  options: DefaultFirebaseOptions.currentPlatform,
);
final account = Account.create(dataDir: dataDir);
```

Hold `account` in `DjAppState` next to the other services, and add
an "Account" card in `lib/ui/settings_page.dart` that opens
`SignInPage(account: account, onSignedIn: ..., 
onContinueWithoutAccount: ...)`. The sign-in screen is written
(`lib/ui/sign_in_page.dart`) but deliberately **not** put in the app
shell yet — the app must work without an account, and Firebase does
not exist until you do steps 1–6. Do not gate startup on sign-in.

## Test it on both devices

1. Run the app on the laptop. Open Settings → Account → **Create
   account** with your email + a password you choose. You should see
   the signed-in state.
2. Run the app on the phone (same build). Open Settings → Account →
   **Sign in** with the same email + password.
3. Change something syncable on one device (e.g. set the Worker URL
   in Settings, or add a memory fact), wait a few seconds, and check
   it appears on the other device.
4. Turn off the internet on the phone, change something, turn the
   internet back on: the change should appear on the laptop once
   the phone is back online (offline queue).
5. **Delete test:** Settings → Account → delete (the UI must ask
   twice). The account, its cloud data and the synced local data
   are wiped. This cannot be undone.

## If something goes wrong

- "No Firebase project / google-services.json missing": steps 1, 5
  and 6 are not done yet — the app cannot sign in without them.
- "Permission denied" from Firestore: the rules in step 4 were not
  published, or you are signed in with a different account.
- "Wrong password": use the password you chose at sign-up. There is
  no password reset screen in DJ yet — reset it from the Firebase
  console (Authentication → user → reset password) if you forget it.
- Spark plan limits: the console's Usage tab shows reads/writes.
  DJ syncs a few small documents; you will not hit the free limits
  in normal use.
