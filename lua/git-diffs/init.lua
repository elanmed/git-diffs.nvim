local M = {}

--- @param callback fun(...: any): any
--- @return fun(...: any): nil
local cb_async = function(callback)
  return function(...)
    local arguments = { ... }
    vim.async
      .run("cb_async_task", function()
        callback(unpack(arguments))
      end)
      :raise_on_error()
  end
end

local ensure_main_loop = function()
  vim.async.sleep(0)
end

--- @param level vim.log.levels
--- @param msg string
--- @param ... any
local notify = function(level, msg, ...)
  msg = "[git-diffs.nvim]: " .. msg
  vim.notify(msg:format(...), level)
end

--- @generic T
--- @param val T | nil
--- @param fallback T
--- @return T
local nonnil = function(val, fallback)
  if val == nil then
    return fallback
  end
  return val
end

--- @param winnr number
local should_close_winnr = function(winnr)
  return winnr ~= nil and vim.api.nvim_win_is_valid(winnr)
end

--- @param winnr number
local maybe_close_winnr = function(winnr)
  if should_close_winnr(winnr) then
    vim.api.nvim_win_close(winnr, false)
    return true
  end
  return false
end

--- @param tabnr number
local maybe_close_tabnr = function(tabnr)
  if tabnr ~= nil and vim.api.nvim_tabpage_is_valid(tabnr) then
    vim.api.nvim_set_current_tabpage(tabnr)
    vim.cmd.tabclose()
    return true
  end
  return false
end

--- @param group_name string
--- @param diff_tabnr integer
--- @param winnrs integer[]
--- @param on_close? fun(): nil
local register_diff_view_close_callback = function(group_name, diff_tabnr, winnrs, on_close)
  vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup(group_name, { clear = true }),
    pattern = vim.tbl_map(tostring, winnrs),
    callback = function()
      if on_close ~= nil then
        on_close()
      end
      if vim.api.nvim_tabpage_is_valid(diff_tabnr) and #vim.api.nvim_list_tabpages() == 1 then
        vim.cmd.quitall()
        return
      end

      for _, winnr in ipairs(winnrs) do
        maybe_close_winnr(winnr)
      end
      maybe_close_tabnr(diff_tabnr)
    end,
  })
end

--- @param file_contents string
--- @return string[]
local split_file_contents = function(file_contents)
  return vim.split(file_contents:gsub("\n$", ""), "\n", { plain = true })
end

--- @class GitDiffConfig
--- @field smooth_scroll? boolean
local is_smooth_scroll_enabled = function()
  --- @type GitDiffConfig
  local opts = nonnil(vim.g.git_diffs, {})
  return nonnil(opts.smooth_scroll, true)
end

--- @param winnr integer
--- @param direction "j" | "k"
--- @param num_lines integer
local smooth_scroll = function(winnr, direction, num_lines)
  for _ = 1, num_lines do
    if not vim.api.nvim_win_is_valid(winnr) then
      notify(vim.log.levels.WARN, "Diff view window is no longer available")
      return
    end

    vim.api.nvim_win_call(winnr, function()
      vim.cmd.normal { direction, bang = true }
    end)
    vim.async.sleep(10)
  end

  if vim.api.nvim_win_is_valid(winnr) then
    vim.api.nvim_win_call(winnr, function()
      vim.cmd.normal { "zz", bang = true }
    end)
  end
end

local get_scroll_num_lines = function(winnr)
  local num_lines = vim.wo[winnr].scroll
  if num_lines == 0 then
    num_lines = math.floor(vim.api.nvim_win_get_height(winnr) / 2)
  end
  return math.max(1, num_lines)
end

--- @param winnr integer
--- @param direction "j" | "k"
local scroll_diff_view = function(winnr, direction)
  if not should_close_winnr(winnr) then
    notify(vim.log.levels.WARN, "Diff view window is no longer available")
    return
  end

  if is_smooth_scroll_enabled() then
    smooth_scroll(winnr, direction, get_scroll_num_lines(winnr))
    return
  end

  local command = (function()
    if direction == "j" then
      return [[execute "normal! \\<C-d>"]]
    end
    return [[execute "normal! \\<C-u>"]]
  end)()
  vim.api.nvim_win_call(winnr, function()
    vim.cmd(command)
    vim.cmd.normal { "zz", bang = true }
  end)
end

--- @param path string
--- @return string[]
M.readfile = function(path)
  return vim.fn.readfile(path)
end

--- @alias FileLocation "worktree" | "index" | "head" | "upstream" | "mergebase"
--- @alias WorktreeDiffType "worktree-index" | "worktree-head" | "worktree-upstream" | "worktree-mergebase"
--- @alias DiffType WorktreeDiffType | "index-head" | "index-upstream" | "index-mergebase" | "head-upstream" | "head-mergebase"

--- @type fun(cmd: string[], opts: vim.SystemOpts?): vim.SystemCompleted
local system_async = vim.async.wrap(3, vim.system)

--- @type fun(cmd: string[], opts: vim.SystemOpts?): vim.async.Task<string?>
local vim_system_stdout = function(cmd, opts)
  --- @return string?
  return vim.async.run(function()
    local out = system_async(cmd, opts)
    if out.code ~= 0 then
      return nil
    end

    return out.stdout
  end)
end

--- @param rel_filename string
--- @return vim.async.Task<string?>
M.read_index_file = function(rel_filename)
  return vim_system_stdout { "git", "show", ":" .. rel_filename }
end

--- @param rel_filename string
--- @param upstream_branch? string
--- @return vim.async.Task<string?>
M.read_mergebase_file = function(rel_filename, upstream_branch)
  --- @return string?
  return vim.async.run(function()
    upstream_branch = nonnil(upstream_branch, "master")
    local merge_base = vim.async.await(
      vim_system_stdout { "git", "merge-base", "HEAD", "origin/" .. upstream_branch }
    ) --[[@as string?]]
    if merge_base == nil then
      return nil
    end
    merge_base = vim.trim(merge_base)
    return vim.async.await(vim_system_stdout { "git", "show", merge_base .. ":" .. rel_filename }) --[[@as string?]]
  end)
end

--- @class ResolveFileContentsParams
--- @field file_location FileLocation
--- @field rel_filename string
--- @field upstream_branch? string
--- @field file_bufnr? number

--- @type fun(opts: ResolveFileContentsParams): vim.async.Task<string?>
local resolve_file_contents = function(opts)
  --- @return string?
  return vim.async.run(function()
    --- @type string?
    local file_contents

    if opts.file_location == "worktree" then
      if opts.file_bufnr == nil then
        local file_lines = M.readfile(opts.rel_filename)
        file_contents = table.concat(file_lines, "\n")
      else
        ensure_main_loop()
        local buf_lines = vim.api.nvim_buf_get_lines(opts.file_bufnr, 0, -1, false)
        file_contents = table.concat(buf_lines, "\n")
      end
    elseif opts.file_location == "index" then
      file_contents = vim.async.await(M.read_index_file(opts.rel_filename)) --[[@as string?]]
    elseif opts.file_location == "head" then
      file_contents =
        vim.async.await(vim_system_stdout { "git", "show", "HEAD:" .. opts.rel_filename }) --[[@as string?]]
    elseif opts.file_location == "upstream" then
      local upstream_branch = nonnil(opts.upstream_branch, "master")
      file_contents = vim.async.await(vim_system_stdout {
        "git",
        "show",
        "origin/" .. upstream_branch .. ":" .. opts.rel_filename,
      }) --[[@as string?]]
    elseif opts.file_location == "mergebase" then
      file_contents =
        vim.async.await(M.read_mergebase_file(opts.rel_filename, opts.upstream_branch)) --[[@as string?]]
    end

    if file_contents == nil then
      return nil
    end
    return file_contents:gsub("\n$", "") .. "\n"
  end)
end

--- @param diff_type DiffType
--- @return FileLocation old_location
--- @return FileLocation new_location
local get_file_locations_from_diff_type = function(diff_type)
  local file_locations = vim.split(diff_type, "-")
  return file_locations[1], file_locations[2]
end

--- @class ResolveDiffCmdOpts
--- @field diff_type DiffType
--- @field upstream_branch? string

--- @class RunDiffCmdParams
--- @field diff_type DiffType
--- @field upstream_branch? string

--- @param opts RunDiffCmdParams
--- @return vim.async.Task<string?>
M.run_diff_cmd = function(opts)
  local upstream_branch = nonnil(opts.upstream_branch, "master")

  if opts.diff_type == "worktree-index" then
    return vim_system_stdout { "git", "diff", "--name-only" }
  elseif opts.diff_type == "worktree-head" then
    return vim_system_stdout { "git", "diff", "--name-only", "HEAD" }
  elseif opts.diff_type == "worktree-upstream" then
    return vim_system_stdout { "git", "diff", "--name-only", "origin/" .. upstream_branch }
  elseif opts.diff_type == "worktree-mergebase" then
    --- @return string?
    return vim.async.run(function()
      local merge_base = vim.async.await(
        vim_system_stdout { "git", "merge-base", "HEAD", "origin/" .. upstream_branch }
      ) --[[@as string?]]
      if merge_base == nil then
        return nil
      end
      merge_base = vim.trim(merge_base)
      return vim.async.await(vim_system_stdout { "git", "diff", "--name-only", merge_base }) --[[@as string?]]
    end)
  elseif opts.diff_type == "index-head" then
    return vim_system_stdout { "git", "diff", "--name-only", "--cached" }
  elseif opts.diff_type == "index-upstream" then
    return vim_system_stdout {
      "git",
      "diff",
      "--name-only",
      "--cached",
      "origin/" .. upstream_branch,
    }
  elseif opts.diff_type == "index-mergebase" then
    --- @return string?
    return vim.async.run(function()
      local merge_base = vim.async.await(
        vim_system_stdout { "git", "merge-base", "HEAD", "origin/" .. upstream_branch }
      ) --[[@as string?]]
      if merge_base == nil then
        return nil
      end
      merge_base = vim.trim(merge_base)
      return vim.async.await(
        vim_system_stdout { "git", "diff", "--name-only", "--cached", merge_base }
      ) --[[@as string?]]
    end)
  elseif opts.diff_type == "head-upstream" then
    return vim_system_stdout { "git", "diff", "--name-only", "HEAD", "origin/" .. upstream_branch }
  elseif opts.diff_type == "head-mergebase" then
    return vim_system_stdout {
      "git",
      "diff",
      "--name-only",
      "origin/" .. upstream_branch .. "...HEAD",
    }
  end

  error("Unsupported diff type: " .. opts.diff_type)
end

--- @class UpdateDiffViewParams
--- @field diff_type DiffType
--- @field upstream_branch? string
--- @field rel_filename string

--- @class OpenMultiFileDiffViewParams
--- @field diff_type DiffType
--- @field upstream_branch? string

--- @class MultiFileDiffViewNrs
--- @field new_winnr integer
--- @field new_bufnr integer
--- @field old_winnr integer
--- @field old_bufnr integer
--- @field file_list_winnr integer
--- @field file_list_bufnr integer
--- @field diff_tabnr integer
--- @field edit_tabnr integer

--- @class OpenSingleFileDiffViewParams
--- @field diff_type WorktreeDiffType
--- @field upstream_branch? string

--- @class SingleFileDiffViewNrs
--- @field worktree_winnr integer
--- @field worktree_bufnr integer
--- @field old_winnr integer
--- @field old_bufnr integer
--- @field diff_tabnr integer
--- @field edit_tabnr integer
--- @field rel_filename string
--- @field cursor integer[]
--- @field filetype string

local iter = 0

--- @class ExistingMultiFileDiffView
--- @field diff_tabnr integer
--- @field file_list_winnr integer

--- @class ExistingSingleFileDiffView
--- @field diff_tabnr integer
--- @field worktree_winnr integer

--- @return ExistingMultiFileDiffView?
local find_multi_file_diff_view = function()
  for _, tabnr in ipairs(vim.api.nvim_list_tabpages()) do
    for _, winnr in ipairs(vim.api.nvim_tabpage_list_wins(tabnr)) do
      local bufnr = vim.api.nvim_win_get_buf(winnr)
      if vim.bo[bufnr].filetype == "git-diffs-multi-file-diff-view-file-list" then
        return { diff_tabnr = tabnr, file_list_winnr = winnr }
      end
    end
  end
end

--- @return ExistingSingleFileDiffView?
local find_single_file_diff_view = function()
  for _, tabnr in ipairs(vim.api.nvim_list_tabpages()) do
    for _, winnr in ipairs(vim.api.nvim_tabpage_list_wins(tabnr)) do
      if vim.wo[winnr].winbar == "worktree" then
        return { diff_tabnr = tabnr, worktree_winnr = winnr }
      end
    end
  end
end

--- @param nrs MultiFileDiffViewNrs
--- @param opts UpdateDiffViewParams
--- @type fun(nrs: MultiFileDiffViewNrs, opts: UpdateDiffViewParams): nil
local update_diff_view = cb_async(function(nrs, opts)
  iter = iter + 1
  local curr_iter = iter

  local new_file_location, old_file_location = get_file_locations_from_diff_type(opts.diff_type)
  local filename_bufnr = vim.fn.bufnr(opts.rel_filename, 1)
  local use_real_filename_bufnr = vim.list_contains({
    "worktree-index",
    "worktree-head",
    "worktree-upstream",
    "worktree-mergebase",
  }, opts.diff_type)

  local new_lines = nil
  if not use_real_filename_bufnr then
    local new_str = vim.async.await(resolve_file_contents {
      file_location = new_file_location,
      rel_filename = opts.rel_filename,
      upstream_branch = opts.upstream_branch,
    }) --[[@as string?]]
    if curr_iter ~= iter then
      return
    end

    new_str =
      nonnil(new_str, "Could not open " .. opts.rel_filename .. " from " .. new_file_location)
    new_lines = split_file_contents(new_str)
  end

  if curr_iter ~= iter then
    return
  end

  local old_str = vim.async.await(resolve_file_contents {
    file_location = old_file_location,
    rel_filename = opts.rel_filename,
    upstream_branch = opts.upstream_branch,
  }) --[[@as string?]]
  ensure_main_loop()
  if
    curr_iter ~= iter
    or not vim.api.nvim_win_is_valid(nrs.old_winnr)
    or not vim.api.nvim_win_is_valid(nrs.new_winnr)
  then
    return
  end

  old_str = nonnil(old_str, "Could not open " .. opts.rel_filename .. " from " .. old_file_location)
  local old_lines = split_file_contents(old_str)

  vim.api.nvim_win_call(nrs.old_winnr, vim.cmd.diffoff)
  vim.api.nvim_win_call(nrs.new_winnr, vim.cmd.diffoff)

  if use_real_filename_bufnr then
    vim.api.nvim_win_set_buf(nrs.new_winnr, filename_bufnr)
  else
    vim.api.nvim_win_set_buf(nrs.new_winnr, nrs.new_bufnr)
    assert(new_lines ~= nil)
    vim.api.nvim_buf_set_lines(nrs.new_bufnr, 0, -1, false, new_lines)
  end
  vim.api.nvim_buf_set_lines(nrs.old_bufnr, 0, -1, false, old_lines)

  vim.api.nvim_win_call(nrs.old_winnr, vim.cmd.diffthis)
  vim.api.nvim_win_call(nrs.new_winnr, vim.cmd.diffthis)
end)

--- @return MultiFileDiffViewNrs
local init_multi_file_diff_view_nrs = function()
  local edit_tabnr = vim.api.nvim_get_current_tabpage()
  vim.cmd.tabnew()
  local diff_tabnr = vim.api.nvim_get_current_tabpage()

  local new_bufnr = vim.api.nvim_create_buf(false, true)
  local new_winnr = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(new_winnr, new_bufnr)
  vim.wo[new_winnr].winbar = "New"

  local old_bufnr = vim.api.nvim_create_buf(false, true)
  local old_winnr = vim.api.nvim_open_win(old_bufnr, true, {
    split = "left",
    win = new_winnr,
  })
  vim.wo[old_winnr].winbar = "Old"

  local file_list_bufnr = vim.api.nvim_create_buf(false, true)
  vim.cmd "botright 10split"
  local file_list_winnr = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(file_list_winnr, file_list_bufnr)
  vim.wo[file_list_winnr].winbar = "Files"
  vim.bo[file_list_bufnr].filetype = "git-diffs-multi-file-diff-view-file-list"

  return {
    new_winnr = new_winnr,
    new_bufnr = new_bufnr,
    old_winnr = old_winnr,
    old_bufnr = old_bufnr,
    file_list_winnr = file_list_winnr,
    file_list_bufnr = file_list_bufnr,
    diff_tabnr = diff_tabnr,
    edit_tabnr = edit_tabnr,
  }
end

--- @param nrs MultiFileDiffViewNrs
--- @param opts OpenMultiFileDiffViewParams
--- @return vim.async.Task<string[]>
local populate_multi_file_file_list = function(nrs, opts)
  --- @return string[]
  return vim.async.run(function()
    local file_list_str = vim.async.await(M.run_diff_cmd {
      diff_type = opts.diff_type,
      upstream_branch = opts.upstream_branch,
    }) --[[@as string?]]
    ensure_main_loop()
    file_list_str = nonnil(file_list_str, "")
    local file_list_lines = vim.split(file_list_str, "\n", { trimempty = true })

    vim.bo[nrs.file_list_bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(nrs.file_list_bufnr, 0, -1, false, file_list_lines)
    vim.bo[nrs.file_list_bufnr].modifiable = false

    return file_list_lines
  end)
end

--- @param nrs MultiFileDiffViewNrs
--- @param files string[]
--- @param opts OpenMultiFileDiffViewParams
local configure_multi_file_diff_view = function(nrs, files, opts)
  if #files > 0 then
    update_diff_view(nrs, {
      diff_type = opts.diff_type,
      rel_filename = files[1],
      upstream_branch = opts.upstream_branch,
    })
  end
end

--- @param nrs MultiFileDiffViewNrs
--- @param opts OpenMultiFileDiffViewParams
local register_multi_file_diff_view_callbacks = function(nrs, opts)
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = vim.api.nvim_create_augroup("GitDiffsMultiFileDiffViewCursorMove", { clear = true }),
    buf = nrs.file_list_bufnr,
    callback = function()
      if not vim.api.nvim_win_is_valid(nrs.file_list_winnr) then
        return
      end
      local rel_filename = vim.api.nvim_win_call(nrs.file_list_winnr, vim.api.nvim_get_current_line)
      if rel_filename == nil or rel_filename == "" then
        return
      end
      update_diff_view(nrs, {
        diff_type = opts.diff_type,
        rel_filename = rel_filename,
        upstream_branch = opts.upstream_branch,
      })
    end,
  })

  register_diff_view_close_callback(
    "GitDiffsMultiFileDiffViewFileListWinClosed",
    nrs.diff_tabnr,
    { nrs.new_winnr, nrs.old_winnr, nrs.file_list_winnr },
    function()
      iter = iter + 1
    end
  )

  vim.keymap.set(
    "n",
    "<Plug>GitDiffsMultiFileDiffViewScrollDown",
    cb_async(function()
      scroll_diff_view(nrs.old_winnr, "j")
    end),
    { desc = "Scroll down in the diff view", buffer = nrs.file_list_bufnr }
  )

  vim.keymap.set(
    "n",
    "<Plug>GitDiffsMultiFileDiffViewScrollUp",
    cb_async(function()
      scroll_diff_view(nrs.old_winnr, "k")
    end),
    { desc = "Scroll up in the diff view", buffer = nrs.file_list_bufnr }
  )

  vim.keymap.set(
    "n",
    "<Plug>GitDiffsMultiFileDiffViewRefresh",
    cb_async(function()
      vim.async.await(populate_multi_file_file_list(nrs, opts))
      ensure_main_loop()
      notify(vim.log.levels.INFO, "Refreshing file list")
    end),
    { desc = "Refresh file list", buffer = nrs.file_list_bufnr }
  )

  vim.keymap.set("n", "<Plug>GitDiffsMultiFileDiffViewSwitchToBuffer", function()
    local rel_filename = vim.api.nvim_win_call(nrs.file_list_winnr, vim.api.nvim_get_current_line)
    if rel_filename == nil or rel_filename == "" then
      notify(vim.log.levels.WARN, "No file is selected")
      return
    end
    if not vim.api.nvim_tabpage_is_valid(nrs.edit_tabnr) then
      notify(vim.log.levels.WARN, "Original editing tab is no longer available")
      return
    end
    local filename_bufnr = vim.fn.bufnr(rel_filename, 1)
    vim.api.nvim_set_current_tabpage(nrs.edit_tabnr)
    vim.api.nvim_win_set_buf(0, filename_bufnr)
  end, { desc = "Switch to selected file buffer", buffer = nrs.file_list_bufnr })

  vim.api.nvim_exec_autocmds("User", {
    pattern = "GitDiffsMultiFileDiffViewOpen",
    data = {
      old_winnr = nrs.old_winnr,
      new_winnr = nrs.new_winnr,
      file_list_winnr = nrs.file_list_winnr,
      old_bufnr = nrs.old_bufnr,
      new_bufnr = nrs.new_bufnr,
      file_list_bufnr = nrs.file_list_bufnr,
    },
  })
end

--- @param nrs SingleFileDiffViewNrs
local close_single_file_diff_view = function(nrs)
  if
    not vim.api.nvim_win_is_valid(nrs.worktree_winnr)
    or not vim.api.nvim_buf_is_valid(nrs.worktree_bufnr)
  then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(nrs.worktree_winnr)
  local line_count = vim.api.nvim_buf_line_count(nrs.worktree_bufnr)
  local clamped = math.min(cursor[1], line_count)
  vim.api.nvim_win_set_buf(nrs.worktree_winnr, nrs.worktree_bufnr)
  vim.api.nvim_win_set_cursor(nrs.worktree_winnr, { clamped, cursor[2] })
  maybe_close_winnr(nrs.worktree_winnr)
end

--- @return SingleFileDiffViewNrs?
local init_single_file_diff_view_nrs = function()
  if vim.bo.buftype ~= "" then
    notify(vim.log.levels.WARN, "aborting: current buffer buftype is %s", vim.bo.buftype)
    return nil
  end

  local worktree_bufnr = vim.api.nvim_get_current_buf()
  local worktree_bufname = vim.api.nvim_buf_get_name(worktree_bufnr)

  local cwd = vim.uv.cwd()
  assert(cwd ~= nil)
  local rel_filename = vim.fs.relpath(cwd, worktree_bufname)
  if rel_filename == nil then
    notify(
      vim.log.levels.WARN,
      "aborting: could not resolve relative path for %s",
      worktree_bufname
    )
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local filetype = vim.bo.filetype
  local edit_tabnr = vim.api.nvim_get_current_tabpage()

  vim.cmd.tabnew()
  local diff_tabnr = vim.api.nvim_get_current_tabpage()

  local worktree_winnr = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(worktree_winnr, worktree_bufnr)
  vim.wo[worktree_winnr].winbar = "worktree"

  local old_bufnr = vim.api.nvim_create_buf(false, true)
  local old_winnr = vim.api.nvim_open_win(old_bufnr, true, {
    split = "left",
    win = worktree_winnr,
  })

  --- @type SingleFileDiffViewNrs
  local nrs = {
    worktree_bufnr = worktree_bufnr,
    worktree_winnr = worktree_winnr,
    old_bufnr = old_bufnr,
    old_winnr = old_winnr,
    diff_tabnr = diff_tabnr,
    edit_tabnr = edit_tabnr,
    rel_filename = rel_filename,
    cursor = cursor,
    filetype = filetype,
  }
  return nrs
end

--- @param nrs SingleFileDiffViewNrs
--- @param opts OpenSingleFileDiffViewParams
local load_single_file_diff_view = function(nrs, opts)
  local _, old_file_location = get_file_locations_from_diff_type(opts.diff_type)
  local old_str = vim.async.await(resolve_file_contents {
    file_location = old_file_location,
    rel_filename = nrs.rel_filename,
    upstream_branch = opts.upstream_branch,
  }) --[[@as string?]]
  ensure_main_loop()
  if old_str == nil then
    notify(
      vim.log.levels.WARN,
      "could not resolve old snapshot: file=%s location=%s",
      nrs.rel_filename,
      old_file_location
    )
    maybe_close_winnr(nrs.worktree_winnr)
    return
  end

  local old_lines = split_file_contents(old_str)
  vim.api.nvim_buf_set_lines(nrs.old_bufnr, 0, -1, false, old_lines)
  vim.bo[nrs.old_bufnr].filetype = nrs.filetype
  pcall(vim.api.nvim_win_set_cursor, nrs.old_winnr, nrs.cursor)
  vim.api.nvim_win_set_cursor(nrs.worktree_winnr, nrs.cursor)
  vim.api.nvim_set_current_win(nrs.worktree_winnr)
  vim.bo[nrs.old_bufnr].modifiable = false
  vim.bo[nrs.old_bufnr].bufhidden = "wipe"
  vim.wo[nrs.old_winnr].winbar = old_file_location
  vim.wo[nrs.worktree_winnr].winbar = "worktree"

  vim.api.nvim_win_call(nrs.old_winnr, vim.cmd.diffthis)
  vim.api.nvim_win_call(nrs.worktree_winnr, vim.cmd.diffthis)
end

--- @param nrs SingleFileDiffViewNrs
local register_single_file_diff_view_callbacks = function(nrs)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "GitDiffsSingleFileDiffViewOpen",
    data = {
      old_winnr = nrs.old_winnr,
      worktree_winnr = nrs.worktree_winnr,
      old_bufnr = nrs.old_bufnr,
      worktree_bufnr = nrs.worktree_bufnr,
    },
  })

  register_diff_view_close_callback(
    "GitDiffsSingleFileDiffViewWinClosed",
    nrs.diff_tabnr,
    { nrs.worktree_winnr, nrs.old_winnr }
  )

  vim.keymap.set("n", "<Plug>GitDiffsSingleFileDiffViewClose", function()
    if should_close_winnr(nrs.worktree_winnr) then
      close_single_file_diff_view(nrs)
    end
  end, { buffer = nrs.worktree_bufnr })
end

--- @param opts OpenMultiFileDiffViewParams
--- @type fun(opts: OpenMultiFileDiffViewParams): nil
M.open_multi_file_diff_view = cb_async(function(opts)
  local existing = find_multi_file_diff_view()
  if existing ~= nil then
    vim.api.nvim_set_current_tabpage(existing.diff_tabnr)
    notify(vim.log.levels.INFO, "Multi-file diff view is already open")
    return
  end
  local nrs = init_multi_file_diff_view_nrs()
  register_multi_file_diff_view_callbacks(nrs, opts)
  local files = vim.async.await(populate_multi_file_file_list(nrs, opts)) --[[@as string[] ]]
  ensure_main_loop()
  configure_multi_file_diff_view(nrs, files, opts)
end)

--- @param opts OpenMultiFileDiffViewParams
M.toggle_multi_file_diff_view = function(opts)
  local existing = find_multi_file_diff_view()
  if existing == nil then
    M.open_multi_file_diff_view(opts)
    return
  end

  maybe_close_winnr(existing.file_list_winnr)
end

--- @param opts OpenSingleFileDiffViewParams
--- @type fun(opts: OpenSingleFileDiffViewParams): nil
M.open_single_file_diff_view = cb_async(function(opts)
  local existing = find_single_file_diff_view()
  if existing ~= nil then
    vim.api.nvim_set_current_tabpage(existing.diff_tabnr)
    notify(vim.log.levels.INFO, "Single-file diff view is already open")
    return
  end
  local nrs = init_single_file_diff_view_nrs()
  if nrs == nil then
    return
  end
  register_single_file_diff_view_callbacks(nrs)
  load_single_file_diff_view(nrs, opts)
end)

--- @param opts OpenSingleFileDiffViewParams
M.toggle_single_file_diff_view = function(opts)
  local existing = find_single_file_diff_view()
  if existing == nil then
    M.open_single_file_diff_view(opts)
    return
  end

  maybe_close_winnr(existing.worktree_winnr)
end

return M
