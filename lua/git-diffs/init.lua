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

--- @type WorktreeDiffType[]
local worktree_file_locations = {
  "worktree-index",
  "worktree-head",
  "worktree-upstream",
  "worktree-mergebase",
}

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

local initial_state = {
  new_winnr = nil,
  new_bufnr = nil,
  old_winnr = nil,
  old_bufnr = nil,
  file_list_winnr = nil,
  file_list_bufnr = nil,
  diff_tabnr = nil,
  edit_tabnr = nil,
}

local state = vim.deepcopy(initial_state)
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

  vim.api.nvim_win_call(state.old_winnr, vim.cmd.diffoff)
  vim.api.nvim_win_call(state.new_winnr, vim.cmd.diffoff)

  if use_real_filename_bufnr then
    vim.api.nvim_win_set_buf(state.new_winnr, filename_bufnr)
  else
    vim.api.nvim_win_set_buf(state.new_winnr, state.new_bufnr)
    assert(new_lines ~= nil)
    vim.api.nvim_buf_set_lines(state.new_bufnr, 0, -1, false, new_lines)
  end
  vim.api.nvim_buf_set_lines(state.old_bufnr, 0, -1, false, old_lines)

  vim.api.nvim_win_call(state.old_winnr, vim.cmd.diffthis)
  vim.api.nvim_win_call(state.new_winnr, vim.cmd.diffthis)
end)

--- @class OpenDiffViewParams
--- @field diff_type DiffType
--- @field upstream_branch? string

--- @type fun(opts: OpenDiffViewParams): nil
M.open_diff_view = cb_async(function(opts)
  if state.diff_tabnr ~= nil then
    vim.api.nvim_set_current_tabpage(state.diff_tabnr)
    return
  end

  state.edit_tabnr = vim.api.nvim_get_current_tabpage()
  vim.cmd.tabnew()
  state.diff_tabnr = vim.api.nvim_get_current_tabpage()

  vim.t.git_diffs_view_open = true

  state.upstream_branch = opts.upstream_branch
  state.new_bufnr = vim.api.nvim_create_buf(false, true)
  state.new_winnr = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.new_winnr, state.new_bufnr)
  vim.wo[state.new_winnr].winbar = "New"

  state.old_bufnr = vim.api.nvim_create_buf(false, true)
  state.old_winnr = vim.api.nvim_open_win(state.old_bufnr, true, {
    split = "left",
    win = state.new_winnr,
  })
  vim.wo[state.old_winnr].winbar = "Old"

  state.file_list_bufnr = vim.api.nvim_create_buf(false, true)

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

      vim.bo[state.file_list_bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(state.file_list_bufnr, 0, -1, false, file_list_lines)
      vim.bo[state.file_list_bufnr].modifiable = false

      return file_list_lines
    end)
  end

  local file_list_lines = vim.async.await(set_file_list()) --[[@as string[] ]]
  ensure_main_loop()
  vim.cmd "botright 10split"
  state.file_list_winnr = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.file_list_winnr, state.file_list_bufnr)
  vim.wo[state.file_list_winnr].winbar = "Files"
  vim.bo[state.file_list_bufnr].filetype = "git-diffs-view-file-list"

  if #file_list_lines > 0 then
    update_diff_view {
      diff_type = opts.diff_type,
      rel_filename = file_list_lines[1],
      upstream_branch = state.upstream_branch,
    }
  end

  vim.api.nvim_create_autocmd({ "CursorMoved" }, {
    group = vim.api.nvim_create_augroup("GitDiffViewFileListCursorMove", { clear = true }),
    buf = state.file_list_bufnr,
    callback = function()
      local rel_filename =
        vim.api.nvim_win_call(state.file_list_winnr, vim.api.nvim_get_current_line)
      if rel_filename == nil or rel_filename == "" then
        return
      end
      update_diff_view {
        diff_type = opts.diff_type,
        rel_filename = rel_filename,
        upstream_branch = state.upstream_branch,
      }
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup("GitDiffViewFileListWinClosed", { clear = true }),
    pattern = {
      tostring(state.new_winnr),
      tostring(state.old_winnr),
      tostring(state.file_list_winnr),
    },
    callback = function()
      iter = iter + 1
      local diff_tabnr = state.diff_tabnr
      if
        diff_tabnr ~= nil
        and vim.api.nvim_tabpage_is_valid(diff_tabnr)
        and #vim.api.nvim_list_tabpages() == 1
      then
        state = vim.deepcopy(initial_state)
        vim.defer_fn(function()
          if vim.api.nvim_tabpage_is_valid(diff_tabnr) and #vim.api.nvim_list_tabpages() == 1 then
            vim.cmd.quitall()
          end
        end, 0)
        return
      end

      if vim.api.nvim_win_is_valid(state.new_winnr) then
        vim.api.nvim_win_close(state.new_winnr, false)
      end
      if vim.api.nvim_win_is_valid(state.old_winnr) then
        vim.api.nvim_win_close(state.old_winnr, false)
      end
      if vim.api.nvim_win_is_valid(state.file_list_winnr) then
        vim.api.nvim_win_close(state.file_list_winnr, false)
      end
      state = vim.deepcopy(initial_state)
    end,
  })

  vim.keymap.set(
    "n",
    "<Plug>GitDiffViewScrollDown",
    cb_async(function()
      local winnr = state.old_winnr
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
    { desc = "Scroll down in the diff view", buffer = state.file_list_bufnr }
  )

  vim.keymap.set(
    "n",
    "<Plug>GitDiffViewScrollUp",
    cb_async(function()
      local winnr = state.old_winnr
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
    { desc = "Scroll up in the diff view", buffer = state.file_list_bufnr }
  )

  vim.keymap.set(
    "n",
    "<Plug>GitDiffViewRefresh",
    cb_async(function()
      vim.async.await(set_file_list())
      ensure_main_loop()
      notify(vim.log.levels.INFO, "Refreshing file list")
    end),
    { desc = "Scroll up in the diff view", buffer = state.file_list_bufnr }
  )

  vim.keymap.set("n", "<Plug>GitDiffViewSwitchToBuffer", function()
    local rel_filename = vim.api.nvim_win_call(state.file_list_winnr, vim.api.nvim_get_current_line)
    if rel_filename == nil or rel_filename == "" then
      notify(vim.log.levels.WARN, "No file is selected")
      return
    end

    if not vim.api.nvim_tabpage_is_valid(state.edit_tabnr) then
      notify(vim.log.levels.WARN, "Original editing tab is no longer available")
      return
    end

    local filename_bufnr = vim.fn.bufnr(rel_filename, 1)
    vim.api.nvim_set_current_tabpage(state.edit_tabnr)
    vim.api.nvim_win_set_buf(0, filename_bufnr)
  end, { desc = "Switch to selected file buffer", buffer = state.file_list_bufnr })

  vim.api.nvim_exec_autocmds("User", {
    pattern = "GitDiffViewOpen",
    data = {
      old_winnr = state.old_winnr,
      new_winnr = state.new_winnr,
      file_list_winnr = state.file_list_winnr,
      old_bufnr = state.old_bufnr,
      new_bufnr = state.new_bufnr,
      file_list_bufnr = state.file_list_bufnr,
    },
  })
end)

--- @class OpenSingleFileDiffViewParams
--- @field diff_type WorktreeDiffType
--- @field upstream_branch? string

M.open_single_file_diff_view = cb_async(function(opts)
  local worktree_bufnr = vim.api.nvim_get_current_buf()
  local worktree_bufname = vim.api.nvim_buf_get_name(worktree_bufnr)
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
  vim.cmd.tabnew()
  local tab_worktree_winnr = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(tab_worktree_winnr, worktree_bufnr)

  vim.t.diff_view = true

  local old_bufnr = vim.api.nvim_create_buf(false, true)
  local old_winnr = vim.api.nvim_open_win(old_bufnr, true, {
    split = "left",
    win = tab_worktree_winnr,
  })

  ensure_main_loop()
  local _, old_file_location = get_file_locations_from_diff_type(opts.diff_type)
  local old_str = vim.async.await(resolve_file_contents {
    file_location = old_file_location,
    rel_filename = curr_bufname,
    upstream_branch = opts.upstream_branch,
  }) --[[@as string?]]
  if old_str == nil then
    notify(
      vim.log.levels.WARN,
      "could not resolve old snapshot: file=%s location=%s",
      curr_bufname,
      old_file_location
    )
    return
  end
  local old_lines = split_file_contents(old_str)

  ensure_main_loop()
  vim.api.nvim_buf_set_lines(old_bufnr, 0, -1, false, old_lines)

  vim.bo[old_bufnr].filetype = curr_filetype

  pcall(vim.api.nvim_win_set_cursor, old_winnr, curr_cursor)
  vim.api.nvim_win_set_cursor(tab_worktree_winnr, curr_cursor)
  vim.api.nvim_set_current_win(tab_worktree_winnr)

  vim.bo[old_bufnr].modifiable = false
  vim.bo[old_bufnr].bufhidden = "wipe"

  vim.wo[old_winnr].winbar = "HEAD"
  vim.wo[tab_worktree_winnr].winbar = "Worktree"

  vim.api.nvim_win_call(old_winnr, vim.cmd.diffthis)
  vim.api.nvim_win_call(tab_worktree_winnr, vim.cmd.diffthis)

  vim.keymap.set("n", "<Plug>GitDiffsSingleFileDiffViewClose", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    vim.cmd.tabclose()
    vim.api.nvim_set_current_buf(worktree_bufnr)
    local line_count = vim.api.nvim_buf_line_count(worktree_bufnr)
    local clamped = math.min(cursor[1], line_count)
    vim.api.nvim_win_set_cursor(0, { clamped, cursor[2] })
  end, { buffer = true })
end)

--- @param opts OpenDiffViewParams
M.toggle_diff_view = function(opts)
  if vim.t.git_diffs_view_open == true then
    vim.api.nvim_win_close(state.file_list_winnr, false)
    return
  end
  M.open_diff_view(opts)
end

return M
