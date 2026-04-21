# e05

A macOS app that hosts libghostty terminal panes and WKWebView browser panes in horizontally-tiled columns.

## Requirements

- macOS 26 (Tahoe) or later
- Swift 6 toolchain (Xcode 16 or Swift 6 CLI)
- A locally-built `GhosttyKit.xcframework` (see [CONTRIBUTING.md](./CONTRIBUTING.md#building-ghosttykit))
- Optional: [Nix](https://nixos.org/) for the provided `flake.nix` devShell

## Build & Run

```bash
# 1. Place GhosttyKit.xcframework at the repo root (see CONTRIBUTING.md)
# 2. Build and run:
swift build
swift run e05
```

## Keybindings

Pane operations use **⌥⌃ (Opt+Ctrl) + vim-style** keys.

| Category | Keys | Action |
|---|---|---|
| Pane focus | ⌥⌃+H / L / J / K | Move focus left / right / down / up |
| Pane order | ⌥⌃+Shift+H / L / J / K | Swap panes |
| New pane | ⌘+T | New terminal column |
| | ⌥⌃+B | New browser column |
| | ⌥⌃+V | Vertical split within column |
| Close / restore | ⌘+W | Close pane (with confirmation) |
| | ⌘+Shift+T | Restore last closed pane (within 10s) |
| Layout | ⌥⌃+/ | Cycle pane width preset (80 cols → 120 cols → 1/2 → 1/3 → ...) |
| | ⌥⌃+F | Toggle column fold |
| | ⌥⌃+T | Toggle title overlay |
| Browser | ⌘+L / ⌘+Shift+L | Focus URL bar / toggle URL bar visibility |
| | ⌘+R / ⌘+Shift+R | Reload / hard reload |
| | ⌘+[ / ⌘+] | Back / forward |
| | ⌘++ / ⌘+- / ⌘+0 | Zoom in / out / reset |
| | ⌘+D | Toggle bookmark |
| | ⌥⌘+I | Toggle Web Inspector (inline) |
| Workspace | Ctrl+Tab / Ctrl+Shift+Tab | Next / previous workspace |
| UI | ⌘+Shift+P | Command palette |
| | ⌘+B | Toggle sidebar pin |

Drag a pane edge to resize to an arbitrary width.

## Configuration

Configuration lives at `~/.config/e05/config`. The format is ghostty-compatible flat `key=value`. ghostty's default theme, keybindings, and font are used as-is.

Runtime data is stored under `~/.config/e05/`:

| Path | Purpose |
|---|---|
| `session.json` | Workspace / pane / window state |
| `history.db` | SQLite browsing history |
| `bookmarks.db` | SQLite bookmarks |
| `downloads.db` | SQLite downloads log |
| `resume/*.resume` | Per-pane resume state |
| `adblocker/` | Compiled `WKContentRuleList` cache + filterlist sources |
| `extensions/` | Unpacked `WKWebExtension` bundles |

## License

[MIT](./LICENSE)

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for build instructions, commit conventions, and architecture notes.
