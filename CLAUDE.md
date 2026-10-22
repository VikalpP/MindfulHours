# MindfulHours: maintainer notes

macOS menu-bar app (Swift 6, SwiftPM, no Xcode project) that records frontmost app, window title and URL every few seconds and asks an LLM, once per active minute, what the person is doing inside the app. Logic lives in `MindfulHoursCore` (tested); macOS integration and SwiftUI live in `MindfulHours`. See README.md for features and CONTRIBUTING.md for setup.

```sh
swift build && swift test
scripts/build-app.sh --install          # build, sign, install to /Applications, launch
scripts/take-screenshots.sh             # refresh docs/screenshots (Mac must be unlocked)
git tag -a vX.Y.Z -m "MindfulHours X.Y.Z" && git push origin vX.Y.Z   # publish a release
```

## Decisions — don't reverse without asking the owner

- **Screenshots are withheld per page, not per app.** A protected tab (password manager, private window…) blocks screenshots of that page only; other pages of the same app still get theirs. A security review suggested app-level blocking; the owner rejected it. The post-capture re-check (same page, no protection seen during capture) covers the real race.
- **Title/URL are hidden only when they are themselves sensitive** (excluded app, sensitive URL rule, sensitive title word). Other protections (password field, capture-blocked window, private window, on-screen secrets, unverifiable browser) skip the screenshot but keep and send the metadata.
- **Fail closed** when a privacy signal can't be determined (browser URL or private mode unreadable, Safari menu in a non-English UI): withhold the screenshot.
- **One AI call per active minute**, describing the app with the most total time that minute (not the single longest page; terminal titles change constantly). Secondary apps are shown from activity checks as Timeline chips and lanes. The owner chose this over per-app AI descriptions to limit Claude subscription usage.
- **Tracking starts at launch; only screenshots wait** for the on-device text scanner to warm up (~30 s once after reboot), so no time is lost.
- **Releases are ad-hoc signed** until the owner has a paid Apple Developer account; the release workflow notarizes automatically once the Developer ID secrets exist (see CONTRIBUTING.md).
- **Provider is any OpenAI-compatible endpoint**, by default CLIProxyAPI on `127.0.0.1:8317` with `claude-haiku-5-5`, so the provider can be swapped without code changes.

## Lessons from testing (not visible in the code)

- **Minute calls must send `reasoning_effort: "none"`.** Without it, Haiku 5.5 spent the whole `max_tokens` budget on hidden reasoning and returned empty content (`finish_reason: length`).
- **Prompt history lists only app + task label, never earlier summaries.** With summaries, the model described an earlier Chrome minute for a Terminal-only minute 4 of 4 times. The current minute goes last, in a block marked "describe only this".
- **Task labels must be judged from the current minute.** "Reuse recent labels" made one wrong label propagate (a YouTube lecture tagged as the coding task). After any prompt change, re-test both cases against the live proxy.
- **The menu popup must keep a constant height.** MenuBarExtra doesn't redraw its rounded corners and shadow when it resizes while open.
- **Window snapshots (`--snapshot-*`)**: launch with `open`, not the binary, or macOS checks the terminal's permissions; use `open -g` for the popup so it shows the real front app; keep 1 pt of the window on screen and re-pin it after each resize, or ScreenCaptureKit fails with -3811; a locked screen can't be captured.
- **Without Screen Recording permission, every window reports "no sharing"**, so the capture-blocked check only runs once permission is granted.
- **Relaunching right after `pkill`** fails with LaunchServices error -600; `build-app.sh` waits for the old process to exit.

## State outside the repo

- The app was renamed from ActivityTracker (bundle `com.vikalppanseriya.ActivityTracker`). Its old data in `~/Library/Application Support/ActivityTracker/` was never migrated.
- Local builds are signed with the owner's Apple Development certificate so macOS keeps Accessibility/Screen Recording grants across rebuilds.
- `docs/screenshots/` shows the owner's real activity, and each refresh adds ~8.5 MB to history. Refresh rarely and review before committing.
- Commits use the owner's personal identity (`vikalppanseriya@gmail.com`), set per folder via `includeIf` in `~/.gitconfig`; pushes go over SSH as GitHub user VikalpP.
