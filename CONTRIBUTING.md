# Contributing to e05

e05 is a personal workspace project. External contributions are welcome, but the development style is opinionated: the author is the only current user, breaking changes are acceptable, and backward compatibility code is explicitly avoided.

## Building GhosttyKit

e05 links against a locally-built `GhosttyKit.xcframework`. The binary is **not** vendored (it is in `.gitignore`) and must be rebuilt on each machine.

```bash
# Build the xcframework from the ghostty main branch
cd /path/to/ghostty
git checkout main && git pull

# macOS-only minimal build (use Homebrew's zig, not Nix's)
/opt/homebrew/bin/zig build \
  -Doptimize=ReleaseFast \
  -Dapp-runtime=none \
  -Demit-xcframework=true \
  -Dxcframework-target=native \
  -Demit-exe=false \
  -Dsentry=false

# Copy the output into the e05 project root
cp -R macos/GhosttyKit.xcframework /path/to/e05/
```

Notes:

- Use Homebrew's zig. Nix's zig does not build libghostty successfully (empirical result)
- `-Dxcframework-target=native` produces a host-arch binary only. Use `universal` for a fat xcframework
- `-Dapp-runtime=none` selects the embedding runtime; on macOS `emit-xcframework` is implied
- `libghostty-spm` is intentionally **not** used. Empirically it has key-handling problems and unstable API tracking

## Build and test

```bash
swift build
swift test --disable-sandbox    # 216 tests, ~0.3s
```

The `--disable-sandbox` flag is required because tests access `~/.config/e05/` paths, which SwiftPM's default sandbox denies.

For interactive runs prefer `./scripts/dev.sh` over `swift run e05`. The script assembles a `.app` bundle under `build/dev/` and execs the binary out of it, so `Bundle.main.bundleIdentifier` resolves and APIs that gate on bundle identity work — camera/microphone/location permission prompts, unified-log Logger subsystem, and the upcoming `UNUserNotificationCenter` wiring. The binary is exec'd directly (not via `open`), so stderr stays attached to the terminal.

```bash
./scripts/dev.sh                  # iterate
./scripts/build_app.sh release    # assemble build/release/e05.app (after swift build -c release)
```

AppleScript integration tests for key input:

```bash
./scripts/test-key-input.sh       # requires GUI + Accessibility permission
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
- New features should ideally ship with unit tests written first

## Source layout

```
Sources/
  App/                    — NSApplicationMain entrypoint, AppDelegate, menus
  Lib/
    Ghostty/              — libghostty C API wrapping (runtime, surface, input)
    Browser/              — WKWebView wrapper, history/bookmarks/downloads stores, ad blocker
    Pane/                 — PaneModel, ColumnModel, PaneAddress, session state
    Container/            — PaneContainerViewController + partial extensions (+Panes, +Focus,
                            +Workspaces, +URLBar, +Actions, +Session, +Sidebar)
    UI/                   — Sidebar, URL bar, command palette, suggestions, list panes
    Utility/              — FuzzyMatcher, ULID, Action registry, Collection+safe
Tests/                    — unit tests (216)
Package.swift             — SwiftPM manifest with GhosttyKit binary target
```
