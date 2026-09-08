# CLAUDE.md - vim-vp4 Plugin Development Guide

## Project Overview

**vim-vp4** is a Vim plugin for Perforce (P4) integration, heavily inspired by vim-fugitive. It allows users to interact with Perforce directly from Vim without leaving the editor.

- **Author:** Emily Ng (original), with local extensions
- **License:** GPL v3
- **Language:** Vimscript (pure, no external dependencies beyond `p4` CLI)

---

## Repository Structure

```
vim-vp4/
├── autoload/vp4.vim    # Core implementation (~1700+ lines)
├── plugin/vp4.vim      # Entry point: config defaults, autocommands, command definitions
├── doc/vp4.txt         # Vim help documentation (:help vp4)
├── doc/tags            # Auto-generated help tags (do not manually edit)
├── README.md           # User-facing documentation (English)
├── FILELOG_DIFF_USAGE.md  # Usage guide for Vp4FilelogDiff (Chinese)
└── LICENSE             # GPL v3
```

---

## Architecture

### Loading Mechanism

- `plugin/vp4.vim` is loaded at Vim startup:
  - Guards against duplicate loading (`g:loaded_vp4`)
  - Requires `p4` to be executable
  - Sets all configuration defaults via `s:set()`
  - Registers autocommands (`PromptOnWrite`, `Vp4Enter`)
  - Defines all `:Vp4*` commands that call into `autoload/vp4.vim`
- `autoload/vp4.vim` is lazy-loaded on first use; all public functions use the `vp4#` namespace

### Naming Conventions

| Pattern | Meaning |
|---------|---------|
| `vp4#FunctionName()` | Public autoloaded function (callable from commands) |
| `s:FunctionName()` | Script-local (private) helper function |
| `g:vp4_*` | User-configurable global option |
| `g:_vp4_*` | Internal plugin state (not for user modification) |
| `b:vp4_*` | Buffer-scoped variable for external program integration |

### Code Organization in `autoload/vp4.vim`

Sections are delimited by fold markers `{{{` / `}}}`:
1. Explorer window width config & data structures
2. Helper/utility functions
3. Perforce system call wrappers
4. Perforce fstat/query helpers
5. Client/workspace detection
6. File editing commands (Add, Delete, Edit, Reopen, Revert)
7. Change specification commands (Change, Describe, Shelve)
8. Analysis commands (Diff, Annotate, Filelog, FilelogDiff)
9. Depot Explorer
10. Passive features (PromptForOpen, CheckServerPath)

---

## Commands Reference

### Analysis
| Command | Description |
|---------|-------------|
| `:[range]Vp4Annotate [q]` | Scrollbound split showing changelist/date/user per line |
| `:Vp4AnnotateLine` | Annotate single line under cursor |
| `:Vp4Diff [s][p][@{cl}][#{rev}]` | Diff vs depot/shelved/previous/specific revision |
| `:Vp4Filelog [max]` | Populate location list with file revision history |
| `:Vp4FilelogDiff` | Show unified diff for selected revision in filelog |
| `:Vp4Info` | Show `p4 fstat` for current file |

### Change Specification
| Command | Description |
|---------|-------------|
| `:Vp4Change` | Open/edit changelist description |
| `:Vp4Describe` | Preview changelist description for current file |
| `:Vp4Shelve[!]` | Shelve current file; `!` overwrites existing shelf |

### File Editing
| Command | Description |
|---------|-------------|
| `:Vp4Add` | Open for add |
| `:Vp4Delete[!]` | Open for delete; `!` skips confirmation |
| `:Vp4Edit [action]` | Open for edit; optional action: `integrate`/`branch`/`move` |
| `:Vp4Reopen` | Move file to a different changelist |
| `:Vp4Revert[!]` | Revert; `!` skips confirmation |
| `:Vp4QuickfixEdit` | Open all files in quickfix list for edit (skips already-opened incl. default) |
| `:Vp4CoEdit` | Open all files in quickfix list for edit (same skip logic as `Vp4Edit`) |

### Exploration
| Command | Description |
|---------|-------------|
| `:Vp4Explore [path]` | Open depot tree explorer |
| `:Vp4 <cmd>` | Run arbitrary `p4` command, output to buffer |

---

## Key Functions (autoload/vp4.vim)

### Perforce Execution Layer
- `s:PerforceSystem(cmd)` — Run `p4 <cmd>`, return output string
- `s:PerforceSystemWithClient(cmd, client)` — Run with `-c <client>`
- `s:PerforceSystemWithFile(cmd, filepath)` — Run using file's detected client
- `s:PerforceRead(cmd)` — Read p4 output into current buffer
- `s:PerforceWrite(cmd)` — Write current buffer to p4 command stdin
- `vp4#PerforceSystemWr(...)` — Public wrapper; output to scratch buffer

### fstat Queries
- `s:PerforceFstat(field, filename)` — Get single fstat field
- `s:PerforceExists(filename)` — Is file in depot?
- `s:PerforceOpened(filename)` — Is file opened for edit?
- `s:PerforceGetCurrentChangelist(filename)` — Return current CL number
- `s:PerforceHaveRevision(filename)` — Return have revision number

### Multi-Client/Workspace Support
- `s:GetClientName()` — Cached current client via `p4 -Mj -ztag info`
- `s:GetWorkspaceForFile(filename)` — Returns full workspace dict (`Name`, `Root`, …) for a path; uses `g:vp4_client_for_file_cmd` if set, falls back to `p4 info`
- `vp4#GetWorkspaceForFile(filename)` — Public wrapper around the above for use outside the plugin
- `s:GetClientNameForFile(filename)` — Thin wrapper; returns `Name` from `s:GetWorkspaceForFile`, falls back to `s:GetClientName()`

### Depot Explorer Data Structures
```
s:directory_data = {
  '<depot path>': {
    'name': '<dirname>/',
    'folded': 0|1,
    'files': [{'name': str, 'flags': str}, ...],
    'children': [<list of child depot paths>]
  }
}
s:line_map      = { <line_number>: <depot_path> }
s:directory_map = { <depot_path>: <local_path> }
```

---

## Configuration Variables

### User Options (`plugin/vp4.vim`)
| Variable | Default | Description |
|----------|---------|-------------|
| `g:vp4_perforce_executable` | `'p4'` | Path to p4 binary |
| `g:vp4_prompt_on_write` | `1` | Prompt to `p4 edit` on `:w` |
| `g:vp4_annotate_revision` | `0` | Show revision# instead of CL# in annotate |
| `g:vp4_open_loclist` | `1` | Auto-open location list after Filelog |
| `g:vp4_filelog_max` | `10` | Max revisions shown in Filelog |
| `g:vp4_debug` | `0` | Enable debug output via `echom` |
| `g:vp4_diff_suppress_header` | `1` | Suppress diff header lines |
| `g:vp4_print_suppress_header` | `1` | Suppress print header lines |
| `g:vp4_allow_open_depot_file` | `1` | Allow `vim //depot/path` syntax |
| `g:vp4_sync_options` | `''` | Extra options passed to `p4 sync` |
| `g:vp4_base_path_replacements` | `{}` | Dict of local path substitution rules |
| `g:vp4_disable_default_changelist` | `0` | Disable selecting default CL |
| `g:vp4_client_for_file_cmd` | `''` | Command to resolve client by filepath; called as `<cmd> <shellescape(path)>`, must return JSON with a `'Name'` field; if empty, falls back to default client |

### Explorer Options (`autoload/vp4.vim`)
| Variable | Default | Description |
|----------|---------|-------------|
| `g:vp4_explore_width` | `'auto'` | Explorer width: `'auto'`, fixed number, or `'20%'` |
| `g:vp4_explore_min_width` | `30` | Minimum width in auto mode |
| `g:vp4_explore_max_width` | `60` | Maximum width in auto mode |

### Internal State (do not set manually)
- `g:_vp4_client` — Cached client name
- `g:_vp4_curpos` — Saved cursor position
- `g:_vp4_filetype` — Saved filetype
- `g:_vp4_loclist_winnr` — Location list window number
- `g:_vp4_filelog_data` — Filelog revision data array
- `g:_vp4_diff_return_tabpage` / `g:_vp4_diff_return_winnr` — Diff navigation state

### Buffer Variables
Buffer-scoped variables can be set by external programs to influence plugin behavior:

| Variable | Type | Purpose |
|----------|------|---------|
| `b:vp4_file_depot_path` | String | When set, `:Vp4Filelog` queries this depot path instead of deriving it from the current file. Enables cross-workspace/stream filelog queries. Example: `let b:vp4_file_depot_path = '//Publish/path/file.cpp'` |

---

## External Dependencies

| Tool | Required | Purpose |
|------|----------|---------|
| `p4` | **Yes** — plugin won't load without it | All Perforce operations |
| `ngr` | No (graceful fallback) | Multi-client workspace guessing via `ngr p4 client -p <path>` |

Vim requirements: JSON parsing (`json_decode`), Vim 8+ or Neovim recommended.

---

## Development Notes

### Adding a New Command
1. Implement `vp4#NewCommand(...)` in `autoload/vp4.vim`
2. Register it in `plugin/vp4.vim`: `command! -nargs=? Vp4New call vp4#NewCommand(<f-args>)`
3. Document it in `doc/vp4.txt` under the appropriate section

### Debug Mode
Enable with `:let g:vp4_debug = 1`. All `s:Debug(msg)` calls will print via `echom`.

### Testing
The repo has a `t/` directory (git-ignored) and a `Makefile` (git-ignored). No test files are committed. Manual testing is the primary approach.

### Vimscript Patterns Used
- **Fold markers:** `" {{{ Section` / `" }}}` for code folding
- **Error handling:** `try/catch` around JSON decoding and p4 calls
- **Buffer management:** scratch buffers with `setlocal buftype=nofile noswapfile`
- **Range commands:** `<line1>,<line2>` passed to functions for visual-selection support
- **Bang modifier:** `<bang>0` pattern — functions receive `1` for `!`, `0` otherwise
- **Scrollbind:** Annotation split uses `scrollbind` + `cursorbind`
- **Diff mode:** `diffthis` / `diffoff` for Vp4Diff

### Vp4Diff Argument Syntax
```
:Vp4Diff          → diff vs #have (depot version)
:Vp4Diff s        → diff vs shelved in current CL
:Vp4Diff p        → diff vs previous revision (#have - 1)
:Vp4Diff @12345   → diff vs shelved in CL 12345
:Vp4Diff #3       → diff vs revision #3
```

### Vp4Diff Implementation Notes
- The depot-side window is opened with `noautocmd` to prevent the `Vp4Enter` `BufReadCmd`
  autocommand from firing on depot paths (e.g. `//depot/...#have`). Without `noautocmd`,
  `CheckServerPath` would be invoked, set `nomodifiable`, and cause **E21** when the function
  tries to clear the buffer with `ggdG`.
- After both windows call `diffthis`, focus returns to the original file window via `wincmd p`,
  then `gg]c` jumps to the first diff hunk automatically.

### Vp4Filelog + Vp4FilelogDiff Workflow
1. `:Vp4Filelog` populates location list; `d` key in loclist triggers `Vp4FilelogDiff`
2. `g:_vp4_filelog_data` stores parsed revision metadata
3. `Vp4FilelogDiff` runs `p4 diff2 -du <file>#prev <file>#rev` and renders in a new tab
4. `q` in the diff tab closes it and returns to the loclist window

**Cross-Workspace Support:**
- When `b:vp4_file_depot_path` is set, `:Vp4Filelog` uses that depot path instead of deriving from the current file
- This allows querying filelogs for files in other perforce branches/streams without switching workspaces
- Useful for external tools that set this variable to enable interactive filelog queries on temporary files

---

## Recent Changes (from git log)

- `feat: cross-workspace Filelog via buffer variable` — `:Vp4Filelog` now checks for `b:vp4_file_depot_path`
  and uses it to query filelogs across perforce branches/streams independent of current workspace.
  Allows external tools (e.g. `ngr p4 print`) to set this variable for seamless cross-workspace queries.
- `feat: add Vp4CoEdit` — Open quickfix files for edit with same skip logic as `Vp4Edit`
  (already-opened files with action other than integrate/branch/move/add are skipped)
- `fix: Vp4Diff use noautocmd to prevent E21` — Use `noautocmd` when opening the depot-side diff
  window so `BufReadCmd`/`CheckServerPath` does not set `nomodifiable` before the buffer is cleared
- `feat: Vp4Diff auto-jump to first diff hunk` — After opening the diff split, cursor returns to
  the original file window and jumps to the first diff hunk with `gg]c`
- `feat: allow reopen iterate as edit` — Vp4Edit can reopen with integrate/branch/move action
- `feat: don't discard p4 error` — Error output from p4 is now preserved/shown
- `fix: workspace commands` — Fixes for multi-workspace command execution
- `feat: revert with multiple workspaces` — Vp4Revert handles multiple p4 clients
- `feat: fix diff with multiple workspaces` — Vp4Diff works correctly across clients
