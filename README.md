# Activity Tracker

A macOS menu-bar app that records what you do on your Mac, minute by minute — including what you're doing *inside* each app.

## How it works

| Layer | Source | Cadence |
|---|---|---|
| Frontmost app, window title, open document | `NSWorkspace` + Accessibility API | every 5 s |
| Active browser tab URL (Safari, Chrome, Arc, Brave, Edge, Vivaldi, Opera) | AppleScript | every 5 s |
| Away detection | input idle time, screen lock, sleep; video/call apps holding a display-sleep assertion count as present | every 5 s |
| Screenshot of the focused window | ScreenCaptureKit (kept in memory only) | ~every 25 s |
| "What are you doing in the app" | LLM via any OpenAI-compatible endpoint (default: CLIProxyAPI → Claude subscription) | once per active minute |

macOS has no API for in-app activity, so each active minute the app sends the window metadata and a screenshot of the focused window to the model, which returns a specific summary (e.g. *"Reviewing PR #42 auth refactor in acme/api on GitHub"*), a task label, project, and category. Consecutive minutes with the same task group into blocks on the timeline.

To save calls, a minute whose window and screenshot are unchanged reuses the previous description (fingerprinted with a 64-bit dHash, refreshed at least every 10 min). When AI is off, the app is excluded, or the model is unreachable, the minute is still recorded from metadata alone; failures back off exponentially up to 15 min.

Data lives in `~/Library/Application Support/ActivityTracker/activity.sqlite` (tables `spans`, `insights`, `day_summaries`). Screenshots are never written to disk.

## Setup

Requires macOS 14+ and Xcode / Swift 6 toolchain.

```sh
scripts/setup-proxy.sh          # brew install cliproxyapi, Claude OAuth login, localhost-only key, writes app settings
scripts/build-app.sh --install  # build, sign with your Apple Development cert, install to ~/Applications, launch
```

Then grant **Accessibility** and **Screen Recording** when prompted (or from the menu-bar popover), and allow Automation for each browser the first time it's in front. Restart the app after granting Screen Recording.

Signing with a stable Apple Development identity keeps permission grants across rebuilds; override with `CODESIGN_IDENTITY=...`.

### Switching providers

CLIProxyAPI exposes every provider it supports behind the same `http://127.0.0.1:8317/v1` endpoint — log in to another provider (see the CLIProxyAPI docs for its login flag) and change **Model** in Settings. Any other OpenAI-compatible server (OpenRouter, Ollama, LM Studio) works by changing **Base URL** and **API key**. The model must accept image input if screenshots are enabled.

## Using it

- **Menu bar** — current app and latest minute description, today's active time, category bar, recent blocks, pause (15 min / 1 h / until resumed).
- **Timeline window** — per-day blocks with every distinct minute summary, app and category totals, **Summarize Day** (LLM-written work log), **Copy Markdown** (for standups).
- **Settings** — provider URL/key/model with connection test, screenshot toggle, idle threshold, excluded apps (password managers excluded by default), launch at login, delete all data.

## Development

```sh
swift build
swift test
```

`ActivityTrackerCore` holds the testable logic (SQLite store, timeline grouping, prompts and parsing, LLM client, image fingerprint). `ActivityTracker` holds the macOS integration (Accessibility, ScreenCaptureKit, AppleScript) and SwiftUI.
