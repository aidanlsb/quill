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

## Build the app (macOS 14+, Swift 6.2)

Xcode 16.4 (Swift 6.1) does not compile the app. CI uses Xcode 26.3 (Swift 6.2) on macos-26, with complete concurrency checking. Linux `swift test` does not build this target.

```bash
swift build -c release --product Quill -Xswiftc -strict-concurrency=complete
./Scripts/bundle-app.sh          # → dist/Quill.app
./Scripts/install.sh             # copies the app to /Applications and `quill` to /usr/local/bin
Scripts/verify-quill            # QUILL_SMOKE: caret, scrolling, directory buffer
```

Or open `Package.swift` in Xcode and run the **Quill** target. The app is not sandboxed, so it can open any folder and spawn configured language servers.

`Scripts/verify-quill` is the launch smoke. A green Linux test run is not a substitute. The recipe lives in `.cursor/skills/verify-quill/`.

## CLI

```bash
quill                    # empty window
quill path/to/note.md    # open a file
quill path/to/note.md:12 # cursor on line 12 (1-based)
quill note.md:12:3       # line 12, column 3 (1-based UTF-16)
quill +12 path/to/note.md
quill .                  # open this folder as a directory buffer
quill some/dir           # same, for that directory
```

The `quill` script resolves `/Applications/Quill.app` (or a local `dist/Quill.app`) and calls `open -a`. A line or column is passed as a `quill://open?path&line&column` URL. If that file is already the open buffer, Quill moves the cursor and leaves unsaved edits in place. After `Scripts/install.sh`, `quill` lives in `/usr/local/bin`.

## Writing feel

- Sans-serif body: the system font at 16pt (`fontSize` 10–32, `font` a family name; blank or missing uses the system font). Headings are semibold system at 1.5 / 1.3 / 1.15 / 1.05 / 1.0 / 1.0. Code and frontmatter are SF Mono. Line height is 1.5
- Centered ~70-character column (`columnWidth`), with at least 128pt between the text and the window edge
- Live markdown styling in the buffer (headings, emphasis, code, lists, checkboxes, GFM tables, `[[wikilinks]]`, dimmed syntax) without rewriting the file. Tables use a monospaced face, a quiet alignment rule, and an emphasized header. Wide rows wrap within the column, and a table too wide to line up is shown as typed. `:TableFormat` pads cells so the pipes line up; set `formatTablesOnInsertLeave = true` to do that when leaving insert mode
- Light and dark follow the system
- Focus mode: **⌃⌘F** (hides the status bar, larger margins)
- `[[` completion from filenames in the opened folder

Frontmatter and wikilinks are never rewritten. Saves write the buffer bytes (UTF-8, original LF vs CRLF preserved).

## Vim (QuillVim)

Own engine: parse **count → operator → motion or text object**. Motions return ranges; operators act on ranges. Every change is a replayable command for `.` and grouped undo.

**Modes:** normal, insert, visual, visual-line.

**Motions:** `h j k l` (`j`/`k` follow screen rows and keep the screen column; `gj`/`gk` are buffer lines), `w b e W B E`, `0 ^ $` (`0`/`$` are the screen row; `g0`/`g$` are the buffer line), `gg G`, `f t F T ; ,`, `{ }`, `( )`, `/ ? n N`.

**Operators:** `d c y > <` with counts and any motion. `cw` behaves like `ce`. Inclusive/exclusive and linewise/charwise are implemented, including the exclusive-motion-at-column-0 exception.

**Text objects:** `iw aw`, `is as`, `ip ap`, quotes `i"/a"` `i'/a'` `` i`/a` ``, brackets `i(/a(` `ib`, `i[/a[`, `i{/a{` `iB`, `i</a<`.

**Commands:** `x r s o O A I a i p P u Ctrl-r J ~ dd cc yy D C Y .`

**Registers:** unnamed, plus `"+` / `"*` for the system clipboard.

**Ex:** `:w` `:q` `:wq`. `:q` refuses a dirty buffer. `:theme` toggles light and dark; `:theme light`, `:theme dark`, and `:theme system` set it. The last runtime choice is remembered in `~/.config/quill/state.toml` and overrides `theme` in `config.toml` on the next launch. `:TableFormat` pads the GFM table under the cursor (`:%TableFormat` pads every table).

**Other:** `gd` (definition / wikilink), `gr` (references), `-` (parent directory), **leader** (Space by default).

`j`/`k` in normal and visual mode move by screen row and keep the horizontal position, including across a short row. `gj`/`gk` move by buffer line. `0`/`$` are the screen row; `g0`/`g$` are the buffer line. Operators stay on buffer lines (`dj`). `d$` deletes to the end of the screen row.

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

Default leader is **Space**. Configurable in `~/.config/quill/config.toml`.

| Map | Action |
|---|---|
| `<leader>sf` | fuzzy files in the opened root (gitignore + hidden/VCS skipped) |
| `<leader>sg` | live grep; results are `file:line` plus snippet |
| `<leader>ca` | code actions for the cursor or selection |
| `<leader>tt` | toggle light and dark |

`<leader>t*` is reserved for toggles. `tt` is the appearance toggle; other `t` sequences are left open. **⇧⌘L** is the same toggle, under View → Toggle Light/Dark.
| ⌘P | alias for find files |

**⌘K** opens the command palette: the same native picker, listing every command (open, save, find files, live grep, the directory buffer, focus mode, light/dark/system theme, LSP, config, and the rest). Each row’s shortcut sits on the right. Recently used commands stay at the top. It opens from normal or insert mode; Escape puts the previous mode and cursor back, and Return runs the selected command. File → Command Palette uses the same list as the menus and the leader and ex bindings.

The picker is a native floating panel with a preview.

**Picker insert mode** (opens here): type to filter, **Ctrl-n / Ctrl-p** or arrows move, Enter opens, **Esc** → picker normal.

**Picker normal mode:** `j`/`k` move, `gg`/`G` top/bottom, Enter opens, `i`/`a` back to insert, **Esc** or `q` closes.

Search is native (fuzzy subsequence matcher + line scan). If `rg` is on `PATH`, grep uses it and falls back otherwise.

`gr` uses the same picker: each row is `file:line` with the source line as the preview. Insert and normal mode are unchanged.

## Shell hooks

`shellCommands` binds a leader sequence to a shell command. Quill runs it in the workspace root, off the main thread. The last non-empty stdout line is a file path, optionally `path:line` or `path:line:col`, and Quill opens it. A non-zero exit prints the error on the status line. The command string is config; Quill has no built-in knowledge of it.

```toml
[shellCommands]
d = "rvn daily"
```

An inline table works too: `shellCommands = { d = "rvn daily" }`.

`<leader>d` runs `rvn daily`.

## Language servers

Generic LSP 3.17 over stdio. **No default server** and nothing vault-specific. If the command is missing, editing still works.

Example `~/.config/quill/config.toml` (also under `examples/config.toml`). If `config.toml` is missing and `config.json` is still there, Quill reads the JSON once, writes an equivalent `config.toml`, and says so on the status line. The JSON file is left in place.

```toml
# `font` empty, or a family that is not installed, uses the system font.

leader = " "
# system follows macOS. light and dark stay put. A later :theme or <leader>tt is remembered.
theme = "system"
columnWidth = 70
fontSize = 16
font = ""
shiftWidth = 2

[leaderMaps]
sf = "findFiles"
sg = "liveGrep"

[shellCommands]
d = "rvn daily"

[[lsp.servers]]
name = "marksman"
command = "marksman"
arguments = ["server"]
extensions = [".md", ".markdown"]
languages = ["markdown"]
rootMarkers = [".git", ".marksman.toml"]
env = {}

[[lsp.servers]]
name = "rvn"
command = "rvn"
arguments = ["lsp"]
extensions = [".md", ".markdown"]
languages = ["markdown"]
rootMarkers = [".git"]
env = {}
```

`marksman` and `rvn lsp` are example command lines. Any other server is the same shape: set `command`, `arguments`, `extensions`, and `rootMarkers`.

Wired: `initialize`, `initialized`, `textDocument/didOpen|didChange|didSave|didClose`, completion, definition (`gd` / ⌘-click), references (`gr`), code action (`<leader>ca`), hover, `publishDiagnostics`, `workspace/executeCommand`. A chosen code action applies its `WorkspaceEdit` or runs its command. Server `workspace/applyEdit` is applied too. Those edits go through the engine and undo as one group. Server requests `workspace/configuration`, `workspace/workspaceFolders`, and capability registration are answered so generic servers can start. Edits for a file that is not the open buffer are left alone and reported on the status line.

## What is verified vs not

**Verified on Linux (`swift test`):** QuillVim (motions, operators, text objects, visual, `.` / undo, ex, leader, `-`, `gr`, `<leader>ca`), QuillLSP JSON-RPC framing and a mock-server lifecycle (initialize, document sync, completion, definition, references, code action, executeCommand, applyEdit, hover, diagnostics, missing-server), launch-argument and shell-hook parsing, QuillFS diffs (create/rename/delete/move), QuillSearch fuzzy + grep + picker insert/normal, QuillTOML (the config subset: tables, strings, numbers, bools, arrays, inline tables, arrays of tables).

**Unverified:** compiling or running the macOS app (no macOS toolchain here). TextKit 2 display-line `j`/`k`, the confirmation sheet, Trash deletes, and a live language server should be checked in Xcode.

## Recommended next steps

1. Build `Quill.app` on a Mac and open a large note (10k lines) to confirm restyle + typing stay smooth.
2. Point `lsp.servers` at marksman or another markdown server and try `gd`, hover, and diagnostics.
3. Walk an oil-style rename / `dd`+`p` move / `:w` confirm once on a throwaway folder.
4. Optional: incremental document sync, visual-block, and a marks/jumplist — deliberately out of v1.
