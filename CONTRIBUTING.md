# Contributing to MindfulHours

Thanks for helping! Bug reports, privacy-rule improvements, UI polish and new integrations are all welcome. For anything larger than a small fix, please open an issue or a discussion first so we can agree on the approach before you invest time.

## Development setup

Requirements: macOS 14+ to run, Xcode 27+ (Swift 6.4 toolchain, macOS 27 SDK) to build; CI enforces it. To exercise the real on-device model, run `MINDFULHOURS_LIVE_AI=1 swift test --filter LiveAppleIntelligence` on a Mac with Apple Intelligence turned on.

```sh
git clone https://github.com/VikalpP/MindfulHours.git
cd MindfulHours
swift build
swift test
scripts/build-app.sh --install   # builds, signs and launches /Applications/MindfulHours.app
```

`build-app.sh` signs with your local **Apple Development** certificate if you have one (any free Apple account in Xcode › Settings › Accounts creates it). With a stable identity, macOS remembers the Accessibility and Screen Recording grants across rebuilds; with ad-hoc signing you'll be asked again after every build.

### AI descriptions (optional)

The app works without AI: minutes are then recorded from app, window title and URL. On macOS 26+ with Apple Intelligence turned on, the default provider works with no setup. Otherwise pick a provider in **Settings › AI provider**; for free local testing, install [Ollama](https://ollama.com) and `ollama pull gemma3`.

## Project layout

| Path | What lives there |
|---|---|
| `Sources/MindfulHoursCore` | Pure, testable logic: SQLite store, timeline grouping, privacy rules, sensitive-text detection, prompts and parsing, LLM client, Apple Intelligence (on-device) and its fallback, provider presets and sign-in flows |
| `Sources/MindfulHours/Tracking` | macOS integration: Accessibility, AppleScript, ScreenCaptureKit, Vision OCR, idle detection, the recording loop |
| `Sources/MindfulHours/UI` | SwiftUI menu bar, timeline and settings |
| `Tests/MindfulHoursCoreTests` | Swift Testing suites for the core |
| `scripts/` | App bundling, release packaging, icon generation, screenshots |

To refresh the README screenshots (menu-bar popup, Timeline and Settings, in light and dark), install the app and run:

```sh
scripts/take-screenshots.sh                       # writes docs/screenshots/
scripts/take-screenshots.sh ~/Desktop/shots       # or anywhere else
```

They look like ⌘⇧4-Space window screenshots: full height, real title bar and shadow, transparent background, Retina resolution. Keep your Mac unlocked while it runs. The images show your real activity, so review them before committing. Each target can also be rendered alone with `open -n -W /Applications/MindfulHours.app --args --snapshot-settings|--snapshot-timeline|--snapshot-menu <file.png> [--appearance light|dark] [--no-frame]`.

The app icon, the README header icon and the GitHub social preview are drawn in code; after changing them run `swift scripts/make-brand-assets.swift` from the repo root.

## Guidelines

- **Put logic in `MindfulHoursCore` and test it there.** The app target should stay a thin layer over system APIs.
- **Write self-explaining code.** Prefer clear names over comments; keep comments for constraints the code can't express.
- **Swift 6 strict concurrency.** UI and tracking run on the main actor; storage is an actor.
- **Privacy rules are non-negotiable:**
  - Screenshots stay in memory and are never written to disk or logs.
  - Nothing reaches a model when a privacy protection applies, and title/URL are dropped when they themselves are sensitive.
  - When a privacy signal can't be determined, fail closed (withhold the screenshot).
  - No network calls other than the chosen AI provider and its sign-in endpoints.

## Pull requests

1. Fork the repo and create a branch from `main` (`fix/safari-private-detection`, `feat/weekly-report`, …).
2. Keep each PR focused on one change; include tests for new core logic.
3. Make sure `swift build` and `swift test` pass. CI runs both and builds the app bundle on every PR; the built app is attached to the run as an artifact so reviewers can try it.
4. Fill in the PR template, especially **Privacy impact**.
5. A maintainer reviews; once CI is green and approved, the PR is squash-merged.

## For maintainers

### Releasing

Releases are built, signed and notarized on the maintainer's Mac, not in CI. Write the release notes to `RELEASE_NOTES.md` (untracked), then:

```sh
scripts/release.sh 1.2.0             # build into dist/1.2.0/ and print the publish commands
scripts/release.sh 1.2.0 --publish   # same, then tag, push the tag and create the GitHub Release (on main only)
```

The script requires a clean tree and a new version, runs the tests, builds a universal (Apple Silicon + Intel) app stamped with the version, signs it with Developer ID (hardened runtime, secure timestamp), notarizes and staples the app, then packages, signs, notarizes and staples the DMG, and writes the zip and `SHA256SUMS.txt` next to it. Versions with a suffix (`1.2.0-beta.1`) are published as pre-releases.

One-time setup on the release Mac:

- A **Developer ID Application** certificate and its private key in the login keychain (the script picks it up; set `CODESIGN_IDENTITY` if there are several).
- A notarytool Keychain profile named `mindfulhours-notary`, created from an App Store Connect API key: `xcrun notarytool store-credentials mindfulhours-notary --key <AuthKey.p8> --key-id <key ID> --issuer <issuer ID>`. Set `NOTARY_PROFILE` to use another name.
- Xcode 27 or later and the `gh` CLI, signed in.

### Repository settings checklist

- Branch protection on `main`: require a pull request, 1 approval, Code Owner review, and the **Build & test** check.
- Enable **Private vulnerability reporting** (Security tab) and **Discussions**.
- Upload `docs/assets/social-preview.png` under Settings › General › Social preview.
