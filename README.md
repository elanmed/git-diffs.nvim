# `git-diffs.nvim`

A minimal plugin to view, navigate, and reset git hunks. Also includes a diff view for comparing any two git file locations.

## Features

- 1 source file (~730 LOC), no dependencies
- Async diff computation via coroutines (no UI freezing)
- Signs update on every edit with debouncing (300ms)
- Watches `.git/index` and `.git/HEAD` for external changes (e.g. `git checkout`, `git stash`, `git reset`)
- Navigate to next/previous hunk with wrapping
- Reset a single hunk, a visual selection of hunks, or the entire file
- Diff view: compare worktree, index, HEAD, upstream, and merge-base versions in a side-by-side split with file list

## Example config

```lua
vim.g.git_diffs = {
  smooth_scroll = true,
}

vim.keymap.set("n", "<leader>gd", function()
  require("git-diffs").toggle_diff_view { diff_type = "worktree-index" }
end)
vim.keymap.set("n", "<leader>gD", function()
  require("git-diffs").toggle_diff_view { diff_type = "worktree-head" }
end)
vim.keymap.set("n", "<leader>gm", function()
  require("git-diffs").toggle_diff_view { diff_type = "head-mergebase" }
end)
```

## Plug remaps

### `<Plug>GitDiffViewScrollDown`

Scroll down in the diff view (both splits simultaneously).

### `<Plug>GitDiffViewScrollUp`

Scroll up in the diff view (both splits simultaneously).

### `<Plug>GitDiffViewRefresh`

Refresh the list of files with diffs.

## API

### `require("git-diffs").open_diff_view(opts)`

Opens a new tab with a 3-pane diff view:

- **Old** (left): the old file version
- **New** (right): the new file version
- **Files** (bottom): list of changed files

`opts`:

- `diff_type` (`string`): one of `"worktree-index"`, `"worktree-head"`, `"worktree-upstream"`, `"worktree-mergebase"`, `"index-head"`, `"index-upstream"`, `"index-mergebase"`, `"head-upstream"`, `"head-mergebase"`
- `upstream_branch` (`string?`): upstream branch name (default: `"master"`)

If the diff view tab already exists, switches to it instead of creating a new one.

### `require("git-diffs").toggle_diff_view(opts)`

Toggles the diff view: opens it if not open, closes it if already open.

## Autocommand events

### `User GitDiffViewOpen`

Fired after the diff view opens. `data` contains `old_winnr`, `new_winnr`, `file_list_winnr`, `old_bufnr`, `new_bufnr`, `file_list_bufnr`.

## Filetype

The file list buffer in the diff view uses `git-diffs-view-file-list` filetype for custom highlighting or keymaps.
