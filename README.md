# `git-diffs.nvim`

A minimal plugin for comparing Git file versions in a side-by-side diff view.

## Features

- 1 source file (~500 LOC), no dependencies
- Compare worktree, index, HEAD, upstream, and merge-base versions in single-file and multi-file side-by-side views

## Example config

```lua
vim.g.git_diffs = {
  smooth_scroll = true,
}

vim.api.nvim_create_autocmd({ "FileType" }, {
  group = vim.api.nvim_create_augroup("GitDiffViewRemaps", { clear = true }),
  pattern = "git-diffs-multi-file-diff-view-file-list",
  callback = function()
    vim.keymap.set("n", "<c-d>", "<Plug>GitDiffsMultiFileDiffViewScrollDown", { buffer = true })
    vim.keymap.set("n", "<c-u>", "<Plug>GitDiffsMultiFileDiffViewScrollUp", { buffer = true })
    vim.keymap.set("n", "<leader>e", "<Plug>GitDiffsMultiFileDiffViewRefresh", { buffer = true })
    vim.keymap.set("n", "o", "<Plug>GitDiffsMultiFileDiffViewSwitchToBuffer", { buffer = true })
  end,
})

vim.keymap.set("n", "<leader>gd", function()
  require("git-diffs").toggle_multi_file_diff_view { diff_type = "worktree-index" }
end)
vim.keymap.set("n", "<leader>gD", function()
  require("git-diffs").toggle_multi_file_diff_view { diff_type = "worktree-head" }
end)
vim.keymap.set("n", "<leader>gm", function()
  require("git-diffs").toggle_multi_file_diff_view { diff_type = "head-mergebase" }
end)
```

## Plug remaps

### `<Plug>GitDiffsMultiFileDiffViewScrollDown`

Scroll down in the diff view (both splits simultaneously).

### `<Plug>GitDiffsMultiFileDiffViewScrollUp`

Scroll up in the diff view (both splits simultaneously).

### `<Plug>GitDiffsMultiFileDiffViewRefresh`

Refresh the list of files with diffs.

### `<Plug>GitDiffsMultiFileDiffViewSwitchToBuffer`

Switch to the selected file's buffer in the tab from which the diff view was opened.

### `<Plug>GitDiffsSingleFileDiffViewClose`

Close the single-file diff view and return to the worktree buffer.

## API

### `require("git-diffs").open_multi_file_diff_view(opts)`

Opens a new tab with a 3-pane diff view:

- **Old** (left): the old file version
- **New** (right): the new file version
- **Files** (bottom): list of changed files

`opts`:

- `diff_type` (`string`): one of `"worktree-index"`, `"worktree-head"`, `"worktree-upstream"`, `"worktree-mergebase"`, `"index-head"`, `"index-upstream"`, `"index-mergebase"`, `"head-upstream"`, `"head-mergebase"`
- `upstream_branch` (`string?`): upstream branch name (default: `"master"`)

If the diff view tab already exists, switches to it instead of creating a new one. If the diff view is the last remaining tab, closing it quits Neovim unless modified buffers prevent quitting.

### `require("git-diffs").open_single_file_diff_view(opts)`

Open a side-by-side diff for the current worktree buffer, comparing it with the selected older file location. `opts` accepts a worktree diff type and optional `upstream_branch`.

Invoke `<Plug>GitDiffsSingleFileDiffViewClose` to close the view and return to the worktree buffer.

### `require("git-diffs").toggle_multi_file_diff_view(opts)`

Toggles the multi-file diff view: opens it if not open, closes it if already open.

### `require("git-diffs").toggle_single_file_diff_view(opts)`

Toggles the single-file diff view: opens it if not open, closes it if already open. `opts` accepts the same worktree diff type and optional `upstream_branch` as `open_single_file_diff_view()`.

## Autocommand events

### `User GitDiffsMultiFileDiffViewOpen`

Fired after the multi-file diff view opens. `data` contains `old_winnr`, `new_winnr`, `file_list_winnr`, `old_bufnr`, `new_bufnr`, `file_list_bufnr`.

### `User GitDiffsSingleFileDiffViewOpen`

Fired after the single-file diff view opens. `data` contains `old_winnr`, `worktree_winnr`, `old_bufnr`, `worktree_bufnr`.

## Filetype

The file list buffer in the diff view uses `git-diffs-multi-file-diff-view-file-list` filetype for custom highlighting or keymaps.
