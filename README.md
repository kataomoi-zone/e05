# e05

A single-window, scrollable-tiling environment for macOS. Rather than managing OS windows, e05 brings terminals (libghostty), browsers (WKWebView), and a native file browser inside as its own panes and tiles them in horizontally-scrolling columns (a.k.a. niri-style) across multiple workspaces — freeing those workflows from macOS's native window management.

Alpha. macOS 26+ only.

## Highlights

- Three pane kinds: terminal (libghostty), browser (WKWebView), and finder (native file browser at `e05://finder`).
- Horizontally-tiled columns with intra-column vertical splits, slide animations on insert / reorder / close.
- Multiple workspaces inside one window, plus ephemeral "private" workspaces with a non-persistent data store.
- Sidebar with five modes — Tabs (workspace + pane tree), Bookmarks, History, Downloads, Extensions — hover-peek and pin.
- Per-tab WKWebExtensions: install from the Chrome Web Store, or load an unpacked extension folder or ZIP archive. Firefox `.xpi` and Safari `.appex` bundles are not supported.
- Built-in adblocker (declarative + procedural cosmetic + scriptlet injection runtime) with a catalog of filter lists — EasyList, EasyPrivacy, uBlock Origin, AdGuard regional lists, and more — fetched and cached at runtime, with a default-on subset plus optional and custom sources.
- Memory saver: idle browser panes auto-suspend after a configurable idle timeout (60 minutes by default) and on system memory pressure, restoring each pane's full back/forward history and scroll position on relaunch via the WKWebView interaction state.
- Web Notifications routed to native macOS banners with deep-link dispatch through the page's Service Worker.
- Per-host site permissions for camera / microphone / geolocation / notifications, and per-site mute.
- Finder pane (`e05://finder`) with inline rename, undo/redo across move / trash / new folder / duplicate / drag-drop, icon view with QuickLook thumbnails, and a rich right-click menu (Open, Open With, Get Info, Rename, Compress, Duplicate, Make Alias, Quick Look, Copy / Copy as Pathname, Paste, Share, Show in Finder, New Folder with Selection).
- Toast feedback overlay, command palette, per-pane find bar.
- `e05` CLI for scripting and shell integration; bundled `open` shim that routes shell-typed `open <url>` / `open <dir>` inside terminal panes to new columns.

## Requirements

- macOS 26 (Tahoe) or later
- Swift 6 toolchain (Xcode 16 or Swift 6 CLI)
- A locally-built `GhosttyKit.xcframework` at the repo root (see [CONTRIBUTING.md](./CONTRIBUTING.md#building-ghosttykit))

## Build & Run

e05 requires a real `.app` bundle at runtime — bundle id drives data paths, permission prompts, and `UNUserNotificationCenter`. `swift run e05` does not work; build the binary first, then assemble the bundle with `scripts/build_app.sh`.

```bash
# Dev iteration (build → assemble dev bundle → exec, stderr attached):
./scripts/dev.sh

# Release bundle (ad-hoc signed + Hardened Runtime):
swift build -c release
./scripts/build_app.sh release
open build/release/e05.app

# Tests:
swift test --disable-sandbox    # see CONTRIBUTING.md for why --disable-sandbox is needed
```

Dev and release use separate bundle ids (`com.kawarimidoll.e05.debug` vs `com.kawarimidoll.e05`), so their data directories stay isolated and you can run them side by side.

An ad-hoc-signed release is not notarised, so macOS Gatekeeper blocks it on first launch; right-click the `.app` and choose Open, or run `xattr -d com.apple.quarantine build/release/e05.app`.

### Signed & notarised distribution

`scripts/build_app.sh release` upgrades from ad-hoc to a real Developer ID identity when `E05_SIGN_IDENTITY` is set (adding the secure timestamp that notarisation requires), and `scripts/notarize.sh` then submits the bundle to Apple and staples the ticket. Copy `.envrc.sample` to `.envrc`, fill in your Developer ID identity and App Store Connect API key, and `direnv allow` (`.envrc` is gitignored) — or export the variables yourself:

```bash
swift build -c release
./scripts/build_app.sh release    # Developer ID-signed + Hardened Runtime + secure timestamp
./scripts/notarize.sh             # notarise, staple, emit a distributable zip
```

A notarised + stapled bundle launches without being blocked by Gatekeeper. See `scripts/notarize.sh --help` for the required `E05_NOTARY_*` variables.

### Install

`open build/release/e05.app` runs the bundle in place. To install it for everyday use, copy it into `/Applications` with `ditto` (a faithful bundle copy; quit any running instance first):

```bash
ditto build/release/e05.app /Applications/e05.app
```

The bundled `e05` CLI then lives at `/Applications/e05.app/Contents/Resources/bin/e05` — see [CLI](#cli) to put it on your `PATH`.

## Keybindings

The bindings below are the **defaults** — remap, clear, or reset any of them in Settings → Shortcuts (`⌘,`). Pane navigation uses **⌥⌃ (Opt+Ctrl) + vim-style** keys; browser / workspace shortcuts use **⌘**.

| Category | Keys | Action |
|---|---|---|
| Pane focus | `⌥⌃ H` / `L` / `J` / `K` | Move focus left / right / down / up |
| | `⌃ Tab` / `⌃⇧ Tab` | Next / previous pane (cycle) |
| Pane order | `⌥⌃⇧ H` / `L` | Move column left / right |
| | `⌥⌃⇧ J` / `K` | Move pane down / up within column |
| New pane | `⌘ T` | New start page column (`e05://start`) |
| | `⌘⇧ D` | Vertical split within column |
| | (palette) | New Browser Column, New Terminal Column, New Finder Column |
| Close / restore | `⌘ W` | Close pane (with confirmation for live terminals) |
| | `⌘⇧ T` | Reopen last closed pane (within 10s) |
| Layout | `⌥⌃ /` | Cycle pane width preset (defaults to 640 pt → 1/2 → 1/3; editable in Settings → Appearance) |
| | `⌥⌃ F` | Toggle column fold |
| Browser | `⌘ L` / `⌘⇧ L` | Focus URL bar / toggle URL bar visibility |
| | `⌘ R` / `⌘⇧ R` | Reload / hard reload (bypass cache) |
| | `⌘ .` | Stop loading |
| | `⌘ [` / `⌘ ]` | Back / forward |
| | `⌘ +` / `⌘ -` / `⌘ 0` | Zoom in / out / reset |
| | `⌘ D` | Toggle bookmark |
| | `⌥⌘ I` | Toggle Web Inspector (inline) |
| Find | `⌘ F` | Find in page (or filter rows in finder pane) |
| | `⌘ G` / `⌘⇧ G` | Find next / previous |
| Workspace | `⌘ N` | New workspace |
| | `⌘⇧ N` | New private workspace (also New Folder when a finder pane is focused) |
| | `⌘⇧ W` | Close current workspace |
| | `⌘⇧ ]` / `⌘⇧ [` | Next / previous workspace |
| Finder pane | `⌘⌫` | Move selection to Trash |
| | `⌘⇧ .` | Toggle hidden files |
| | (right-click) | Open, Open With, Get Info, Rename, Compress, Duplicate, Make Alias, Quick Look, Copy, Copy as Pathname, Paste, Share, Show in Finder, New Folder with Selection |
| Sidebar | `⌘⌥ T` / `B` / `L` / `E` | Open Tabs / Bookmarks / Downloads / Extensions |
| | `⌘ Y` | Open History |
| UI | `⌘⇧ P` | Command palette |
| | `⌘ B` | Toggle sidebar pin |
| | `⌘ ,` | Settings |

The command palette surfaces every action by id (e.g. `new_terminal_pane`, `browser_suspend`, `finder_view_as_icons`), so unbound actions are still reachable by typing.

Drag a pane edge to resize to an arbitrary width.

## Configuration

If `~/.config/e05/config.ghostty` exists it is loaded into ghostty's config parser at startup, so any ghostty config key (theme, font, keybindings, …) takes effect. The `.ghostty` extension follows the convention ghostty itself adopted in 1.3.0 so the same file can be fed to `ghostty --config-file=...`. Note that some ghostty options (window decoration, app-lifecycle flags) are app-only and have no effect inside libghostty. e05-specific preferences — including the app appearance (System / Light / Dark, following the macOS Appearance preference by default), keyboard shortcuts, and the idle-suspend threshold — live separately and are edited through Settings (`⌘,`).

## Data layout

Runtime data and caches live under macOS-native locations, keyed by bundle id so dev and release builds stay isolated:

```
~/Library/Application Support/<bundle-id>/
├── bookmarks.db              SQLite bookmarks
├── history.db                SQLite browsing history
├── downloads.db              SQLite downloads log
├── input-history.db          URL-bar input history
├── session.json              Workspace / pane state
├── preferences.json          e05 settings (edited via Settings)
├── permissions.json          Per-host camera / mic / location / notification grants
├── muted-sites.json          Per-host mute list
├── suspend-exempt.json       Per-host auto-suspend exemptions
├── adblocker-whitelist.json  Per-host adblocker whitelist
├── finder-modes.json         Per-directory finder view mode
├── resume/                   Per-pane download resume state
├── extensions/               Installed WKWebExtension bundles + state
└── control.sock              e05 CLI Unix domain socket
~/Library/Caches/<bundle-id>/
├── adblocker/                Compiled WKContentRuleList cache + filterlist sources
└── favicons/                 HTTP-fetched favicon cache
```

There is no automatic data migration between the dev and release bundle ids. Copy by hand if you want to carry a dev session over to release.

## CLI

`Contents/Resources/bin/e05` is a small CLI that talks to the running app over the Unix-domain socket above. The `.app` bundle is self-contained; symlink the binary onto your `PATH` to use it from any shell:

```bash
ln -s /Applications/e05.app/Contents/Resources/bin/e05 /usr/local/bin/e05
```

Subcommands:

```bash
e05 open <url-or-path>          # Open URL as a browser column, dir as a finder column
e05 action <action-id>          # Run any command-palette action by id
e05 switch-workspace <index>    # Switch to workspace at zero-based index
e05 notify <message>            # Surface a toast in the running app
```

Inside terminal panes the bundled `open` shim is prepended to `PATH`, so shell-typed `open .` / `open https://...` becomes a new finder / browser column. `open -a App` / `open file.pdf` etc. fall through to the system `/usr/bin/open` and keep their stock Launch Services behaviour.

## Related projects

e05's scrollable-tiling, panes-inside-one-window approach was most directly informed by two macOS apps that put terminals and browsers in horizontally-scrolling columns:

- [watchtower](https://github.com/markhuot/watchtower) — open source.
- [ribari](https://github.com/dalvlatko/ribari-releases) — closed source (releases only).

## License

e05 itself is [MIT](./LICENSE).

It also bundles, as separate aggregated scripts, the Ghostty shell integration (derived from Kitty), which is **GPL-3.0-or-later**. Its full license text ships inside the app at `Contents/Resources/licenses/GPL-3.0.txt` (source under [`Resources/licenses/`](./Resources/licenses)). This is mere aggregation — e05's own MIT-licensed code is unaffected.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for build instructions, commit conventions, and architecture notes.
