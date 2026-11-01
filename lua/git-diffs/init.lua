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
local maybe_close_winnr = function(winnr)
  if winnr ~= nil and vim.api.nvim_win_is_valid(winnr) then
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

--- @param winnr integer
--- @param cursor integer[]
local set_cursor = function(winnr, cursor)
  local bufnr = vim.api.nvim_win_get_buf(winnr)
  local line = math.min(cursor[1], vim.api.nvim_buf_line_count(bufnr))
  pcall(vim.api.nvim_win_set_cursor, winnr, { line, cursor[2] })
end

--- @class RegisterDiffViewCloseCallbackOpts
--- @field group_name string
--- @field diff_tabnr integer
--- @field winnrs integer[]
--- @field on_close? fun(): nil

--- @param opts RegisterDiffViewCloseCallbackOpts
local register_diff_view_close_callback = function(opts)
  vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup(opts.group_name, { clear = true }),
    pattern = vim.tbl_map(tostring, opts.winnrs),
    callback = function()
      if opts.on_close ~= nil then
        opts.on_close()
      end
      if vim.api.nvim_tabpage_is_valid(opts.diff_tabnr) and #vim.api.nvim_list_tabpages() == 1 then
        vim.cmd.quitall()
        return
      end

      for _, winnr in ipairs(opts.winnrs) do
        maybe_close_winnr(winnr)
      end
      maybe_close_tabnr(opts.diff_tabnr)
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
  if winnr == nil or not vim.api.nvim_win_is_valid(winnr) then
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

local worktree_diff_types = {
  "worktree-index",
  "worktree-head",
  "worktree-upstream",
  "worktree-mergebase",
}

--- @param diff_type DiffType
local is_worktree_diff_type = function(diff_type)
  return vim.list_contains(worktree_diff_types, diff_type)
end

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

--- @param upstream_branch string
--- @return vim.async.Task<string?>
local get_merge_base = function(upstream_branch)
  return vim_system_stdout { "git", "merge-base", "HEAD", "origin/" .. upstream_branch }
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
      file_contents = vim.async.await(vim_system_stdout { "git", "show", ":" .. opts.rel_filename }) --[[@as string?]]
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
      local upstream_branch = nonnil(opts.upstream_branch, "master")
      local merge_base = vim.async.await(get_merge_base(upstream_branch)) --[[@as string?]]
      if merge_base ~= nil then
        merge_base = vim.trim(merge_base)
        file_contents = vim.async.await(
          vim_system_stdout { "git", "show", merge_base .. ":" .. opts.rel_filename }
        ) --[[@as string?]]
      end
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
      local merge_base = vim.async.await(get_merge_base(upstream_branch)) --[[@as string?]]
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
      local merge_base = vim.async.await(get_merge_base(upstream_branch)) --[[@as string?]]
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
--- @field keymap_bufnrs integer[]

--- @class OpenSingleFileDiffViewParams
--- @field diff_type WorktreeDiffType
--- @field upstream_branch? string

--- @class SingleFileDiffViewNrs
--- @field worktree_winnr integer
--- @field worktree_bufnr integer
--- @field edit_winnr integer
--- @field old_winnr integer
--- @field old_bufnr integer
--- @field diff_tabnr integer
--- @field edit_tabnr integer

--- @class SingleFileDiffViewContext
--- @field rel_filename string
--- @field cursor integer[]
--- @field filetype string

local iter = 0

--- @type fun(nrs: MultiFileDiffViewNrs, opts: OpenMultiFileDiffViewParams): vim.async.Task<string[]>
local populate_multi_file_file_list

--- @param nrs MultiFileDiffViewNrs
--- @param new_bufnr integer
--- @param rel_filename? string
local emit_multi_buffer_event = function(nrs, new_bufnr, rel_filename)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "GitDiffsMultiBuffer",
    data = {
      old_winnr = nrs.old_winnr,
      new_winnr = nrs.new_winnr,
      file_list_winnr = nrs.file_list_winnr,
      old_bufnr = nrs.old_bufnr,
      new_bufnr = new_bufnr,
      file_list_bufnr = nrs.file_list_bufnr,
      rel_filename = rel_filename,
    },
  })
end

--- @param nrs MultiFileDiffViewNrs
--- @param direction integer
local move_file_list_cursor = function(nrs, direction)
  if not vim.api.nvim_win_is_valid(nrs.file_list_winnr) then
    notify(vim.log.levels.WARN, "File list window is no longer available")
    return
  end

  vim.api.nvim_win_call(nrs.file_list_winnr, function()
    if direction > 0 then
      if vim.fn.line "." == vim.fn.line "$" then
        vim.cmd "normal! gg"
      else
        vim.cmd "normal! j"
      end
    elseif vim.fn.line "." == 1 then
      vim.cmd "normal! G"
    else
      vim.cmd "normal! k"
    end

    vim.cmd "redraw"
  end)
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = nrs.file_list_bufnr })
end

--- @class RegisterMultiBufferKeymapsOpts
--- @field nrs MultiFileDiffViewNrs
--- @field bufnr integer
--- @field diff_type DiffType
--- @field upstream_branch? string

--- @param opts RegisterMultiBufferKeymapsOpts
local register_multi_buffer_keymaps = function(opts)
  local nrs = opts.nrs
  local bufnr = opts.bufnr
  local diff_type = opts.diff_type
  local upstream_branch = opts.upstream_branch

  if vim.list_contains(nrs.keymap_bufnrs, bufnr) then
    return
  end

  vim.keymap.set("n", "<Plug>GitDiffsMultiListDown", function()
    local winnr = vim.api.nvim_get_current_win()
    if winnr == nrs.new_winnr or winnr == nrs.old_winnr or winnr == nrs.file_list_winnr then
      move_file_list_cursor(nrs, 1)
    end
  end, { buffer = bufnr })

  vim.keymap.set("n", "<Plug>GitDiffsMultiListUp", function()
    local winnr = vim.api.nvim_get_current_win()
    if winnr == nrs.new_winnr or winnr == nrs.old_winnr or winnr == nrs.file_list_winnr then
      move_file_list_cursor(nrs, -1)
    end
  end, { buffer = bufnr })

  vim.keymap.set("n", "<Plug>GitDiffsMultiSwitchBuffer", function()
    local winnr = vim.api.nvim_get_current_win()
    if winnr ~= nrs.new_winnr and winnr ~= nrs.old_winnr and winnr ~= nrs.file_list_winnr then
      return
    end

    --- @type integer[]?
    local cursor
    if
      winnr == nrs.new_winnr
      and is_worktree_diff_type(diff_type)
      and vim.bo[bufnr].buftype == ""
    then
      cursor = vim.api.nvim_win_get_cursor(winnr)
    end

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
    if cursor ~= nil then
      set_cursor(0, cursor)
    end
  end, { desc = "Switch to selected file buffer", buffer = bufnr })

  vim.keymap.set(
    "n",
    "<Plug>GitDiffsMultiRefresh",
    cb_async(function()
      local winnr = vim.api.nvim_get_current_win()
      if winnr ~= nrs.new_winnr and winnr ~= nrs.old_winnr and winnr ~= nrs.file_list_winnr then
        return
      end

      --- @type OpenMultiFileDiffViewParams
      local opts = { diff_type = diff_type, upstream_branch = upstream_branch }
      vim.async.await(populate_multi_file_file_list(nrs, opts))
      ensure_main_loop()
      notify(vim.log.levels.INFO, "Refreshing file list")
    end),
    { desc = "Refresh file list", buffer = bufnr }
  )

  table.insert(nrs.keymap_bufnrs, bufnr)
end

--- @param nrs MultiFileDiffViewNrs
local clear_file_list_navigation_keymaps = function(nrs)
  for _, bufnr in ipairs(nrs.keymap_bufnrs) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", "<Plug>GitDiffsMultiListDown")
      pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", "<Plug>GitDiffsMultiListUp")
      pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", "<Plug>GitDiffsMultiSwitchBuffer")
      pcall(vim.api.nvim_buf_del_keymap, bufnr, "n", "<Plug>GitDiffsMultiRefresh")
    end
  end
  nrs.keymap_bufnrs = {}
end

--- @class ExistingMultiFileDiffView
--- @field diff_tabnr integer
--- @field file_list_winnr integer

--- @class ExistingSingleFileDiffView
--- @field diff_tabnr integer
--- @field worktree_winnr integer
--- @field worktree_bufnr integer
--- @field edit_winnr integer

--- @return ExistingMultiFileDiffView?
local find_multi_file_diff_view = function()
  for _, tabnr in ipairs(vim.api.nvim_list_tabpages()) do
    for _, winnr in ipairs(vim.api.nvim_tabpage_list_wins(tabnr)) do
      local ok, is_multi_file_diff_view =
        pcall(vim.api.nvim_win_get_var, winnr, "git_diffs_multi_file_view")
      if ok and is_multi_file_diff_view then
        return { diff_tabnr = tabnr, file_list_winnr = winnr }
      end
    end
  end
end

--- @return ExistingSingleFileDiffView?
local find_single_file_diff_view = function()
  for _, tabnr in ipairs(vim.api.nvim_list_tabpages()) do
    for _, winnr in ipairs(vim.api.nvim_tabpage_list_wins(tabnr)) do
      local ok, is_single_file_diff_view =
        pcall(vim.api.nvim_win_get_var, winnr, "git_diffs_single_file_view")
      if ok and is_single_file_diff_view then
        local worktree_bufnr =
          vim.api.nvim_win_get_var(winnr, "git_diffs_single_file_worktree_bufnr")
        local edit_winnr = vim.api.nvim_win_get_var(winnr, "git_diffs_single_file_edit_winnr")
        return {
          diff_tabnr = tabnr,
          worktree_winnr = winnr,
          worktree_bufnr = worktree_bufnr,
          edit_winnr = edit_winnr,
        }
      end
    end
  end
end

--- @class UpdateDiffViewParams
--- @field diff_type DiffType
--- @field upstream_branch? string
--- @field rel_filename string

--- @param nrs MultiFileDiffViewNrs
--- @param opts UpdateDiffViewParams
--- @type fun(nrs: MultiFileDiffViewNrs, opts: UpdateDiffViewParams): nil
local update_diff_view = cb_async(function(nrs, opts)
  iter = iter + 1
  local curr_iter = iter

  local new_file_location, old_file_location = get_file_locations_from_diff_type(opts.diff_type)
  local filename_bufnr = vim.fn.bufnr(opts.rel_filename, 1)
  local use_real_filename_bufnr = is_worktree_diff_type(opts.diff_type)

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
  local previous_new_bufnr = vim.api.nvim_win_get_buf(nrs.new_winnr)

  if use_real_filename_bufnr then
    vim.api.nvim_win_set_buf(nrs.new_winnr, filename_bufnr)
    register_multi_buffer_keymaps {
      nrs = nrs,
      bufnr = filename_bufnr,
      diff_type = opts.diff_type,
      upstream_branch = opts.upstream_branch,
    }
  else
    vim.api.nvim_win_set_buf(nrs.new_winnr, nrs.new_bufnr)
    register_multi_buffer_keymaps {
      nrs = nrs,
      bufnr = nrs.new_bufnr,
      diff_type = opts.diff_type,
      upstream_branch = opts.upstream_branch,
    }
    assert(new_lines ~= nil)
    vim.api.nvim_buf_set_lines(nrs.new_bufnr, 0, -1, false, new_lines)
  end
  vim.api.nvim_buf_set_lines(nrs.old_bufnr, 0, -1, false, old_lines)

  vim.api.nvim_win_call(nrs.old_winnr, vim.cmd.diffthis)
  vim.api.nvim_win_call(nrs.new_winnr, vim.cmd.diffthis)

  local new_bufnr = vim.api.nvim_win_get_buf(nrs.new_winnr)
  if new_bufnr ~= previous_new_bufnr then
    emit_multi_buffer_event(nrs, new_bufnr, opts.rel_filename)
  end
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
  vim.api.nvim_win_set_var(file_list_winnr, "git_diffs_multi_file_view", true)
  vim.wo[file_list_winnr].winbar = "Files"

  return {
    new_winnr = new_winnr,
    new_bufnr = new_bufnr,
    old_winnr = old_winnr,
    old_bufnr = old_bufnr,
    file_list_winnr = file_list_winnr,
    file_list_bufnr = file_list_bufnr,
    diff_tabnr = diff_tabnr,
    edit_tabnr = edit_tabnr,
    keymap_bufnrs = {},
  }
end

--- @param nrs MultiFileDiffViewNrs
--- @param opts OpenMultiFileDiffViewParams
--- @return vim.async.Task<string[]>
populate_multi_file_file_list = function(nrs, opts)
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
  for _, bufnr in ipairs { nrs.old_bufnr, nrs.new_bufnr, nrs.file_list_bufnr } do
    register_multi_buffer_keymaps {
      nrs = nrs,
      bufnr = bufnr,
      diff_type = opts.diff_type,
      upstream_branch = opts.upstream_branch,
    }
  end

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = vim.api.nvim_create_augroup("GitDiffsMultiCursor", { clear = true }),
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

  register_diff_view_close_callback {
    group_name = "GitDiffsMultiWinClosed",
    diff_tabnr = nrs.diff_tabnr,
    winnrs = { nrs.new_winnr, nrs.old_winnr, nrs.file_list_winnr },
    on_close = function()
      iter = iter + 1
      clear_file_list_navigation_keymaps(nrs)
    end,
  }

  vim.keymap.set(
    "n",
    "<Plug>GitDiffsMultiScrollDown",
    cb_async(function()
      scroll_diff_view(nrs.old_winnr, "j")
    end),
    { desc = "Scroll down in the diff view", buffer = nrs.file_list_bufnr }
  )

  vim.keymap.set(
    "n",
    "<Plug>GitDiffsMultiScrollUp",
    cb_async(function()
      scroll_diff_view(nrs.old_winnr, "k")
    end),
    { desc = "Scroll up in the diff view", buffer = nrs.file_list_bufnr }
  )

  emit_multi_buffer_event(nrs, nrs.new_bufnr)
end

--- @class SingleFileDiffViewCloseParams
--- @field worktree_winnr integer
--- @field worktree_bufnr integer
--- @field edit_winnr integer

--- @param close_params SingleFileDiffViewCloseParams
local close_single_file_diff_view = function(close_params)
  if
    not vim.api.nvim_win_is_valid(close_params.worktree_winnr)
    or not vim.api.nvim_buf_is_valid(close_params.worktree_bufnr)
  then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(close_params.worktree_winnr)
  vim.api.nvim_win_set_buf(close_params.worktree_winnr, close_params.worktree_bufnr)

  if
    vim.api.nvim_win_is_valid(close_params.edit_winnr)
    and vim.api.nvim_win_get_buf(close_params.edit_winnr) == close_params.worktree_bufnr
  then
    set_cursor(close_params.edit_winnr, cursor)
  end

  maybe_close_winnr(close_params.worktree_winnr)
end

--- @return SingleFileDiffViewNrs? nrs
--- @return SingleFileDiffViewContext? context
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
  local edit_winnr = vim.api.nvim_get_current_win()
  local edit_tabnr = vim.api.nvim_get_current_tabpage()

  vim.cmd.tabnew()
  local diff_tabnr = vim.api.nvim_get_current_tabpage()

  local worktree_winnr = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(worktree_winnr, worktree_bufnr)
  vim.api.nvim_win_set_var(worktree_winnr, "git_diffs_single_file_view", true)
  vim.api.nvim_win_set_var(worktree_winnr, "git_diffs_single_file_worktree_bufnr", worktree_bufnr)
  vim.api.nvim_win_set_var(worktree_winnr, "git_diffs_single_file_edit_winnr", edit_winnr)
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
    edit_winnr = edit_winnr,
  }

  --- @type SingleFileDiffViewContext
  local context = {
    rel_filename = rel_filename,
    cursor = cursor,
    filetype = filetype,
  }

  return nrs, context
end

--- @param nrs SingleFileDiffViewNrs
--- @param context SingleFileDiffViewContext
--- @param opts OpenSingleFileDiffViewParams
local load_single_file_diff_view = function(nrs, context, opts)
  local _, old_file_location = get_file_locations_from_diff_type(opts.diff_type)
  local old_str = vim.async.await(resolve_file_contents {
    file_location = old_file_location,
    rel_filename = context.rel_filename,
    upstream_branch = opts.upstream_branch,
  }) --[[@as string?]]
  ensure_main_loop()
  if old_str == nil then
    notify(
      vim.log.levels.WARN,
      "could not resolve old snapshot: file=%s location=%s",
      context.rel_filename,
      old_file_location
    )
    maybe_close_winnr(nrs.worktree_winnr)
    return
  end

  local old_lines = split_file_contents(old_str)
  vim.api.nvim_buf_set_lines(nrs.old_bufnr, 0, -1, false, old_lines)
  vim.bo[nrs.old_bufnr].filetype = context.filetype
  set_cursor(nrs.old_winnr, context.cursor)
  set_cursor(nrs.worktree_winnr, context.cursor)
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
    pattern = "GitDiffsSingleOpen",
    data = {
      old_winnr = nrs.old_winnr,
      worktree_winnr = nrs.worktree_winnr,
      old_bufnr = nrs.old_bufnr,
      worktree_bufnr = nrs.worktree_bufnr,
    },
  })

  register_diff_view_close_callback {
    group_name = "GitDiffsSingleWinClosed",
    diff_tabnr = nrs.diff_tabnr,
    winnrs = { nrs.worktree_winnr, nrs.old_winnr },
  }

  vim.keymap.set("n", "<Plug>GitDiffsSingleClose", function()
    close_single_file_diff_view {
      worktree_winnr = nrs.worktree_winnr,
      worktree_bufnr = nrs.worktree_bufnr,
      edit_winnr = nrs.edit_winnr,
    }
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

  if existing.diff_tabnr ~= vim.api.nvim_get_current_tabpage() then
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
  local nrs, context = init_single_file_diff_view_nrs()
  if nrs == nil or context == nil then
    return
  end
  register_single_file_diff_view_callbacks(nrs)
  load_single_file_diff_view(nrs, context, opts)
end)

--- @param opts OpenSingleFileDiffViewParams
M.toggle_single_file_diff_view = function(opts)
  local existing = find_single_file_diff_view()
  if existing == nil then
    M.open_single_file_diff_view(opts)
    return
  end

  if existing.diff_tabnr ~= vim.api.nvim_get_current_tabpage() then
    M.open_single_file_diff_view(opts)
    return
  end

  close_single_file_diff_view {
    worktree_winnr = existing.worktree_winnr,
    worktree_bufnr = existing.worktree_bufnr,
    edit_winnr = existing.edit_winnr,
  }
end

return M
