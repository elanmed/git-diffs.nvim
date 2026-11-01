# `git-diffs.nvim`

A minimal plugin for comparing Git file versions in a side-by-side diff view.

## Features

- 1 source file (~1000 LOC), no dependencies
- Compare worktree, index, HEAD, upstream, and merge-base versions in single-file and multi-file side-by-side views

## Example config

```lua
vim.g.git_diffs = {
  smooth_scroll = true,
}

vim.api.nvim_create_autocmd("User", {
  group = vim.api.nvim_create_augroup("GitDiffsMultiOpts", { clear = true }),
  pattern = "GitDiffsMultiBuffer",
  callback = function(ev)
    local data = ev.data
    for _, winnr in ipairs { data.old_winnr, data.new_winnr, data.file_list_winnr } do
      vim.wo[winnr].statusline = " "
    end

    for _, bufnr in ipairs { data.old_bufnr, data.new_bufnr, data.file_list_bufnr } do
      vim.keymap.set("n", "<C-n>", "<Plug>GitDiffsMultiListDown", { buffer = bufnr })
      vim.keymap.set("n", "<C-p>", "<Plug>GitDiffsMultiListUp", { buffer = bufnr })
      vim.keymap.set("n", "o", "<Plug>GitDiffsMultiSwitchBuffer", { buffer = bufnr })
      vim.keymap.set("n", "<leader>e", "<Plug>GitDiffsMultiRefresh", { buffer = bufnr })
    end

    vim.keymap.set("n", "<c-d>", "<Plug>GitDiffsMultiScrollDown", { buffer = data.file_list_bufnr })
    vim.keymap.set("n", "<c-u>", "<Plug>GitDiffsMultiScrollUp", { buffer = data.file_list_bufnr })
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

| Remap                                                           | Multi-file buffers              | Single-file buffers |
| --------------------------------------------------------------- | ------------------------------- | ------------------- |
| `<Plug>GitDiffsMultiScrollDown` / `<Plug>GitDiffsMultiScrollUp` | Files pane only                 | —                   |
| `<Plug>GitDiffsMultiListDown` / `<Plug>GitDiffsMultiListUp`     | Old, new, and file list buffers | —                   |
| `<Plug>GitDiffsMultiRefresh`                                    | Old, new, and file list buffers | —                   |
| `<Plug>GitDiffsMultiSwitchBuffer`                               | Old, new, and file list buffers | —                   |
| `<Plug>GitDiffsSingleClose`                                     | —                               | Worktree pane only  |

### `<Plug>GitDiffsMultiScrollDown`

Scroll down in the diff view (both splits simultaneously); map this on the multi-file view's file-list buffer. The corresponding `<Plug>GitDiffsMultiScrollUp` mapping scrolls up.

### `<Plug>GitDiffsMultiScrollUp`

Scroll up in the diff view (both splits simultaneously); map this on the multi-file view's file-list buffer.

### `<Plug>GitDiffsMultiListDown`

Move the file-list cursor to the next file; wraps from the last file to the first. Available from the old, new, and file-list buffers of a multi-file view.

### `<Plug>GitDiffsMultiListUp`

Move the file-list cursor to the previous file; wraps from the first file to the last. Available from the old, new, and file-list buffers of a multi-file view.

### `<Plug>GitDiffsMultiRefresh`

Refresh the list of files with diffs. Available from the old, new, and file-list buffers of a multi-file view.

### `<Plug>GitDiffsMultiSwitchBuffer`

Switch to the selected file's buffer in the tab from which the diff view was opened. Available from the old, new, and file-list buffers of a multi-file view.

### `<Plug>GitDiffsSingleClose`

Close the single-file diff view and return to the worktree buffer. This mapping is available in the worktree pane only.

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

Invoke `<Plug>GitDiffsSingleClose` to close the view and return to the worktree buffer.

### `require("git-diffs").toggle_multi_file_diff_view(opts)`

Toggles the multi-file diff view: opens it if not open, closes it if already open.

### `require("git-diffs").toggle_single_file_diff_view(opts)`

Toggles the single-file diff view: opens it if not open, closes it if already open. `opts` accepts the same worktree diff type and optional `upstream_branch` as `open_single_file_diff_view()`.

## Autocommand events

### `User GitDiffsSingleOpen`

Fired after the single-file diff view opens. `data` contains `old_winnr`, `worktree_winnr`, `old_bufnr`, `worktree_bufnr`.

### `User GitDiffsMultiBuffer`

Fired when multi-file buffers are initialized and when the new-side buffer changes.
