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
    local file_contents --- @type string?

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

local initial_state_multi_file = {
  new_winnr = nil,
  new_bufnr = nil,
  old_winnr = nil,
  old_bufnr = nil,
  file_list_winnr = nil,
  file_list_bufnr = nil,
  diff_tabnr = nil,
  edit_tabnr = nil,
}
local state_multi_file = vim.deepcopy(initial_state_multi_file)

local initial_state_single_file = {
  worktree_winnr = nil,
  worktree_bufnr = nil,
  old_winnr = nil,
  old_bufnr = nil,
  diff_tabnr = nil,
  edit_tabnr = nil,
}
local state_single_file = vim.deepcopy(initial_state_single_file)

local iter = 0

--- @class UpdateDiffViewParams
--- @field diff_type DiffType
--- @field upstream_branch? string
--- @field rel_filename string

--- @type fun(opts: UpdateDiffViewParams): nil
local update_diff_view = cb_async(function(opts)
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
  if curr_iter ~= iter then
    return
  end

  old_str = nonnil(old_str, "Could not open " .. opts.rel_filename .. " from " .. old_file_location)
  local old_lines = split_file_contents(old_str)

  vim.api.nvim_win_call(state_multi_file.old_winnr, vim.cmd.diffoff)
  vim.api.nvim_win_call(state_multi_file.new_winnr, vim.cmd.diffoff)

  if use_real_filename_bufnr then
    vim.api.nvim_win_set_buf(state_multi_file.new_winnr, filename_bufnr)
  else
    vim.api.nvim_win_set_buf(state_multi_file.new_winnr, state_multi_file.new_bufnr)
    assert(new_lines ~= nil)
    vim.api.nvim_buf_set_lines(state_multi_file.new_bufnr, 0, -1, false, new_lines)
  end
  vim.api.nvim_buf_set_lines(state_multi_file.old_bufnr, 0, -1, false, old_lines)

  vim.api.nvim_win_call(state_multi_file.old_winnr, vim.cmd.diffthis)
  vim.api.nvim_win_call(state_multi_file.new_winnr, vim.cmd.diffthis)
end)

--- @class OpenMultiFileDiffViewParams
--- @field diff_type DiffType
--- @field upstream_branch? string

--- @type fun(opts: OpenMultiFileDiffViewParams): nil
M.open_multi_file_diff_view = cb_async(function(opts)
  if state_multi_file.diff_tabnr ~= nil then
    vim.api.nvim_set_current_tabpage(state_multi_file.diff_tabnr)
    return
  end

  state_multi_file.edit_tabnr = vim.api.nvim_get_current_tabpage()
  vim.cmd.tabnew()
  state_multi_file.diff_tabnr = vim.api.nvim_get_current_tabpage()

  state_multi_file.upstream_branch = opts.upstream_branch
  state_multi_file.new_bufnr = vim.api.nvim_create_buf(false, true)
  state_multi_file.new_winnr = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state_multi_file.new_winnr, state_multi_file.new_bufnr)
  vim.wo[state_multi_file.new_winnr].winbar = "New"

  state_multi_file.old_bufnr = vim.api.nvim_create_buf(false, true)
  state_multi_file.old_winnr = vim.api.nvim_open_win(state_multi_file.old_bufnr, true, {
    split = "left",
    win = state_multi_file.new_winnr,
  })
  vim.wo[state_multi_file.old_winnr].winbar = "Old"

  state_multi_file.file_list_bufnr = vim.api.nvim_create_buf(false, true)

  --- @type fun(): vim.async.Task<string[]>
  local set_file_list = function()
    --- @return string[]
    return vim.async.run(function()
      local file_list_str = vim.async.await(M.run_diff_cmd {
        diff_type = opts.diff_type,
        upstream_branch = opts.upstream_branch,
      }) --[[@as string?]]
      ensure_main_loop()
      file_list_str = nonnil(file_list_str, "")
      local file_list_lines = vim.split(file_list_str, "\n", { trimempty = true })

      vim.bo[state_multi_file.file_list_bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(state_multi_file.file_list_bufnr, 0, -1, false, file_list_lines)
      vim.bo[state_multi_file.file_list_bufnr].modifiable = false

      return file_list_lines
    end)
  end

  local file_list_lines = vim.async.await(set_file_list()) --[[@as string[] ]]
  ensure_main_loop()
  vim.cmd "botright 10split"
  state_multi_file.file_list_winnr = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state_multi_file.file_list_winnr, state_multi_file.file_list_bufnr)
  vim.wo[state_multi_file.file_list_winnr].winbar = "Files"
  vim.bo[state_multi_file.file_list_bufnr].filetype = "git-diffs-multi-file-diff-view-file-list"

  if #file_list_lines > 0 then
    update_diff_view {
      diff_type = opts.diff_type,
      rel_filename = file_list_lines[1],
      upstream_branch = state_multi_file.upstream_branch,
    }
  end

  vim.api.nvim_create_autocmd({ "CursorMoved" }, {
    group = vim.api.nvim_create_augroup("GitDiffsMultiFileDiffViewCursorMove", { clear = true }),
    buf = state_multi_file.file_list_bufnr,
    callback = function()
      local rel_filename =
        vim.api.nvim_win_call(state_multi_file.file_list_winnr, vim.api.nvim_get_current_line)
      if rel_filename == nil or rel_filename == "" then
        return
      end
      update_diff_view {
        diff_type = opts.diff_type,
        rel_filename = rel_filename,
        upstream_branch = state_multi_file.upstream_branch,
      }
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup(
      "GitDiffsMultiFileDiffViewFileListWinClosed",
      { clear = true }
    ),
    pattern = {
      tostring(state_multi_file.new_winnr),
      tostring(state_multi_file.old_winnr),
      tostring(state_multi_file.file_list_winnr),
    },
    callback = function()
      iter = iter + 1
      local diff_tabnr = state_multi_file.diff_tabnr
      if
        diff_tabnr ~= nil
        and vim.api.nvim_tabpage_is_valid(diff_tabnr)
        and #vim.api.nvim_list_tabpages() == 1
      then
        vim.cmd.quitall()
        return
      end

      maybe_close_winnr(state_multi_file.new_winnr)
      maybe_close_winnr(state_multi_file.old_winnr)
      maybe_close_winnr(state_multi_file.file_list_winnr)
      maybe_close_tabnr(state_multi_file.diff_tabnr)

      state_multi_file = vim.deepcopy(initial_state_multi_file)
    end,
  })

  vim.keymap.set(
    "n",
    "<Plug>GitDiffsMultiFileDiffViewScrollDown",
    cb_async(function()
      local winnr = state_multi_file.old_winnr
      if winnr == nil or not vim.api.nvim_win_is_valid(winnr) then
        notify(vim.log.levels.WARN, "Diff view window is no longer available")
        return
      end

      if is_smooth_scroll_enabled() then
        smooth_scroll(winnr, "j", get_scroll_num_lines(winnr))
      else
        vim.api.nvim_win_call(winnr, function()
          vim.cmd [[execute "normal! \<C-d>"]]
          vim.cmd.normal { "zz", bang = true }
        end)
      end
    end),
    { desc = "Scroll down in the diff view", buffer = state_multi_file.file_list_bufnr }
  )

  vim.keymap.set(
    "n",
    "<Plug>GitDiffsMultiFileDiffViewScrollUp",
    cb_async(function()
      local winnr = state_multi_file.old_winnr
      if winnr == nil or not vim.api.nvim_win_is_valid(winnr) then
        notify(vim.log.levels.WARN, "Diff view window is no longer available")
        return
      end

      if is_smooth_scroll_enabled() then
        smooth_scroll(winnr, "k", get_scroll_num_lines(winnr))
      else
        vim.api.nvim_win_call(winnr, function()
          vim.cmd [[execute "normal! \<C-u>"]]
          vim.cmd.normal { "zz", bang = true }
        end)
      end
    end),
    { desc = "Scroll up in the diff view", buffer = state_multi_file.file_list_bufnr }
  )

  vim.keymap.set(
    "n",
    "<Plug>GitDiffsMultiFileDiffViewRefresh",
    cb_async(function()
      vim.async.await(set_file_list())
      ensure_main_loop()
      notify(vim.log.levels.INFO, "Refreshing file list")
    end),
    { desc = "Scroll up in the diff view", buffer = state_multi_file.file_list_bufnr }
  )

  vim.keymap.set("n", "<Plug>GitDiffsMultiFileDiffViewSwitchToBuffer", function()
    local rel_filename =
      vim.api.nvim_win_call(state_multi_file.file_list_winnr, vim.api.nvim_get_current_line)
    if rel_filename == nil or rel_filename == "" then
      notify(vim.log.levels.WARN, "No file is selected")
      return
    end

    if not vim.api.nvim_tabpage_is_valid(state_multi_file.edit_tabnr) then
      notify(vim.log.levels.WARN, "Original editing tab is no longer available")
      return
    end

    local filename_bufnr = vim.fn.bufnr(rel_filename, 1)
    vim.api.nvim_set_current_tabpage(state_multi_file.edit_tabnr)
    vim.api.nvim_win_set_buf(0, filename_bufnr)
  end, { desc = "Switch to selected file buffer", buffer = state_multi_file.file_list_bufnr })

  vim.api.nvim_exec_autocmds("User", {
    pattern = "GitDiffsMultiFileDiffViewOpen",
    data = {
      old_winnr = state_multi_file.old_winnr,
      new_winnr = state_multi_file.new_winnr,
      file_list_winnr = state_multi_file.file_list_winnr,
      old_bufnr = state_multi_file.old_bufnr,
      new_bufnr = state_multi_file.new_bufnr,
      file_list_bufnr = state_multi_file.file_list_bufnr,
    },
  })
end)

local close_single_file_diff_view = function()
  if
    state_single_file.worktree_winnr == nil
    or state_single_file.worktree_bufnr == nil
    or not vim.api.nvim_win_is_valid(state_single_file.worktree_winnr)
    or not vim.api.nvim_buf_is_valid(state_single_file.worktree_bufnr)
  then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(state_single_file.worktree_winnr)
  local line_count = vim.api.nvim_buf_line_count(state_single_file.worktree_bufnr)
  local clamped = math.min(cursor[1], line_count)

  vim.api.nvim_win_set_buf(state_single_file.worktree_winnr, state_single_file.worktree_bufnr)
  vim.api.nvim_win_set_cursor(state_single_file.worktree_winnr, { clamped, cursor[2] })
  maybe_close_winnr(state_single_file.worktree_winnr)
end

--- @class OpenSingleFileDiffViewParams
--- @field diff_type WorktreeDiffType
--- @field upstream_branch? string

--- @type fun(opts: OpenSingleFileDiffViewParams): nil
M.open_single_file_diff_view = cb_async(function(opts)
  if state_single_file.diff_tabnr ~= nil then
    vim.api.nvim_set_current_tabpage(state_single_file.diff_tabnr)
    return
  end

  state_single_file.worktree_bufnr = vim.api.nvim_get_current_buf()
  local worktree_bufname = vim.api.nvim_buf_get_name(state_single_file.worktree_bufnr)
  if vim.bo.buftype ~= "" then
    notify(vim.log.levels.WARN, "aborting: current buffer buftype is %s", vim.bo.buftype)
    return
  end

  local curr_cursor = vim.api.nvim_win_get_cursor(0)
  local cwd = vim.uv.cwd()
  assert(cwd ~= nil)
  local curr_bufname = vim.fs.relpath(cwd, worktree_bufname)
  if curr_bufname == nil then
    notify(
      vim.log.levels.WARN,
      "aborting: could not resolve relative path for %s",
      worktree_bufname
    )
    return
  end

  local curr_filetype = vim.bo.filetype
  state_single_file.edit_tabnr = vim.api.nvim_get_current_tabpage()
  vim.cmd.tabnew()
  state_single_file.diff_tabnr = vim.api.nvim_get_current_tabpage()

  state_single_file.worktree_winnr = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state_single_file.worktree_winnr, state_single_file.worktree_bufnr)

  state_single_file.old_bufnr = vim.api.nvim_create_buf(false, true)
  state_single_file.old_winnr = vim.api.nvim_open_win(state_single_file.old_bufnr, true, {
    split = "left",
    win = state_single_file.worktree_winnr,
  })

  vim.api.nvim_exec_autocmds("User", {
    pattern = "GitDiffsSingleFileDiffViewOpen",
    data = {
      old_winnr = state_single_file.old_winnr,
      worktree_winnr = state_single_file.worktree_winnr,
      old_bufnr = state_single_file.old_bufnr,
      worktree_bufnr = state_single_file.worktree_bufnr,
    },
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup("GitDiffsSingleFileDiffViewWinClosed", { clear = true }),
    pattern = {
      tostring(state_single_file.worktree_winnr),
      tostring(state_single_file.old_winnr),
    },
    callback = function()
      if
        state_single_file.diff_tabnr ~= nil
        and vim.api.nvim_tabpage_is_valid(state_single_file.diff_tabnr)
        and #vim.api.nvim_list_tabpages() == 1
      then
        vim.cmd.quitall()
      end

      maybe_close_winnr(state_single_file.worktree_winnr)
      maybe_close_winnr(state_single_file.old_winnr)
      maybe_close_tabnr(state_single_file.diff_tabnr)

      state_single_file = vim.deepcopy(initial_state_single_file)
    end,
  })

  ensure_main_loop()
  local _, old_file_location = get_file_locations_from_diff_type(opts.diff_type)
  local old_str = vim.async.await(resolve_file_contents {
    file_location = old_file_location,
    rel_filename = curr_bufname,
    upstream_branch = opts.upstream_branch,
  }) --[[@as string?]]
  ensure_main_loop()
  if old_str == nil then
    notify(
      vim.log.levels.WARN,
      "could not resolve old snapshot: file=%s location=%s",
      curr_bufname,
      old_file_location
    )
    maybe_close_winnr(state_single_file.worktree_winnr)
    state_single_file = vim.deepcopy(initial_state_single_file)
    return
  end
  local old_lines = split_file_contents(old_str)

  vim.api.nvim_buf_set_lines(state_single_file.old_bufnr, 0, -1, false, old_lines)

  vim.bo[state_single_file.old_bufnr].filetype = curr_filetype

  pcall(vim.api.nvim_win_set_cursor, state_single_file.old_winnr, curr_cursor)
  vim.api.nvim_win_set_cursor(state_single_file.worktree_winnr, curr_cursor)
  vim.api.nvim_set_current_win(state_single_file.worktree_winnr)

  vim.bo[state_single_file.old_bufnr].modifiable = false
  vim.bo[state_single_file.old_bufnr].bufhidden = "wipe"

  vim.wo[state_single_file.old_winnr].winbar = old_file_location
  vim.wo[state_single_file.worktree_winnr].winbar = "worktree"

  vim.api.nvim_win_call(state_single_file.old_winnr, vim.cmd.diffthis)
  vim.api.nvim_win_call(state_single_file.worktree_winnr, vim.cmd.diffthis)

  vim.keymap.set("n", "<Plug>GitDiffsSingleFileDiffViewClose", function()
    if should_close_winnr(state_single_file.worktree_winnr) then
      close_single_file_diff_view()
    end
  end, { buffer = true })
end)

--- @param opts OpenMultiFileDiffViewParams
M.toggle_multi_file_diff_view = function(opts)
  local closed = maybe_close_winnr(state_multi_file.file_list_winnr)
  if closed then
    return
  end
  M.open_multi_file_diff_view(opts)
end

--- @param opts OpenSingleFileDiffViewParams
M.toggle_single_file_diff_view = function(opts)
  if should_close_winnr(state_single_file.worktree_winnr) then
    close_single_file_diff_view()
    return
  end

  M.open_single_file_diff_view(opts)
end

return M
