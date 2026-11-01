local MiniTest = require "mini.test"
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality
local child = MiniTest.new_child_neovim()

--- @param files table<string, string>
local function mock_read_index_files(files)
  child.lua_func(
    --- @param files_arg table<string, string>
    function(files_arg)
      M.read_index_file = function(rel_filename)
        --- @return string?
        return vim.async.run(function()
          return files_arg[rel_filename]
        end)
      end
    end,
    files
  )
end

--- @class MockSystemResult
--- @field code? integer
--- @field stdout? string
--- @field stderr? string
--- @param responses table<string, MockSystemResult>
local function mock_system_responses(responses)
  child.lua_func(
    --- @param responses_arg table<string, MockSystemResult>
    function(responses_arg)
      rawset(_G, "git_system_responses", responses_arg)
    end,
    responses
  )
end

--- @alias TestDiffType "worktree-index" | "worktree-head" | "worktree-upstream" | "worktree-mergebase" | "index-head" | "index-upstream" | "index-mergebase" | "head-upstream" | "head-mergebase"
--- @param diff_type TestDiffType
--- @param upstream_branch? string
--- @return string | false
local function run_diff_command(diff_type, upstream_branch)
  return child.lua_func(
    --- @param diff_type_arg TestDiffType
    --- @param upstream_branch_arg string?
    function(diff_type_arg, upstream_branch_arg)
      local result --- @type string?
      local done = false
      vim.async.run(
        --- @return nil
        function()
          result = vim.async.await(M.run_diff_cmd {
            diff_type = diff_type_arg,
            upstream_branch = upstream_branch_arg,
          }) --[[@as string?]]
          done = true
          return nil
        end
      )
      assert(vim.wait(1000, function()
        return done
      end))
      return result or false
    end,
    diff_type,
    upstream_branch
  )
end

local function get_file_list_lines()
  for _, win in ipairs(child.api.nvim_tabpage_list_wins(0)) do
    local bufnr = child.api.nvim_win_get_buf(win)
    if
      child.api.nvim_buf_get_option(bufnr, "filetype") == "git-diffs-multi-file-diff-view-file-list"
    then
      return child.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end
  end
  return nil
end

local function mock_notify()
  child.lua_func(function()
    rawset(_G, "notifications", {})
    --- @param message string
    --- @param level? vim.log.levels
    local notify_mock = function(message, level)
      table.insert(rawget(_G, "notifications"), { message, level })
      return 0
    end
    --- @diagnostic disable-next-line: duplicate-set-field
    vim.notify = notify_mock --[[@as any]]
  end)
end

local expect_state = MiniTest.new_expectation(
  "state condition met",
  --- @param predicate fun(): boolean
  --- @param timeout? integer
  function(predicate, timeout)
    timeout = timeout or 1000
    return vim.wait(timeout, predicate)
  end,
  --- @param _ fun(): boolean
  --- @param timeout? integer
  function(_, timeout)
    timeout = timeout or 1000
    return string.format("Expected state condition to be met after %d ms", timeout)
  end
)

--- @param rel_path string
--- @param lines string[]
local function set_named_buffer(rel_path, lines)
  child.bo.buftype = ""
  child.bo.readonly = false
  child.bo.modifiable = true
  child.api.nvim_buf_set_name(0, rel_path)
  child.api.nvim_buf_set_lines(0, 0, -1, true, lines)
end

--- @param filename string
local function get_diff_view_windows(filename)
  local new_win, old_win, files_win
  for _, win in ipairs(child.api.nvim_tabpage_list_wins(0)) do
    local bufnr = child.api.nvim_win_get_buf(win)
    local buftype = child.api.nvim_buf_get_option(bufnr, "buftype")
    local filetype = child.api.nvim_buf_get_option(bufnr, "filetype")
    local bufname = child.api.nvim_buf_get_name(bufnr)
    local basename = child.fn.fnamemodify(bufname, ":t")

    if filetype == "git-diffs-multi-file-diff-view-file-list" then
      files_win = win
    elseif buftype == "" and basename == filename then
      new_win = win
    else
      old_win = win
    end
  end
  return new_win, old_win, files_win
end

--- @param win_id integer
local function get_win_lines(win_id)
  local bufnr = child.api.nvim_win_get_buf(win_id)
  return child.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

--- @param filename string
--- @param worktree_lines string[]
--- @param index_content string
local function setup_diff_view_test(filename, worktree_lines, index_content)
  set_named_buffer(filename, worktree_lines)
  mock_read_index_files { [filename] = index_content }
  mock_system_responses { ["git diff --name-only"] = { stdout = filename .. "\n" } }
end

local function open_two_file_diff_view()
  set_named_buffer("a.txt", { "new a" })
  child.cmd "badd b.txt"
  local b_bufnr = child.fn.bufnr "b.txt"
  child.api.nvim_buf_set_lines(b_bufnr, 0, -1, true, { "new b" })
  mock_read_index_files {
    ["a.txt"] = "old a\n",
    ["b.txt"] = "old b\n",
  }
  mock_system_responses { ["git diff --name-only"] = { stdout = "a.txt\nb.txt\n" } }
  child.lua [[M.open_multi_file_diff_view { diff_type = "worktree-index" }]]
  expect_state(function()
    local lines = get_file_list_lines()
    local new_win = get_diff_view_windows "a.txt"
    return lines ~= nil and lines[2] == "b.txt" and new_win ~= nil
  end)
  return get_diff_view_windows "a.txt"
end

--- @param filename string
--- @param worktree_lines string[]
--- @param snapshot_response MockSystemResult
local function setup_single_file_diff_test(filename, worktree_lines, snapshot_response)
  set_named_buffer(filename, worktree_lines)
  mock_system_responses { ["git show :" .. filename] = snapshot_response }
end

local function open_single_file_diff_view()
  child.lua [[M.open_single_file_diff_view { diff_type = "worktree-index" }]]
  expect_state(function()
    return #child.api.nvim_list_tabpages() == 2
      and #child.api.nvim_tabpage_list_wins(0) == 2
      and child.lua_func(function()
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.wo[win].winbar == "index" then
            return true
          end
        end
        return false
      end)
  end)
end

local function setup_diff_view_scroll_test()
  local index_lines = {}
  local worktree_lines = {}
  for index = 1, 30 do
    index_lines[index] = "line " .. index
    worktree_lines[index] = index_lines[index]
  end
  worktree_lines[1] = "changed line"

  set_named_buffer("scroll-test.txt", worktree_lines)
  mock_read_index_files { ["scroll-test.txt"] = table.concat(index_lines, "\n") .. "\n" }
  mock_system_responses { ["git diff --name-only"] = { stdout = "scroll-test.txt\n" } }

  child.lua_func(function()
    M.open_multi_file_diff_view { diff_type = "worktree-index" }
  end)
  expect_state(function()
    return #child.api.nvim_list_tabpages() == 2 and #child.api.nvim_tabpage_list_wins(0) == 3
  end)

  local _, old_win, files_win = get_diff_view_windows "scroll-test.txt"
  child.wo[old_win].scroll = 1
  child.api.nvim_set_current_win(files_win)
  child.lua_func(function()
    local sleep = vim.async.sleep
    _G.smooth_scroll_sleep_calls = {}
    --- @param ms number
    vim.async.sleep = function(ms)
      if ms == 10 then
        table.insert(_G.smooth_scroll_sleep_calls, ms)
      end
      return sleep(ms)
    end
  end)
end

local T = new_set {
  hooks = {
    pre_case = function()
      child.restart { "-u", "scripts/minimal_init.lua" }
      child.lua_func(function()
        rawset(_G, "git_system_responses", {})
        --- @type fun(command: string[], opts: vim.SystemOpts?, on_exit: fun(result: vim.SystemCompleted)): nil
        local system_mock = function(command, _, on_exit)
          local command_string = table.concat(command, " ")
          local responses = rawget(_G, "git_system_responses")
          local response = responses[command_string]
          local result = {
            cmd = command,
            code = response and response.code or 0,
            signal = 0,
            stdout = response and response.stdout or "",
            stderr = response and response.stderr or "",
          }
          vim.schedule(function()
            on_exit(result)
          end)
          return nil
        end
        vim.system = system_mock --[[@as any]]
        M = require "git-diffs"
      end)
    end,
    post_once = child.stop,
  },
}

T["diff view"] = new_set()

T["diff view"]["smooth scroll defaults to enabled"] = function()
  setup_diff_view_scroll_test()

  child.type_keys "<Plug>GitDiffsMultiFileDiffViewScrollDown"
  eq(
    child.lua_func(function()
      return #_G.smooth_scroll_sleep_calls
    end),
    1
  )
end

T["diff view"]["smooth scroll can be disabled"] = function()
  child.g.git_diffs = { smooth_scroll = false }
  setup_diff_view_scroll_test()

  child.type_keys "<Plug>GitDiffsMultiFileDiffViewScrollUp"
  eq(
    child.lua_func(function()
      return #_G.smooth_scroll_sleep_calls
    end),
    0
  )
end

T["diff view"]["opens a diff view tab"] = function()
  setup_diff_view_test(
    "test.txt",
    { "line1 changed", "line2", "line3" },
    [[line1
line2
line3
]]
  )

  child.lua_func(function()
    M.open_multi_file_diff_view { diff_type = "worktree-index" }
  end)

  expect_state(function()
    return #child.api.nvim_list_tabpages() == 2 and #child.api.nvim_tabpage_list_wins(0) == 3
  end)

  eq(#child.api.nvim_list_tabpages(), 2)
  eq(#child.api.nvim_tabpage_list_wins(0), 3)

  local new_win, old_win, files_win = get_diff_view_windows "test.txt"

  eq(get_win_lines(new_win), { "line1 changed", "line2", "line3" })
  eq(get_win_lines(old_win), { "line1", "line2", "line3" })
  eq(get_win_lines(files_win), { "test.txt" })
end

T["diff view"]["preserves empty and trailing snapshot lines"] = new_set {
  parametrize = {
    { "empty.txt", "", { "changed" }, { "" } },
    { "one-blank-line.txt", "line\n\n", { "changed" }, { "line", "" } },
    { "two-blank-lines.txt", "line\n\n\n", { "changed" }, { "line", "", "" } },
  },
}

--- @param filename string
--- @param index_content string
--- @param worktree_lines string[]
--- @param expected_old_lines string[]
T["diff view"]["preserves empty and trailing snapshot lines"]["keeps line boundaries"] = function(
  filename,
  index_content,
  worktree_lines,
  expected_old_lines
)
  setup_diff_view_test(filename, worktree_lines, index_content)
  child.lua [[M.open_multi_file_diff_view { diff_type = "worktree-index" }]]
  expect_state(function()
    return #child.api.nvim_list_tabpages() == 2 and #child.api.nvim_tabpage_list_wins(0) == 3
  end)
  local _, old_win = get_diff_view_windows(filename)
  eq(get_win_lines(old_win), expected_old_lines)
end

T["diff view"]["moves the file list from either diff window"] = function()
  local new_win, old_win, files_win = open_two_file_diff_view()
  child.api.nvim_set_current_win(old_win)
  child.type_keys "<Plug>GitDiffsMultiFileDiffViewFileListDown"
  eq(child.api.nvim_win_get_cursor(files_win)[1], 2)
  expect_state(function()
    return child.api.nvim_win_get_buf(new_win) == child.fn.bufnr "b.txt"
  end)

  child.api.nvim_set_current_win(new_win)
  child.type_keys "<Plug>GitDiffsMultiFileDiffViewFileListUp"
  eq(child.api.nvim_win_get_cursor(files_win)[1], 1)
end

T["diff view"]["wraps down from the last file to the first"] = function()
  local new_win, _, files_win = open_two_file_diff_view()
  child.api.nvim_set_current_win(files_win)
  child.api.nvim_win_set_cursor(files_win, { 2, 0 })
  child.api.nvim_set_current_win(new_win)
  child.type_keys "<Plug>GitDiffsMultiFileDiffViewFileListDown"
  eq(child.api.nvim_win_get_cursor(files_win)[1], 1)
end

T["diff view"]["wraps up from the first file to the last"] = function()
  local _, old_win, files_win = open_two_file_diff_view()
  child.api.nvim_set_current_win(files_win)
  child.api.nvim_win_set_cursor(files_win, { 1, 0 })
  child.api.nvim_set_current_win(old_win)
  child.type_keys "<Plug>GitDiffsMultiFileDiffViewFileListUp"
  eq(child.api.nvim_win_get_cursor(files_win)[1], 2)
end

T["diff view"]["shows an empty file list when there are no changed files"] = function()
  mock_system_responses { ["git diff --name-only"] = { stdout = "" } }
  child.lua [[M.open_multi_file_diff_view { diff_type = "worktree-index" }]]
  expect_state(function()
    return #child.api.nvim_list_tabpages() == 2 and #child.api.nvim_tabpage_list_wins(0) == 3
  end)
  eq(get_file_list_lines(), { "" })
end

T["diff view"]["loads a single diff from the current buffer path"] = function()
  setup_single_file_diff_test("single.txt", { "worktree" }, { stdout = "index snapshot\n" })
  open_single_file_diff_view()
  expect_state(function()
    return child.lua_func(function()
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.wo[win].winbar == "index" then
          return vim.deep_equal(
            vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false),
            {
              "index snapshot",
            }
          )
        end
      end
      return false
    end)
  end)
end

T["diff view"]["cleans up after an unavailable single-file snapshot and allows retry"] = function()
  setup_single_file_diff_test(
    "single-missing.txt",
    { "worktree" },
    { code = 128, stderr = "missing path" }
  )
  local worktree_bufnr = child.api.nvim_get_current_buf()
  mock_notify()

  child.lua [[M.open_single_file_diff_view { diff_type = "worktree-index" }]]
  expect_state(function()
    return child.lua_func(function()
      return #notifications == 1
    end)
  end)
  eq(#child.api.nvim_list_tabpages(), 1)
  eq(#child.api.nvim_tabpage_list_wins(0), 1)
  eq(child.api.nvim_get_current_buf(), worktree_bufnr)
  eq(
    child.lua_func(function()
      return notifications[1]
    end),
    {
      "[git-diffs.nvim]: could not resolve old snapshot: file=single-missing.txt location=index",
      vim.log.levels.WARN,
    }
  )

  mock_system_responses {
    ["git show :single-missing.txt"] = { stdout = "old snapshot\n" },
  }
  open_single_file_diff_view()
  eq(#child.api.nvim_list_tabpages(), 2)
end

T["diff view"]["closes the single-file view and restores the worktree cursor"] = function()
  setup_single_file_diff_test("single.txt", { "one", "two", "three" }, { stdout = "old version\n" })
  child.api.nvim_win_set_cursor(0, { 2, 1 })
  local worktree_bufnr = child.api.nvim_get_current_buf()
  local edit_tab = child.api.nvim_get_current_tabpage()

  open_single_file_diff_view()
  child.type_keys "<Plug>GitDiffsSingleFileDiffViewClose"
  expect_state(function()
    return #child.api.nvim_list_tabpages() == 1
  end)

  eq(child.api.nvim_get_current_tabpage(), edit_tab)
  eq(child.api.nvim_get_current_buf(), worktree_bufnr)
  eq(child.api.nvim_win_get_cursor(0), { 2, 1 })
end

T["diff view"]["does not replace another buffer when toggling closed"] = function()
  setup_single_file_diff_test(
    "single-toggle-other.txt",
    { "worktree", "second line" },
    { stdout = "old version\n" }
  )
  open_single_file_diff_view()

  local edit_tab = child.api.nvim_list_tabpages()[1]
  child.api.nvim_set_current_tabpage(edit_tab)
  child.cmd "enew"
  set_named_buffer("unrelated.txt", { "keep this buffer" })
  local edit_win = child.api.nvim_get_current_win()
  local unrelated_bufnr = child.api.nvim_get_current_buf()
  local unrelated_lines = child.api.nvim_buf_get_lines(unrelated_bufnr, 0, -1, false)

  child.lua [[M.toggle_single_file_diff_view { diff_type = "worktree-index" }]]
  expect_state(function()
    return #child.api.nvim_list_tabpages() == 1
  end)

  eq(child.api.nvim_win_is_valid(edit_win), true)
  eq(child.api.nvim_win_get_buf(edit_win), unrelated_bufnr)
  eq(child.api.nvim_buf_get_lines(unrelated_bufnr, 0, -1, false), unrelated_lines)
end

T["diff view"]["toggles the single-file view and closes both diff windows"] = function()
  set_named_buffer("single-toggle.txt", { "one", "two" })
  mock_system_responses {
    ["git show :single-toggle.txt"] = { stdout = "old version\n" },
  }
  local worktree_bufnr = child.api.nvim_get_current_buf()
  child.lua_func(function()
    vim.api.nvim_create_autocmd("User", {
      pattern = "GitDiffsSingleFileDiffViewOpen",
      callback = function(event)
        _G.single_file_diff_windows = event.data
      end,
    })
  end)

  child.lua("M.toggle_single_file_diff_view(...)", { { diff_type = "worktree-index" } })
  expect_state(function()
    return #child.api.nvim_list_tabpages() == 2 and #child.api.nvim_tabpage_list_wins(0) == 2
  end)
  local diff_windows = child.lua_get "single_file_diff_windows"
  eq(diff_windows.worktree_winnr ~= nil, true)
  eq(diff_windows.old_winnr ~= nil, true)
  child.lua("M.toggle_single_file_diff_view(...)", { { diff_type = "worktree-index" } })
  expect_state(function()
    return #child.api.nvim_list_tabpages() == 1
  end)
  eq(child.api.nvim_win_is_valid(diff_windows.worktree_winnr), false)
  eq(child.api.nvim_win_is_valid(diff_windows.old_winnr), false)
  eq(child.api.nvim_get_current_buf(), worktree_bufnr)
end

T["diff view"]["notifies when scroll keymaps no longer have a diff window"] = function()
  set_named_buffer("a.txt", { "a" })
  mock_read_index_files { ["a.txt"] = "old a\n" }
  mock_system_responses { ["git diff --name-only"] = { stdout = "a.txt\n" } }
  child.lua [[M.open_multi_file_diff_view { diff_type = "worktree-index" }]]
  expect_state(function()
    return #child.api.nvim_tabpage_list_wins(0) == 3
  end)
  local _, _, files_win = get_diff_view_windows "a.txt"
  local files_bufnr = child.api.nvim_win_get_buf(files_win)
  child.api.nvim_win_close(files_win, false)
  expect_state(function()
    return #child.api.nvim_list_tabpages() == 1
  end)

  mock_notify()
  child.cmd "new"
  child.api.nvim_win_set_buf(0, files_bufnr)
  child.type_keys "<Plug>GitDiffsMultiFileDiffViewScrollDown"
  expect_state(function()
    return child.lua_func(function()
      return #rawget(_G, "notifications") == 1
    end)
  end)
  child.type_keys "<Plug>GitDiffsMultiFileDiffViewScrollUp"
  expect_state(function()
    return child.lua_func(function()
      return #rawget(_G, "notifications") == 2
    end)
  end)
  eq(
    child.lua_func(function()
      return rawget(_G, "notifications")
    end),
    {
      { "[git-diffs.nvim]: Diff view window is no longer available", vim.log.levels.WARN },
      { "[git-diffs.nvim]: Diff view window is no longer available", vim.log.levels.WARN },
    }
  )
end

T["diff view"]["switches to the selected file buffer in the original tab"] = function()
  set_named_buffer("a.txt", { "a" })
  child.cmd "badd b.txt"
  local b_bufnr = child.fn.bufnr "b.txt"
  child.api.nvim_buf_set_lines(b_bufnr, 0, -1, true, { "b1", "b2" })
  mock_read_index_files {
    ["a.txt"] = "old a\n",
    ["b.txt"] = "old b\n",
  }
  mock_system_responses { ["git diff --name-only"] = { stdout = "a.txt\nb.txt\n" } }
  local edit_tab = child.api.nvim_get_current_tabpage()

  child.lua [[M.open_multi_file_diff_view { diff_type = "worktree-index" }]]
  expect_state(function()
    local lines = get_file_list_lines()
    return #child.api.nvim_tabpage_list_wins(0) == 3 and lines ~= nil and lines[1] == "a.txt"
  end)
  child.type_keys "j"
  expect_state(function()
    return child.api.nvim_get_current_line() == "b.txt"
  end)
  child.type_keys "<Plug>GitDiffsMultiFileDiffViewSwitchToBuffer"

  eq(child.api.nvim_get_current_tabpage(), edit_tab)
  eq(child.api.nvim_get_current_buf(), b_bufnr)
  eq(child.api.nvim_buf_get_lines(b_bufnr, 0, -1, false), { "b1", "b2" })
end

T["diff view"]["does nothing when switching from an empty file list"] = function()
  mock_system_responses { ["git diff --name-only"] = { stdout = "" } }
  child.lua [[M.open_multi_file_diff_view { diff_type = "worktree-index" }]]
  expect_state(function()
    return #child.api.nvim_tabpage_list_wins(0) == 3
  end)
  local diff_tab = child.api.nvim_get_current_tabpage()
  mock_notify()

  child.type_keys "<Plug>GitDiffsMultiFileDiffViewSwitchToBuffer"

  eq(child.api.nvim_get_current_tabpage(), diff_tab)
  eq(#child.api.nvim_list_tabpages(), 2)
  eq(
    child.lua_func(function()
      return rawget(_G, "notifications")
    end),
    { { "[git-diffs.nvim]: No file is selected", vim.log.levels.WARN } }
  )
end

T["diff view"]["quits when closing the last diff tab after the original tab closes"] = function()
  set_named_buffer("a.txt", { "a" })
  mock_read_index_files { ["a.txt"] = "old a\n" }
  mock_system_responses { ["git diff --name-only"] = { stdout = "a.txt\n" } }
  local edit_tab = child.api.nvim_get_current_tabpage()

  child.lua [[M.open_multi_file_diff_view { diff_type = "worktree-index" }]]
  expect_state(function()
    return #child.api.nvim_tabpage_list_wins(0) == 3
  end)
  local diff_tab = child.api.nvim_get_current_tabpage()
  child.api.nvim_set_current_tabpage(edit_tab)
  child.cmd "tabclose"
  child.api.nvim_set_current_tabpage(diff_tab)
  child.lua_func(function()
    rawset(_G, "quitall_called", false)
    rawset(vim.cmd, "quitall", function()
      rawset(_G, "quitall_called", true)
    end)
  end)

  local _, _, files_win = get_diff_view_windows "a.txt"
  child.api.nvim_win_close(files_win, false)
  expect_state(function()
    return child.lua_func(function()
      return rawget(_G, "quitall_called")
    end)
  end)
  eq(#child.api.nvim_list_tabpages(), 1)
end

T["diff view"]["does nothing when the original tab has been closed"] = function()
  set_named_buffer("a.txt", { "a" })
  mock_read_index_files { ["a.txt"] = "old a\n" }
  mock_system_responses { ["git diff --name-only"] = { stdout = "a.txt\n" } }
  local edit_tab = child.api.nvim_get_current_tabpage()

  child.lua [[M.open_multi_file_diff_view { diff_type = "worktree-index" }]]
  expect_state(function()
    return #child.api.nvim_tabpage_list_wins(0) == 3
  end)
  local diff_tab = child.api.nvim_get_current_tabpage()
  child.api.nvim_set_current_tabpage(edit_tab)
  child.cmd "tabclose"
  child.api.nvim_set_current_tabpage(diff_tab)
  mock_notify()

  child.type_keys "<Plug>GitDiffsMultiFileDiffViewSwitchToBuffer"

  eq(child.api.nvim_get_current_tabpage(), diff_tab)
  eq(#child.api.nvim_list_tabpages(), 1)
  eq(
    child.lua_func(function()
      return rawget(_G, "notifications")
    end),
    { { "[git-diffs.nvim]: Original editing tab is no longer available", vim.log.levels.WARN } }
  )
end

--- @class DiffViewEventData
--- @field new_bufnr integer
--- @field old_bufnr integer
T["diff view"]["preserves HEAD and upstream or merge-base snapshot lines"] = new_set {
  parametrize = {
    { "head-upstream" },
    { "head-mergebase" },
  },
}

--- @param diff_type TestDiffType
T["diff view"]["preserves HEAD and upstream or merge-base snapshot lines"]["keeps trailing blank lines"] = function(
  diff_type
)
  mock_system_responses {
    ["git diff --name-only HEAD origin/master"] = { stdout = "snapshot.txt\n" },
    ["git diff --name-only origin/master...HEAD"] = { stdout = "snapshot.txt\n" },
    ["git merge-base HEAD origin/master"] = { stdout = "base-sha\n" },
    ["git show HEAD:snapshot.txt"] = { stdout = "line\n\n\n" },
    ["git show origin/master:snapshot.txt"] = { stdout = "line\n\n" },
    ["git show base-sha:snapshot.txt"] = { stdout = "line\n\n" },
  }
  child.lua_func(function()
    vim.api.nvim_create_autocmd("User", {
      pattern = "GitDiffsMultiFileDiffViewOpen",
      once = true,
      callback = function(event)
        rawset(_G, "diff_view_data", event.data)
      end,
    })
  end)

  child.lua("M.open_multi_file_diff_view(...)", { { diff_type = diff_type } })
  expect_state(function()
    return #child.api.nvim_list_tabpages() == 2
      and #child.api.nvim_tabpage_list_wins(0) == 3
      and child.lua_func(function()
        return rawget(_G, "diff_view_data") ~= nil
      end)
  end)
  expect_state(function()
    return child.lua_func(function()
      local data = rawget(_G, "diff_view_data") --[[@as DiffViewEventData?]]
      if data == nil then
        return false
      end
      return vim.deep_equal(vim.api.nvim_buf_get_lines(data.new_bufnr, 0, -1, false), {
        "line",
        "",
        "",
      }) and vim.deep_equal(vim.api.nvim_buf_get_lines(data.old_bufnr, 0, -1, false), {
        "line",
        "",
      })
    end)
  end)
  eq(
    child.lua_func(function()
      local data = rawget(_G, "diff_view_data") --[[@as DiffViewEventData?]]
      assert(data ~= nil)
      return {
        new = vim.api.nvim_buf_get_lines(data.new_bufnr, 0, -1, false),
        old = vim.api.nvim_buf_get_lines(data.old_bufnr, 0, -1, false),
      }
    end),
    {
      new = { "line", "", "" },
      old = { "line", "" },
    }
  )
end

T["git diff commands"] = new_set()

T["git diff commands"]["compare every supported location pair and upstream branch"] = function()
  mock_system_responses {
    ["git diff --name-only"] = { stdout = "worktree-index.txt\n" },
    ["git diff --name-only HEAD"] = { stdout = "worktree-head.txt\n" },
    ["git diff --name-only origin/master"] = { stdout = "worktree-upstream.txt\n" },
    ["git merge-base HEAD origin/master"] = { stdout = "base-sha\n" },
    ["git diff --name-only base-sha"] = { stdout = "worktree-mergebase.txt\n" },
    ["git diff --name-only --cached"] = { stdout = "index-head.txt\n" },
    ["git diff --name-only --cached origin/master"] = { stdout = "index-upstream.txt\n" },
    ["git diff --name-only --cached base-sha"] = { stdout = "index-mergebase.txt\n" },
    ["git diff --name-only HEAD origin/master"] = { stdout = "head-upstream.txt\n" },
    ["git diff --name-only origin/master...HEAD"] = { stdout = "head-mergebase.txt\n" },
    ["git diff --name-only origin/release"] = { stdout = "custom-upstream.txt\n" },
  }

  --- @type table<TestDiffType, string>
  local expected = {
    ["worktree-index"] = "worktree-index.txt\n",
    ["worktree-head"] = "worktree-head.txt\n",
    ["worktree-upstream"] = "worktree-upstream.txt\n",
    ["worktree-mergebase"] = "worktree-mergebase.txt\n",
    ["index-head"] = "index-head.txt\n",
    ["index-upstream"] = "index-upstream.txt\n",
    ["index-mergebase"] = "index-mergebase.txt\n",
    ["head-upstream"] = "head-upstream.txt\n",
    ["head-mergebase"] = "head-mergebase.txt\n",
  }
  for diff_type, file_list in pairs(expected) do
    eq(run_diff_command(diff_type), file_list)
  end
  eq(run_diff_command("worktree-upstream", "release"), "custom-upstream.txt\n")
end

T["git diff commands"]["return nil for unavailable refs and files"] = function()
  mock_system_responses {
    ["git diff --name-only origin/missing"] = { code = 128, stderr = "unknown ref" },
    ["git merge-base HEAD origin/missing"] = { code = 1, stderr = "no merge base" },
    ["git show :missing.txt"] = { code = 128, stderr = "missing path" },
  }

  eq(run_diff_command("worktree-upstream", "missing"), false)
  eq(run_diff_command("worktree-mergebase", "missing"), false)
  eq(
    child.lua_func(function()
      --- @type string?
      local result
      local done = false
      vim.async.run(
        --- @return nil
        function()
          result = vim.async.await(M.read_index_file "missing.txt") --[[@as string?]]
          done = true
          return nil
        end
      )
      assert(vim.wait(1000, function()
        return done
      end))
      return result == nil
    end),
    true
  )
end

T["diff view"]["refreshes the file list"] = function()
  set_named_buffer("a.txt", { "a" })
  mock_read_index_files { ["a.txt"] = "old\n" }
  mock_system_responses { ["git diff --name-only"] = { stdout = "a.txt\n" } }
  child.lua [[M.open_multi_file_diff_view { diff_type = "worktree-index" }]]
  expect_state(function()
    local lines = get_file_list_lines()
    return #child.api.nvim_list_tabpages() == 2 and lines ~= nil and lines[1] == "a.txt"
  end)

  mock_system_responses { ["git diff --name-only"] = { stdout = "a.txt\nb.txt\n" } }
  child.type_keys "<Plug>GitDiffsMultiFileDiffViewRefresh"
  expect_state(function()
    return vim.deep_equal(get_file_list_lines(), { "a.txt", "b.txt" })
  end)
  eq(get_file_list_lines(), { "a.txt", "b.txt" })
end

T["diff view"]["ignores pending snapshots after closing and reopening"] = function()
  set_named_buffer("async.txt", { "worktree" })
  mock_system_responses { ["git diff --name-only"] = { stdout = "async.txt\n" } }
  child.lua_func(function()
    rawset(_G, "mock_snapshot_state", {
      waiting = 0,
      completed = 0,
      release = false,
      snapshot = "stale\n",
    })
    M.read_index_file = function()
      local state = rawget(_G, "mock_snapshot_state")
      state.waiting = state.waiting + 1
      local contents = state.snapshot
      return vim.async.run(function()
        while not state.release do
          vim.async.sleep(1)
        end
        state.completed = state.completed + 1
        return contents
      end)
    end
  end)

  child.lua [[M.open_multi_file_diff_view { diff_type = "worktree-index" }]]
  expect_state(function()
    return #child.api.nvim_list_tabpages() == 2 and #child.api.nvim_tabpage_list_wins(0) == 3
  end)
  expect_state(function()
    return child.lua_func(function()
      return rawget(_G, "mock_snapshot_state").waiting > 0
    end)
  end)

  local _, _, files_win = get_diff_view_windows "async.txt"
  child.api.nvim_win_close(files_win, false)
  expect_state(function()
    return #child.api.nvim_list_tabpages() == 1
  end)
  child.lua_func(function()
    rawget(_G, "mock_snapshot_state").snapshot = "fresh\n"
  end)

  child.lua [[M.open_multi_file_diff_view { diff_type = "worktree-index" }]]
  expect_state(function()
    return child.lua_func(function()
      local state = rawget(_G, "mock_snapshot_state")
      return state.waiting > 1
    end)
  end)
  child.lua_func(function()
    rawget(_G, "mock_snapshot_state").release = true
  end)
  expect_state(function()
    return child.lua_func(function()
      local state = rawget(_G, "mock_snapshot_state")
      return state.completed == state.waiting
    end)
  end)
  local _, old_win = get_diff_view_windows "async.txt"
  eq(get_win_lines(old_win), { "fresh" })
end

T["diff view"]["updates old/new content on file selection"] = function()
  set_named_buffer("a.txt", { "a1 changed", "a2" })
  child.cmd "badd b.txt"
  local b_bufnr = child.fn.bufnr "b.txt"
  child.api.nvim_buf_set_lines(b_bufnr, 0, -1, true, { "b1 changed", "b2" })

  mock_read_index_files {
    ["a.txt"] = "a1\na2\n",
    ["b.txt"] = "b1\nb2\n",
  }
  mock_system_responses { ["git diff --name-only"] = { stdout = "a.txt\nb.txt\n" } }

  child.lua_func(function()
    M.open_multi_file_diff_view { diff_type = "worktree-index" }
  end)

  expect_state(function()
    return #child.api.nvim_list_tabpages() == 2 and #child.api.nvim_tabpage_list_wins(0) == 3
  end)

  child.type_keys "j"

  expect_state(function()
    local new_win = get_diff_view_windows "b.txt"
    return new_win ~= nil
  end)

  local new_win, old_win = get_diff_view_windows "b.txt"
  eq(get_win_lines(new_win), { "b1 changed", "b2" })
  eq(get_win_lines(old_win), { "b1", "b2" })
end

T["diff view"]["toggles the diff view"] = function()
  setup_diff_view_test(
    "test.txt",
    { "line1 changed", "line2", "line3" },
    [[line1
line2
line3
]]
  )

  child.lua_func(function()
    M.toggle_multi_file_diff_view { diff_type = "worktree-index" }
  end)
  expect_state(function()
    return #child.api.nvim_list_tabpages() == 2
  end)
  eq(#child.api.nvim_list_tabpages(), 2)

  child.lua_func(function()
    M.toggle_multi_file_diff_view { diff_type = "worktree-index" }
  end)
  expect_state(function()
    return #child.api.nvim_list_tabpages() == 1
  end)
  eq(#child.api.nvim_list_tabpages(), 1)
end

T["diff view"]["closes cleanly"] = new_set {
  parametrize = {
    { "new" },
    { "old" },
    { "files" },
  },
}

--- @param win_name "new" | "old" | "files"
T["diff view"]["closes cleanly"]["closes when window closes"] = function(win_name)
  setup_diff_view_test(
    "test.txt",
    { "line1 changed", "line2", "line3" },
    [[line1
line2
line3
]]
  )

  child.lua_func(function()
    M.open_multi_file_diff_view { diff_type = "worktree-index" }
  end)
  expect_state(function()
    return #child.api.nvim_list_tabpages() == 2 and #child.api.nvim_tabpage_list_wins(0) == 3
  end)

  local new_win, old_win, files_win = get_diff_view_windows "test.txt"
  local win_to_close = ({ new = new_win, old = old_win, files = files_win })[win_name]
  child.api.nvim_win_close(win_to_close, false)
  expect_state(function()
    return #child.api.nvim_list_tabpages() == 1
  end)
  eq(#child.api.nvim_list_tabpages(), 1)

  child.lua_func(function()
    M.open_multi_file_diff_view { diff_type = "worktree-index" }
  end)
  expect_state(function()
    return #child.api.nvim_list_tabpages() == 2
  end)
  eq(#child.api.nvim_list_tabpages(), 2)
end

return T
