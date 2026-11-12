# DJ — Microsoft Store listing pack

Everything needed to submit DJ to the Microsoft Store. The code for
the Store build is ready in this repo (MSIX target + GitHub Actions
workflow); the only missing pieces are the Partner Center account
and the reserved app name — see "Still needed from the user" below.

## App name

- Preferred display name: **DJ**
- "DJ" is a very common name and is likely taken in the Store. If it
  is, reserve one of these instead (in order of preference):
  1. **DJ Files**
  2. **DJ — Your Files, Found**
  3. **DJ File Finder**
- Whatever name is reserved becomes `STORE_DISPLAY_NAME` for the
  build workflow. The package identity fields must match the
  reservation exactly (see "Still needed from the user").

## Short description (Store listing)

DJ finds your files — by name, or by what's inside them. Private,
offline, and free. Nothing leaves your laptop.

## Full description (Store listing)

DJ is your private laptop assistant. Ask it to find a file and it
finds it and opens it. It understands what is *inside* your files,
not just their names — so "open something about travel and tourism"
opens the files about travel and tourism.

DJ can also:

- Open folders — "open the frontend folder" opens it in File
  Explorer. Add any project folder and DJ learns its folder names too.
- Summarize a file — it picks the key sentences out of the file
  itself, and says plainly that it has no AI model.
- Organize Downloads — for today, yesterday, the last few days, this
  week, or everything. It shows you every move first. Nothing moves
  until you say yes. Nothing is ever deleted, nothing is ever
  overwritten.
- Find duplicate files — delete the copies you pick (they go to the
  Recycle Bin, only after you confirm), or merge a group into one
  folder you pick.
- Open apps by name — Notepad, Chrome, Calculator, Clock, and more.
- List recent files.

DJ never edits what is inside a file. It only finds, opens, deletes,
merges, and organizes.

Private by design: no account, no API key, no cloud, no paid
service, no tracking, no ads. The small meaning-search model lives
inside the app and runs on your own computer. DJ works fully offline.

## Features (bullet list for the Store)

- Find files by name or by meaning
- Open files and folders, including project folders
- Organize Downloads with a preview first — nothing moves without your yes
- Find and remove duplicate files (Recycle Bin, with confirmation)
- Summarize a file's key points
- Open apps by name
- Works fully offline — no account, no cloud, no tracking

## Keywords

file finder, file search, find my files, search by meaning, organize
downloads, duplicate finder, private assistant, offline, local files

## Category

Productivity

## Support / contact

Email: dhanunjay905@gmail.com

## Privacy policy

File: `PRIVACY.md` (and `privacy.html`, same text as a web page).
The Store needs it at a public URL. Hosting options, in order:

1. **GitHub Pages on this repo** — publish `privacy.html` from the
   `dj-laptop-agent` repo (Settings → Pages). Free, no new account.
2. **The user's portfolio site** — add the page there instead.

Do not submit the listing until the policy is live at a public URL.

## Screenshots (store-assets/)

1366×768, dark chat UI. Used for the Store listing:

- `preview-1-chat-sidebar.png` — chat with the slide-in sidebar
- `preview-2-search-results.png` — search with Explorer-style results
- `preview-3-folders.png` — Folders dialog (Add folder)
- `preview-4-duplicates.png` — duplicates view (extra shot)

## Still needed from the user (Partner Center)

The user — and only the user — can do these steps, because they
need his Microsoft account and his identity verification.

1. Go to **storedeveloper.microsoft.com** → "Get started for free"
   → **Individual** developer (free, no registration fee).
2. Sign in with a personal Microsoft account, verify identity with
   a government ID photo and a selfie. No credit card needed.
3. In Partner Center: **Create a new app** → reserve the app name
   (see "App name" above).
4. Open the app's **App identity** page and copy these four values:
   - **Package Name** — e.g. `Dhanunjay.DJFiles`
     → workflow input `store_package_name`
   - **Publisher ID** — the full string starting with `CN=`
     → workflow input `store_publisher_id`
   - **Publisher display name** — e.g. `Dhanunjay`
     → workflow input `store_publisher_display_name`
   - **Display name** — the reserved name itself
     → workflow input `store_display_name`
5. Send those four values to Muse (paste them in chat).

## What happens next (parent / build)

1. Parent pushes this commit (needs the user's token paste, as usual).
2. Parent runs the **Store MSIX build** workflow in GitHub
   (Actions → Store MSIX build → Run workflow) and fills in the
   four values above.
3. The workflow builds the `.msix` on a Windows runner and uploads
   it as an artifact. Download it from the workflow run.
4. In Partner Center: create a submission, upload the `.msix`,
   paste the description/features from this file, add the
   screenshots from `store-assets/`, set the privacy policy URL,
   set the price to Free, and submit for certification.
5. Microsoft reviews (usually 24–48 hours). Once it is live, the
   Store signs the app and Smart App Control trusts it — the
   unsigned-installer block goes away. Updates then come through
   the Store; the GitHub self-update in the app stays off in the
   Store build.

## What is still untested

- The MSIX build itself: it only runs on the Windows GitHub runner
  (the workflow). It has never run yet.
- The Store submission and certification review.
- The Store-installed app on a real Windows laptop (Store update
  path, `process.windowsStore` detection).
