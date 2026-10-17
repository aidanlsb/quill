# Quill

A native macOS markdown editor for long-form writing. It opens and saves plain `.md` files in place, speaks vim motions through a from-scratch engine, and keeps YAML frontmatter and `[[wikilinks]]` untouched.

There is no WKWebView, Electron, or JavaScript. The editor is SwiftUI + AppKit on **TextKit 2 / `NSTextView`**.

## Layout

| Module | What it is |
|---|---|
| **QuillVim** | Vim engine. No AppKit. `swift test` on Linux. |
| **QuillLSP** | Generic JSON-RPC LSP client (stdio). No AppKit. |
| **QuillFS** | Oil-style directory buffer → filesystem operations. |
| **QuillSearch** | Fuzzy matcher, grep (ripgrep optional), Telescope-style picker state. |
| **Quill** | macOS app (SwiftPM executable, macOS 14+ / Swift 6). |

## Build and test (Linux or macOS)

The engine, LSP client, directory planner, and picker all run here:

```bash
swift test
```

That is the verified suite on Linux.

## Build the app (macOS 14+, Xcode 16 / Swift 6)

```bash
swift build -c release --product Quill
./Scripts/bundle-app.sh          # → dist/Quill.app
./Scripts/install.sh             # copies the app to /Applications and `quill` to /usr/local/bin
```

Or open `Package.swift` in Xcode and run the **Quill** target. The app is not sandboxed, so it can open any folder and spawn configured language servers.

The macOS app target is written for Xcode 16+ / Swift 6. It has **not** been compiled in this environment (Linux VM, no macOS runner).

## CLI

```bash
quill                  # empty window
quill path/to/note.md  # open a file
quill .                # open this folder as a directory buffer
quill some/dir         # same, for that directory
```

The `quill` script resolves `/Applications/Quill.app` (or a local `dist/Quill.app`) and calls `open -a`. After `Scripts/install.sh`, `quill` lives in `/usr/local/bin`.

## Writing feel

- Proportional body (New York / Iowan / Palatino) with generous line height
- Centered ~76-character column
- Live markdown styling in the buffer (headings, emphasis, code, lists, checkboxes, `[[wikilinks]]`, dimmed syntax) without rewriting the file
- Light and dark follow the system
- Focus mode: **⌃⌘F** (hides the status bar, larger margins)
- `[[` completion from filenames in the opened folder

Frontmatter and wikilinks are never rewritten. Saves write the buffer bytes (UTF-8, original LF vs CRLF preserved).

## Vim (QuillVim)

Own engine: parse **count → operator → motion or text object**. Motions return ranges; operators act on ranges. Every change is a replayable command for `.` and grouped undo.

**Modes:** normal, insert, visual, visual-line.

**Motions:** `h j k l` (`j`/`k` are display-line in the app, buffer-line when used as operators), `w b e W B E`, `0 ^ $`, `gg G`, `f t F T ; ,`, `{ }`, `( )`, `/ ? n N`.

**Operators:** `d c y > <` with counts and any motion. `cw` behaves like `ce`. Inclusive/exclusive and linewise/charwise are implemented, including the exclusive-motion-at-column-0 exception.

**Text objects:** `iw aw`, `is as`, `ip ap`, quotes `i"/a"` `i'/a'` `` i`/a` ``, brackets `i(/a(` `ib`, `i[/a[`, `i{/a{` `iB`, `i</a<`.

**Commands:** `x r s o O A I a i p P u Ctrl-r J ~ dd cc yy D C Y .`

**Registers:** unnamed, plus `"+` / `"*` for the system clipboard.

**Ex:** `:w` `:q` `:wq` only. `:q` refuses a dirty buffer.

**Other:** `gd` (definition / wikilink), `-` (parent directory), **leader** (Space by default).

`j`/`k` as operators stay linewise (vim `dj`). In normal/visual they follow wrapped display lines.

## Directory buffers (oil-style)

`-` in normal mode opens the current file's parent as an editable listing. Directories have a trailing `/`. `quill .` and `quill some/dir` start here.

| Key | Action |
|---|---|
| motions | normal vim |
| Enter | open file or descend |
| `-` | parent directory |
| edit a line | rename |
| add a line | create (`name/` = directory) |
| `dd` | delete (pending until `:w`) |
| `dd` then `p` in another listing | move |
| `:w` | confirmation sheet, then apply. Deletes go to Trash |

The planner lives in **QuillFS**: a buffer diff becomes `create` / `rename` / `delete` operations, with tests.

## Leader and pickers (Telescope-style)

Default leader is **Space**. Configurable in `~/.config/quill/config.json`.

| Map | Action |
|---|---|
| `<leader>sf` | fuzzy files in the opened root (gitignore + hidden/VCS skipped) |
| `<leader>sg` | live grep; results are `file:line` plus snippet |
| ⌘P | alias for find files |

The picker is a native floating panel with a preview.

**Picker insert mode** (opens here): type to filter, **Ctrl-n / Ctrl-p** or arrows move, Enter opens, **Esc** → picker normal.

**Picker normal mode:** `j`/`k` move, `gg`/`G` top/bottom, Enter opens, `i`/`a` back to insert, **Esc** or `q` closes.

Search is native (fuzzy subsequence matcher + line scan). If `rg` is on `PATH`, grep uses it and falls back otherwise.

## Language servers

Generic LSP 3.17 over stdio. **No default server** and nothing vault-specific. If the command is missing, editing still works.

Example `~/.config/quill/config.json` (also under `examples/config.json`):

```json
{
  "leader": " ",
  "leaderMaps": { "sf": "findFiles", "sg": "liveGrep" },
  "columnWidth": 76,
  "shiftWidth": 2,
  "lsp": {
    "servers": [
      {
        "name": "marksman",
        "command": "marksman",
        "arguments": ["server"],
        "extensions": [".md", ".markdown"],
        "languages": ["markdown"],
        "rootMarkers": [".git", ".marksman.toml"],
        "env": {}
      }
    ]
  }
}
```

Other markdown/prose servers (harper-ls, `rvn lsp`, …) are the same shape: set `command`, `arguments`, `extensions`, and `rootMarkers`.

Wired: `initialize`, `initialized`, `textDocument/didOpen|didChange|didSave|didClose`, completion, definition (`gd` / ⌘-click), hover, `publishDiagnostics`. Server requests `workspace/configuration`, `workspace/workspaceFolders`, and capability registration are answered so generic servers can start.

## What is verified vs not

**Verified on Linux (`swift test`):** QuillVim (motions, operators, text objects, visual, `.` / undo, ex, leader, `-`), QuillLSP JSON-RPC framing and a mock-server lifecycle (initialize, document sync, completion, definition, hover, diagnostics, missing-server), QuillFS diffs (create/rename/delete/move), QuillSearch fuzzy + grep + picker insert/normal.

**Unverified:** compiling or running the macOS app (no macOS toolchain here). TextKit 2 display-line `j`/`k`, the confirmation sheet, Trash deletes, and a live language server should be checked in Xcode.

## Recommended next steps

1. Build `Quill.app` on a Mac and open a large note (10k lines) to confirm restyle + typing stay smooth.
2. Point `lsp.servers` at marksman or another markdown server and try `gd`, hover, and diagnostics.
3. Walk an oil-style rename / `dd`+`p` move / `:w` confirm once on a throwaway folder.
4. Optional: incremental document sync, visual-block, and a marks/jumplist — deliberately out of v1.
