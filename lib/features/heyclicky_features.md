# HeyClicky features — status (Dart layer)

DJ is local and private: no pricing, no subscription tiers, no usage
limits, no account or sign-in system. Nothing here is metered.

The integrations (features 9–15) share one framework —
`lib/features/integrations/integration.dart` (abstract `Integration` +
`IntegrationRegistry`) plus `integrations.dart` (`defaultRegistry()` in
the user's order). Adding another app is a small job: implement
`Integration`, register one line, done. See the comment at the top of
`integration.dart`.

Status key: **DONE** = built + tested in this layer; **PARTIAL** = Dart
built, something outside this layer is still missing (named per row);
**NOT BUILT** = not in this build, with the reason.

| # | Feature | Status | File(s) / notes |
|---|---------|--------|-----------------|
| 1 | Ask about the screen — capture on hotkey/ask, model answers, fake cursor points at it | **PARTIAL** | `lib/features/screen_qa.dart`. Capture, `[POINT:x,y:label]` parsing, cursor move, speak, and the Core-only fallback (says plainly no model is running, points from the user's words) are built + tested. **Live vision is blocked, not built:** `WorkerClient.chat` and the Worker `/chat` endpoint accept text messages only (`content` must be a String) — there is no image input. Vision needs an `image_url` part added to `worker/src/index.ts` + `WorkerClient` first. `ScreenQA` takes an injectable `VisionChat` for that day; until then it refuses honestly instead of faking sight. Screenshots are memory-only, never written to disk. |
| 2 | Annotations — circles, arrows, highlights, text labels in DJ blue #0071E3 | **PARTIAL** | `lib/features/annotations.dart`. Model + controller built + tested (maps, colour, clear). The Dart calls are defined (`annotate` with a list of annotation maps, `clearAnnotations` on `com.dhanunjay.dj/cursor`), but the **native method is still pending** (a Windows native agent is adding it). Until it lands the calls return `false` and nothing is drawn; walkthroughs/tutor still work via the cursor alone. |
| 3 | Walkthroughs — one step at a time, cursor + annotation, Next/cancel, progress "Step 2 of 5" | **DONE** | `lib/features/walkthrough.dart`. Engine + built-in example ("Open Chrome and search for something") + step advance/back/cancel/finish + state stream, tested. Auto-advance needs the UI to wire an `actionRunner`; with none, steps wait for Next and DJ never clicks by itself. |
| 4 | Tutor mode — explain a tool step by step, plain words, one UI element per step | **PARTIAL** | `lib/features/tutor.dart`. Mode flag, lesson builder from known elements, and lesson-from-model-answer parsing are built. **Live element discovery needs vision** — same blocker as #1. Without a model it says so plainly and builds lessons only from element positions the user/app supplies; it never invents button positions. |
| 5 | Agent mode — "DJ agent \<task\>", plans, runs the bounded AgentLoop with the real tools | **DONE** | `lib/features/agent_mode.dart`. Core-rules planner (BrainService keyword routing) + optional model-planner slot, `AgentLoop(maxSteps: 15)`, show-before-click with a beat, stuck detection (same action ×3, no screen change ×3), password refusal (text or focused password field), judge before destructive steps, step-by-step progress. All safety rules tested with fake tools. The model planner and the real tool wiring (channels/IndexService) are plug-in points for the app. |
| 6 | Routines — named step lists, saved to `dj_data/routines.json` | **DONE** | `lib/features/routines.dart`. Save/list/delete/run tested. Built-ins: "morning routine" (open Chrome, open VS Code, show today's newest files) and "wind down" (summary only — DJ never closes apps; there is deliberately no close step). |
| 7 | Parallel jobs — many agent jobs at once, each with status/progress, cancel | **DONE** | `lib/features/jobs.dart`. `startJob`/`cancelJob`/`listJobs` + `Stream<JobUpdate>`, tested (parallel finish, cancel-before-start, failure isolation). v1 runs jobs as Dart async Futures on one isolate — said in a comment; isolates are a future step. |
| 8 | Hotkey — Ctrl+Alt+D on Windows; floating button / wake word on Android | **PARTIAL** | `lib/features/hotkey_api.dart`. Dart API built + tested (`registerHotkey`/`unregisterHotkey`, `onHotkeyPressed` stream, `feedPress()` for Android). The **native `RegisterHotKey` is still pending** (a Windows native agent is implementing it); until then registering returns `false` and the stream never fires from a key press. Android has no global hotkey — the floating button / wake word feed the same stream. |
| 9 | WhatsApp | **PARTIAL** | `lib/features/integrations/whatsapp.dart`. Deep-link version built: open chat (`wa.me/<number>?text=…`), share text, open WhatsApp. **NOT BUILT, by design:** reading messages and auto-sending. There is no official API for personal accounts; that needs the WhatsApp Business API (businesses only) and is not in this build. Said plainly in the code comments. |
| 10 | Gmail — search mail + read a message | **PARTIAL** | `lib/features/integrations/gmail.dart` + `google_oauth.dart`. REST calls, message parsing (headers + plain-text body), OAuth2 flow with local tokens under `integrations.gmail`, auto-refresh — all built. **Needs the user to finish it:** create a Google Cloud OAuth client (exact steps in the comment at the top of `google_oauth.dart`), paste the client ID/secret, open the auth URL, paste the code back. Never live-tested against Google (no network test in this build). Read-only scope; no sending. |
| 11 | Google Drive — search + list files | **PARTIAL** | `lib/features/integrations/drive.dart` + `google_oauth.dart`. Same OAuth2 flow as Gmail (same Google Cloud client can cover both scopes); tokens under `integrations.drive`, auto-refresh. Same "needs the user's client + live test" as #10. Read-only scope; no upload/edit/delete. |
| 12 | GitHub — list repos, search code, read a file | **PARTIAL** | `lib/features/integrations/github.dart`. REST calls built; token stored locally only in `dj_config.json` under `integrations.github.token`, sent only to `api.github.com`, never logged. **Needs the user's token** (PAT with `repo` scope — documented in the file header) and a live test. Read-only; DJ never commits or edits. |
| 13 | Instagram | **PARTIAL** | `lib/features/integrations/instagram.dart`. Deep-link version built: open profile/post/reel, share text, open Instagram. **NOT BUILT, by design:** reading DMs, listing followers, posting. There is no official API for personal DMs/posting; that needs a business/creator account + Meta review and is not in this build. Said plainly in the code comments. |
| 14 | Browsers — open a URL in Chrome / Opera / Edge / Firefox; open DJ in the browser | **PARTIAL** | `lib/features/integrations/browsers.dart`. Windows: launches the browser exe with the URL as an argument (usual install paths, then PATH) — built. Android: opens the browser app, but **cannot pass the URL yet** — the system channel ignores launch args and there is no native `openUrl` method; DJ shows the URL instead. **NOT BUILT:** tab reading — that needs a browser extension, not in this build. |
| 15 | Local apps — open an installed app by name, list installed apps (utility, no auth) | **PARTIAL** | `lib/features/integrations/local_apps.dart`. Windows list + open built (known-apps table + PATH resolution). Android open works via the system channel; **Android list is NOT BUILT:** there is no `listApps` method on the Android system channel (`SystemChannelHandler` has `openApp` but no `listApps`), so it returns the plain message "Listing apps is not available on Android yet." |
| 16 | Privacy — screenshots never stored; delete all data | **DONE** | `lib/features/privacy.dart`. Rules enforced in code: screenshots memory-only (test asserts no image file appears after a ScreenQA run), only plain-text summaries/diary lines kept, `deleteAllData()` wipes `dj_data` and resets to first-run (refuses non-`dj_data` paths; needs `confirmed: true` — the UI must show one clear confirm dialog first, per the contract in the file), `clearScreenHistory()` is a documented no-op. |

## Things this layer could NOT build (missing pieces, by owner)

- **Vision endpoint** (Worker owner): `worker/src/index.ts` + `WorkerClient` need an image input before #1/#4 can see the screen. Until then ScreenQA's Core-only fallback is the honest behaviour.
- **Native `annotate` / `clearAnnotations`** (Windows native agent): #2 draws nothing until it lands.
- **Native `RegisterHotKey`** (Windows native agent): #8 fires nothing from a key press until it lands.
- **Native Android `listApps` + `openUrl`** (Android native owner): #15 list and #14 URL-passing on Android.
- **User setup + live tests** for #10/#11 (Google Cloud OAuth client) and #12 (GitHub PAT): code is done, but no live Google/GitHub call has been made from this build.
- **UI wiring** (UI agent, owns `lib/ui/` + `lib/main.dart`): none of these features is on screen yet — the pages, the hotkey hookup, the tutor toggle, the routines/jobs lists, and the integration connect flows are all UI work, untouched here.

## What was NOT touched

`lib/core/`, `lib/services/`, `lib/platform/`, `lib/ui/`, `lib/main.dart`,
`android/`, `windows/`, `worker/` — no changes. No commit, no push,
no token used. No new pub dependencies (`dart:io` HttpClient only).
