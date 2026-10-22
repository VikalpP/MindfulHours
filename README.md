# MindfulHours

A macOS menu-bar app that records what you do on your Mac, minute by minute — including what you're doing *inside* each app.

## How it works

| Layer | Source | Cadence |
|---|---|---|
| Frontmost app, window title, open document | `NSWorkspace` + Accessibility API | every 5 s |
| Active browser tab URL (Safari, Chrome, Comet, Arc, Brave, Edge, Vivaldi, Opera) | AppleScript | every 5 s |
| Away detection | input idle time, screen lock, sleep; video/call apps holding a display-sleep assertion count as present | every 5 s |
| Screenshot of the focused window | ScreenCaptureKit (kept in memory only) | ~every 25 s |
| "What are you doing in the app" | LLM via any OpenAI-compatible endpoint (default: CLIProxyAPI → Claude subscription) | once per active minute |

macOS has no API for in-app activity, so each active minute the app sends the window metadata and a screenshot of the focused window to the model, which returns a specific summary (e.g. *"Reviewing PR #42 auth refactor in acme/api on GitHub"*), a task label, project, and category. Consecutive minutes with the same task group into blocks on the timeline.

To save calls, a minute whose window and screenshot are unchanged reuses the previous description (fingerprinted with a 64-bit dHash, refreshed at least every 10 min). When AI is off, the app is excluded, or the model is unreachable, the minute is still recorded from metadata alone; failures back off exponentially up to 15 min.

## Privacy protections

Before each screenshot the app evaluates these signals; any hit skips the screenshot:

| Signal | Source | Title & URL |
|---|---|---|
| Excluded app (password managers by default) | bundle ID list | hidden |
| Sensitive address (`chrome://password-manager`, `edge://wallet`, `passwords.google.com`, your banks…) | active tab URL vs. editable prefix/domain list | hidden |
| Sensitive title word ("passwords", "recovery codes", "credit card"… whole-word) | window title vs. editable list | hidden |
| Password field focused | `IsSecureEventInputEnabled()` (Chromium, Safari, native fields) and AX `AXSecureTextField` | kept |
| Window opts out of capture | `kCGWindowSharingState == none` | kept |
| Private/incognito window | Chromium `mode of front window`; Safari Window-menu heuristic | kept (toggle) |
| Sensitive text on screen (Luhn-valid card numbers, IBANs, SSNs, API keys, private keys, "recovery codes"/"CVV" labels) | on-device Vision OCR of the screenshot | kept |

When the title or URL itself is sensitive, the minute is stored as "<App> — private content hidden" and nothing goes to the model. Otherwise the model still gets the metadata, told the screenshot was withheld. Any protection seen during a minute withholds that minute's screenshot even if it was taken earlier. Every skip is logged (reason and matched rule, never the matched text) under **Settings › Skipped screenshots**.

Data lives in `~/Library/Application Support/MindfulHours/activity.sqlite` (tables `spans`, `insights`, `day_summaries`, `privacy_events`). Screenshots are never written to disk.

## Setup

Requires macOS 14+ and Xcode / Swift 6 toolchain.

```sh
scripts/setup-proxy.sh          # brew install cliproxyapi, Claude OAuth login, localhost-only key, writes app settings
scripts/build-app.sh --install  # build, sign with your Apple Development cert, install to /Applications, launch
```

Then grant **Accessibility** and **Screen Recording** when prompted (or from the menu-bar popover), and allow Automation for each browser the first time it's in front. Restart the app after granting Screen Recording.

Signing with a stable Apple Development identity keeps permission grants across rebuilds; override with `CODESIGN_IDENTITY=...`.

### Switching providers

CLIProxyAPI exposes every provider it supports behind the same `http://127.0.0.1:8317/v1` endpoint — log in to another provider (see the CLIProxyAPI docs for its login flag) and change **Model** in Settings. Any other OpenAI-compatible server (OpenRouter, Ollama, LM Studio) works by changing **Base URL** and **API key**. The model must accept image input if screenshots are enabled.

## Using it

- **Menu bar** — current app and latest minute description, today's active time, category bar, recent blocks, pause (15 min / 1 h / until resumed).
- **Timeline window** — per-day blocks with every distinct minute summary, app and category totals, **Summarize Day** (LLM-written work log), **Copy Markdown** (for standups).
- **Settings** — provider URL/key/model with connection test, screenshot toggle, idle threshold, privacy rules (excluded apps, sensitive addresses and title words, private windows, on-screen text scan), skipped-screenshot log, launch at login, delete all data.

## Development

```sh
swift build
swift test
swift scripts/make-icon.swift   # regenerate Resources/AppIcon.icns
```

`MindfulHoursCore` holds the testable logic (SQLite store, timeline grouping, prompts and parsing, LLM client, image fingerprint). `MindfulHours` holds the macOS integration (Accessibility, ScreenCaptureKit, AppleScript) and SwiftUI.
