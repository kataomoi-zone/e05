# Contributing to e05

e05 is a personal workspace project. External contributions are welcome, but the development style is opinionated: the author is the only current user, breaking changes are acceptable, and backward compatibility code is explicitly avoided.

## Building GhosttyKit

e05 links against a locally-built `GhosttyKit.xcframework`. The binary is **not** vendored (it is in `.gitignore`) and must be rebuilt on each machine.

```bash
# Build the xcframework from the ghostty main branch
cd /path/to/ghostty
git checkout main && git pull

# Apply e05's local libghostty patch(es) before building. They add
# ghostty_* C symbols e05 links against (e.g. ghostty_surface_command_text
# for OSC 133 command-output copy) and are not upstream. See patches/.
git apply /path/to/e05/patches/*.patch

# macOS-only minimal build (use Homebrew's zig@0.15, not Nix's).
# `-Demit-macos-app=false` because `-Demit-xcframework=true` turns the
# app bundle on by default, and e05 does not use Ghostty.app — building
# it only costs time, and its CodeSign step fails outright on a machine
# whose CoreSimulator is out of step with Xcode.
/opt/homebrew/opt/zig@0.15/bin/zig build \
  -Doptimize=ReleaseFast \
  -Dapp-runtime=none \
  -Demit-xcframework=true \
  -Dxcframework-target=native \
  -Demit-exe=false \
  -Demit-macos-app=false \
  -Dsentry=false

# Copy the output into the e05 project root
cp -R macos/GhosttyKit.xcframework /path/to/e05/

# Runtime resources (themes / shell-integration / terminfo). Unlike the
# xcframework these are COMMITTED under Resources/, and must come from the
# same ghostty commit (see GHOSTTY_VERSION). build_app.sh bundles them so a
# release resolves built-in themes + the xterm-ghostty terminfo without an
# inherited GHOSTTY_RESOURCES_DIR.
rsync -a --delete zig-out/share/ghostty/themes/            /path/to/e05/Resources/ghostty/themes/
rsync -a --delete zig-out/share/ghostty/shell-integration/ /path/to/e05/Resources/ghostty/shell-integration/
rsync -a --delete zig-out/share/terminfo/                  /path/to/e05/Resources/terminfo/

# Pin the commit so binary + resources stay in lockstep:
git rev-parse HEAD   # write the FULL sha into e05's GHOSTTY_VERSION (release CI fetches it verbatim)
```

Notes:

- Use Homebrew's **zig@0.15** keg (0.15.2, ghostty's `minimum_zig_version`). The main `zig` formula has moved to 0.16, so invoke the keg path directly. Nix's zig (0.16+) does not build libghostty successfully (empirical result)
- The macOS app build (which is what produces the apprt-enabled xcframework) needs the **Metal Toolchain** (`xcodebuild -downloadComponent MetalToolchain`) and a CoreSimulator in sync with Xcode (`sudo xcodebuild -runFirstLaunch`; reboot if `xcrun simctl list` still errors). Missing either fails the `Ld ghostty` step
- `-Demit-macos-app=false` costs nothing: in `build.zig` the xcframework is built and installed under `emit_xcframework` alone, and `emit_macos_app` only gates `Ghostty.app`. The apprt symbols e05 links against (`ghostty_init`, `ghostty_surface_*`) are still exported — `nm GhosttyKit.xcframework/macos-arm64/libghostty-internal-fat.a` to confirm after a bump
- `-Dxcframework-target=native` produces a host-arch binary only. Use `universal` for a fat xcframework
- `-Dapp-runtime=none` selects the embedding runtime; on macOS `emit-xcframework` is implied
- `libghostty-spm` is intentionally **not** used. Empirically it has key-handling problems and unstable API tracking
- **Local libghostty patches** live under `patches/`. Because `include/ghostty.h` is hand-written (not generated), each export needs an edit in both `src/apprt/embedded.zig` and `include/ghostty.h`. All of e05's exports ship as a single patch file — they share an insertion region, so separate patches would fight over line numbers. Re-verify on a ghostty bump: the internal APIs they call (`highlightSemanticContent`, `promptIterator`, `ScreenSet.get`, `Screen.selectionString`, `Selection.core`) are not C-stable. The `*.snippet.zig` files document the canonical insertion point, one per export
- If the macOS app build fails at `CodeSign` with `resource fork, Finder information, or similar detritus not allowed`, strip extended attributes and rebuild: `xattr -cr macos zig-out` (or `xattr -cr .` for the whole checkout)

## Fetching Sparkle

e05 links against Sparkle for in-app updates. Like `GhosttyKit.xcframework` it is a local binary target rather than a vendored one, so fetch it once per clone:

```bash
./scripts/fetch_sparkle.sh        # unpacks .sparkle/ (gitignored)
```

The version and its checksum are pinned in `SPARKLE_VERSION`; the script verifies the archive against that digest and is a no-op when the pinned version is already present, so it is safe to re-run. It supplies both the XCFramework the build links against and the signing tools (`sign_update`, `generate_keys`, `generate_appcast`) under `.sparkle/bin`.

Taking the archive with `curl` rather than declaring a remote SwiftPM package is deliberate: SwiftPM's artifact fetch has wedged silently in CI for over half an hour — "Downloading binary artifact" and then no further output — with no retry or timeout to configure. `curl` has both. To bump, update `SPARKLE_VERSION` with the version and the `checksum` that Sparkle's own `Package.swift` declares for that tag, then re-run the script.

## Build and test

```bash
./scripts/fetch_sparkle.sh              # first time, or after a SPARKLE_VERSION bump
swift build
swift test --disable-sandbox            # unit tests
./scripts/test-shell-integration.sh     # shell-integration snippets (bash + zsh)
```

The `--disable-sandbox` flag is required because tests access `~/.config/e05/` paths, which SwiftPM's default sandbox denies.

`test-shell-integration.sh` covers `Resources/bin/e05-integration.{zsh,bash,fish}`, which no Swift test can reach. (`Resources/bin/open`, the shim that keeps `open` inside e05, is shell too and is still uncovered.) Each case runs in a pristine shell (`bash --noprofile --norc` / `zsh -f`), so the developer's own dotfiles cannot mask a failure. Both workflows run it ahead of the GhosttyKit build, since it needs no build inputs and fails in seconds.

For interactive runs prefer `./scripts/dev.sh` over `swift run e05`. The script assembles a `.app` bundle under `build/dev/` and execs the binary out of it, so `Bundle.main.bundleIdentifier` resolves and APIs that gate on bundle identity work — camera/microphone/location permission prompts, unified-log Logger subsystem, and the upcoming `UNUserNotificationCenter` wiring. The binary is exec'd directly (not via `open`), so stderr stays attached to the terminal.

To follow the app's own `os.Logger` output, run `./scripts/logs.sh` in another terminal (it wraps `log stream --predicate 'subsystem == "com.kawarimidoll.e05"' --level debug`). The `--level debug` matters: the default stream level is `notice`, so `info`/`debug` messages are hidden without it. `os.Logger` also redacts interpolated strings as `<private>` — log a value as `\(value, privacy: .public)` to see it. (This is unrelated to `NSLog`, which a `swift run` binary does not route to the unified log at all.)

```bash
./scripts/dev.sh                  # iterate
./scripts/build_app.sh release    # assemble build/release/e05.app (after swift build -c release)
```

AppleScript integration tests for key input:

```bash
./scripts/test-key-input.sh       # requires GUI + Accessibility permission
```

## Formatting

Code is formatted with [swift-format](https://github.com/swiftlang/swift-format) (bundled with the Swift toolchain) in its **default configuration** — `.swift-format` pins only the schema `version` and overrides no rules (100-column limit, 2-space indent, etc.).

```bash
swift format -i -r Sources/ Tests/        # format in place
swift format lint -r -p Sources/ Tests/   # lint only
```

A pre-commit hook in `.githooks/` rejects commits that violate the rules. Enable it once per clone:

```bash
git config core.hooksPath .githooks
```

The same `core.hooksPath` also activates a **pre-push** hook that scans the commits being pushed for secrets with [gitleaks](https://github.com/gitleaks/gitleaks). It is graceful — if gitleaks is not installed the hook skips with a notice instead of blocking the push — so install it to opt in:

```bash
brew install gitleaks
```

Known false positives are allowlisted in `.gitleaks.toml`.

The bulk-reformat commit is recorded in `.git-blame-ignore-revs`; to skip it in local `git blame`:

```bash
git config blame.ignoreRevsFile .git-blame-ignore-revs
```

## Commit conventions

e05 uses [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` — new feature
- `fix:` — bug fix
- `refactor:` — internal restructure, no behaviour change
- `test:` — tests only
- `docs:` — documentation only
- `chore:` — build / tooling / meta

### Breaking changes

Breaking changes MUST be marked:

- Subject prefix: `feat!:`, `fix!:`, `refactor!:`
- Body: trailing `BREAKING CHANGE:` footer describing the impact and the fix path

Applies to:

- Persistence schemas (`session.json`, `*.db`, `resume/*.resume`)
- Public API surfaces
- Keybindings visible in the command palette

When in doubt, lean toward marking the change as breaking — it is cheap to demote, expensive to miss.

### Review fixups

Review feedback is applied via `git commit --fixup=<sha>` or `--amend` to the original commit, not as a separate commit.

## Testing philosophy

- Logic (key conversion, scroll math, pane management, URL handling) is covered by unit tests
- End-to-end key input is covered by AppleScript integration tests
- Shell-integration snippets are covered by `./scripts/test-shell-integration.sh` (bash + zsh)
- New features should ideally ship with unit tests written first

## Conventions

### Process-wide instances

The name tells you which kind of type it is and nothing else — in particular nothing about mutability, since `ScrollbackStore` is a value type that writes and deletes files:

- **`shared`** — reference types (`AdBlocker.shared`, `MutedSitesStore.shared`)
- **`default`** — value types (`E05Paths.default`, `ScrollbackStore.default`)

`E05Preferences.default` is the odd one out and does not mean this: it is the baseline value used when no preferences file exists, not a process-wide instance.

### Store locations

A store's location should be injectable so tests never touch the developer's real `~/.config` or `~/Library`. Reach for whichever of the first two fits:

- **Single file or SQLite** — `init(inMemory: Bool = false)` delegating to an internal `init(storeURL: URL?)` or `init(databasePath: String)`, where `nil` / `":memory:"` keeps the store ephemeral (`PreferencesStore`, `MutedSitesStore`, `Bookmarks`)
- **A directory of files** — the directory as an initialiser parameter, so a test can point it at a temp directory (`ScrollbackStore` defaults the parameter to the `E05Paths.default` location; `FaviconCache` resolves it in an `init(inMemory:)` convenience instead)
- **An injected collaborator** — the store itself is a parameter, and the test passes an in-memory one (`DownloadsManager(store:)`)
- **A test-only entry point** — `GhosttyConfigFileStore.init(testURL:)`, `SessionState.load(from:)`. Works, but leaves the production path (`SessionState.save()`) unreachable from a test

Some locations are still read from `E05Paths.default` inline with no seam at all — `SessionState.save()`, `DownloadsManager.resumeDir`, `AdBlocker.cacheRoot`, `ExtensionController`. That is not a pattern to copy. `E05Paths` documents the reasoning behind the seam it exposes for itself.

## Source layout

```
Sources/
  App/                    — NSApplicationMain entrypoint, AppDelegate, menus
  CLI/                    — e05 CLI executable (bundled as Contents/Resources/bin/e05)
  Lib/
    Ghostty/              — libghostty C API wrapping (runtime, surface, input)
    Browser/              — WKWebView wrapper, history/bookmarks/downloads stores, ad blocker
    Pane/                 — PaneModel, ColumnModel, WorkspaceModel, PaneAddress, session state
    Container/            — PaneContainerViewController + partial extensions (+Panes, +Focus,
                            +Workspaces, +URLBar, +Actions, +Session, +Sidebar, +Pin,
                            +Appearance, +FindBar, …)
    UI/                   — Sidebar, URL bar, command palette, suggestions, list panes
    Finder/               — native file-browser pane (e05://finder)
    Settings/             — Settings window (SwiftUI) + preferences store
    IPC/                  — control socket the e05 CLI connects to
    Utility/              — FuzzyMatcher, Frecency, ULID, Action registry, E05Paths,
                            URLCanonicalizer, Collection+Safe
Tests/                    — unit tests
Package.swift             — SwiftPM manifest with GhosttyKit + e05cli targets
```
