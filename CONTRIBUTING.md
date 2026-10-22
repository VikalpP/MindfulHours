# Contributing to MindfulHours

Thanks for helping! Bug reports, privacy-rule improvements, UI polish and new integrations are all welcome. For anything larger than a small fix, please open an issue or a discussion first so we can agree on the approach before you invest time.

## Development setup

Requirements: macOS 14+, Xcode 26+ (Swift 6 toolchain).

```sh
git clone https://github.com/VikalpP/MindfulHours.git
cd MindfulHours
swift build
swift test
scripts/build-app.sh --install   # builds, signs and launches /Applications/MindfulHours.app
```

`build-app.sh` signs with your local **Apple Development** certificate if you have one (any free Apple account in Xcode › Settings › Accounts creates it). With a stable identity, macOS remembers the Accessibility and Screen Recording grants across rebuilds; with ad-hoc signing you'll be asked again after every build.

### AI descriptions (optional)

The app works without AI: minutes are then recorded from app, window title and URL. To get AI descriptions, point Settings at any OpenAI-compatible endpoint, or run `scripts/setup-proxy.sh` to install [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) and sign in with a Claude subscription.

## Project layout

| Path | What lives there |
|---|---|
| `Sources/MindfulHoursCore` | Pure, testable logic: SQLite store, timeline grouping, privacy rules, sensitive-text detection, prompts and parsing, LLM client |
| `Sources/MindfulHours/Tracking` | macOS integration: Accessibility, AppleScript, ScreenCaptureKit, Vision OCR, idle detection, the recording loop |
| `Sources/MindfulHours/UI` | SwiftUI menu bar, timeline and settings |
| `Tests/MindfulHoursCoreTests` | Swift Testing suites for the core |
| `scripts/` | App bundling, release packaging, icon generation, proxy setup |

To capture the whole Settings window at full height (e.g. for docs), run:

```sh
open -n -W /Applications/MindfulHours.app --args --snapshot-settings ~/Desktop/settings.png --appearance light
```

The result looks like a ⌘⇧4-Space window screenshot: title bar, rounded corners and the system shadow on a transparent background, at Retina resolution. Add `--no-frame` for just the content. Launch it with `open` (not the binary directly) so macOS checks the app's own permissions, and keep your Mac unlocked so the window renders in its active style.

The app icon, the README header icon and the GitHub social preview are drawn in code; after changing them run `swift scripts/make-brand-assets.swift` from the repo root.

## Guidelines

- **Put logic in `MindfulHoursCore` and test it there.** The app target should stay a thin layer over system APIs.
- **Write self-explaining code.** Prefer clear names over comments; keep comments for constraints the code can't express.
- **Swift 6 strict concurrency.** UI and tracking run on the main actor; storage is an actor.
- **Privacy rules are non-negotiable:**
  - Screenshots stay in memory and are never written to disk or logs.
  - Nothing reaches a model when a privacy protection applies, and title/URL are dropped when they themselves are sensitive.
  - When a privacy signal can't be determined, fail closed (withhold the screenshot).
  - No network calls other than the configured model endpoint.

## Pull requests

1. Fork the repo and create a branch from `main` (`fix/safari-private-detection`, `feat/weekly-report`, …).
2. Keep each PR focused on one change; include tests for new core logic.
3. Make sure `swift build` and `swift test` pass. CI runs both and builds the app bundle on every PR; the built app is attached to the run as an artifact so reviewers can try it.
4. Fill in the PR template, especially **Privacy impact**.
5. A maintainer reviews; once CI is green and approved, the PR is squash-merged.

## For maintainers

### Releasing

```sh
git tag v1.2.0
git push origin v1.2.0
```

The **Release** workflow tests, builds a universal (Apple Silicon + Intel) app stamped with the tag's version, packages a DMG, zip and `SHA256SUMS.txt`, and publishes a GitHub Release with generated notes. Tags with a suffix (`v1.2.0-beta.1`) are published as pre-releases.

### Enabling signing and notarization

Releases are ad-hoc signed until these repository secrets exist; then they are signed with Developer ID, notarized and stapled automatically:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | `base64 -i DeveloperID.p12` of your *Developer ID Application* certificate + key |
| `DEVELOPER_ID_P12_PASSWORD` | Password of that `.p12` |
| `APPLE_ID` | Apple ID email of the developer account |
| `APPLE_TEAM_ID` | 10-character team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password from appleid.apple.com |

### Repository settings checklist

- Branch protection on `main`: require a pull request, 1 approval, Code Owner review, and the **Build & test** check.
- Enable **Private vulnerability reporting** (Security tab) and **Discussions**.
- Upload `docs/assets/social-preview.png` under Settings › General › Social preview.
