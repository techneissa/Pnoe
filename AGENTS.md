# Pnoe

Pnoe is a native macOS app (SwiftUI, macOS 15+) that turns speech into text in whatever app you type in, with local or cloud transcription and optional AI cleanup. It is a personal project under GPL-3.0; `CONTRIBUTING.md` says how changes are accepted.

## Layout

- `Pnoe/`: the app. `App/` (lifecycle, menu bar, windows, defaults), `Features/` (one folder per screen area; `Modes/` holds what users see as Workflows), `Core/`, `DesignSystem/`, `Localizable.xcstrings`, `InfoPlist.xcstrings`.
- `Shared/`: code compiled into both the app and `PnoeTests` (a synchronized folder: a new file needs no project edit). Put logic a test must reach here.
- `Packages/`: Swift packages with their own tests. `PnoeFormatter` (text cleanup, model discovery, XPC protocol, eval tool), `PnoeLlama` (llama.cpp runtime), `PnoeMLX` (MLX runtime).
- `PnoeFormatterXPC/`, `PnoeFormatterMLXXPC/`: the two XPC services that run Built-in models, so a model crash never takes down dictation.
- `Tests/PnoeTests/`: unit and offscreen preview tests. `Tests/PnoeUITests/`: UI tests.
- `design/`: app icon and sound sources. `BUILDING.md`: build requirements and signing.

## Build and test

Run the heavy commands one at a time, never in parallel: each compiles for minutes and they slow each other down.

- One-time setup: `make whisper` builds `whisper.xcframework` into `~/Pnoe-Dependencies`, which the project links.
- Check build, unsigned, in a derived-data folder inside your worktree (`.review-build/` is git-ignored):
  `xcodebuild build -project Pnoe.xcodeproj -scheme Pnoe -configuration Debug -derivedDataPath .review-build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -skipPackagePluginValidation -skipMacroValidation`
- App tests, only the classes that cover your change:
  `xcodebuild test -project Pnoe.xcodeproj -scheme Pnoe -derivedDataPath .review-build -only-testing:PnoeTests/<TestClass> CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -skipPackagePluginValidation -skipMacroValidation`
- Package tests: `swift test --package-path Packages/<name>` (`make formatter-test` is the same for `PnoeFormatter`). The first MLX build takes a few minutes; Metal shaders only build under `xcodebuild`.
- Not for a check: `make local` rebuilds Release and copies the result over `~/Downloads/Pnoe.app`, replacing the app you may be running. `make build` and `make dev` sign with the maintainer's team.
- Leave the full suite, `PnoeUITests` and the app launch for the maintainer, unless the issue asks for them.

## Conventions

- **Motion goes through `Shared/Motion.swift`.** It is the one timing source (200 ms at most, none under Reduce Motion), so one search finds a stray animation. Views call its helpers and never `withAnimation`, `.animation`, `.transition` or `.symbolEffect` with their own numbers. A new kind of moment gets a case and a row in the moment table first.
- **User-facing strings exist in every shipped language**: English, German (`de`), French (`fr`) and Simplified Chinese (`zh-Hans`), in `Localizable.xcstrings` (and `InfoPlist.xcstrings` for permission texts). A string in one language only shows English elsewhere.
- **Prove a view with an offscreen preview test.** Render the real view in an `NSHostingView` to a PNG, light and dark, with no window on screen (`Tests/PnoeTests/PastingSettingPreviewTests.swift` is the pattern; the output folder comes from an environment variable passed as `TEST_RUNNER_<NAME>`). A fixed harness stands in for state the view reads from the app.
- **Tests use a private named pasteboard**, such as `NSPasteboard(name: "com.techneissa.pnoe.tests.<UUID>")`, never `NSPasteboard.general`: a test must not touch what the person running it has copied.
- **Defaults are registered, not set.** A setting's default goes into `AppDefaults.registerDefaults()` (or a `registeredDefaults` dictionary it includes), which applies only when no value is saved, so a user's choice survives an update. Read through a helper that clamps a saved value and falls back to the default.
- **New logic goes where a test can reach it**: `Shared/` for app code, a package for engine code. A change to `Pnoe/` that a test must cover moves its logic out first.
- **A setting that is saved is also backed up.** A new stored setting is added to backup export and import and to the system information the Dashboard copies, and an older backup without it leaves the current value alone.

## How changes arrive

Open an issue first; one problem per issue and one issue per pull request. Use the forms in `.github/`: a bug form and a feature form for issues, and the pull request template (What changes, How, Proof). Titles read `type(area): what is true after the change`, for example `fix(recorder): the check mark shows when a recording ends`. See `CONTRIBUTING.md`.

The Proof section lists the tests you ran with their results, a picture of each changed screen (dark mode), and what you did not run. State what you did not check; do not claim it.

Do not commit personal details, signing identities, API keys or local paths. Credit for code taken from other projects goes in `CREDITS.md`.
