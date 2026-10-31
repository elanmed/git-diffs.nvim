local MiniTest = require "mini.test"
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

--- @param files table<string, string>
local function mock_read_index_files(files)
  child.lua_func(
    --- @param files_arg table<string, string>
    function(files_arg)
      ---@diagnostic disable-next-line: duplicate-set-field
      M.read_index_file = function(rel_filename)
        return vim.async.run(
          --- @return string?
          function()
            return files_arg[rel_filename]
          end
        )
      end
    end,
    files
  )
end

--- @param fn_name string
--- @param content string
local function mock_run_diff_cmd(fn_name, content)
  child.lua_func(
    --- @param fn_name_arg string
    --- @param content_arg string
    function(fn_name_arg, content_arg)
      M[fn_name_arg] = function()
        return vim.async.run(
          --- @return string?
          function()
            return content_arg
          end
        )
      end
    end,
    fn_name,
    content
  )
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

    if filetype == "git-diffs-view-file-list" then
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
  mock_run_diff_cmd("run_diff_cmd_worktree_index", filename .. "\n")
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
  mock_run_diff_cmd("run_diff_cmd_worktree_index", "scroll-test.txt\n")

  child.lua_func(function()
    M.open_diff_view { diff_type = "worktree-index" }
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
        M = require "git-diffs"
      end)
    end,
    post_once = child.stop,
  },
}

T["diff view"] = new_set()

T["diff view"]["smooth scroll defaults to enabled"] = function()
  setup_diff_view_scroll_test()

  child.type_keys "<Plug>GitDiffViewScrollDown"
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

  child.type_keys "<Plug>GitDiffViewScrollUp"
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
    M.open_diff_view { diff_type = "worktree-index" }
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

T["diff view"]["updates old/new content on file selection"] = function()
  set_named_buffer("a.txt", { "a1 changed", "a2" })
  child.cmd "badd b.txt"
  local b_bufnr = child.fn.bufnr "b.txt"
  child.api.nvim_buf_set_lines(b_bufnr, 0, -1, true, { "b1 changed", "b2" })

  mock_read_index_files {
    ["a.txt"] = "a1\na2\n",
    ["b.txt"] = "b1\nb2\n",
  }
  mock_run_diff_cmd("run_diff_cmd_worktree_index", "a.txt\nb.txt\n")

  child.lua_func(function()
    M.open_diff_view { diff_type = "worktree-index" }
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
    M.toggle_diff_view { diff_type = "worktree-index" }
  end)
  expect_state(function()
    return #child.api.nvim_list_tabpages() == 2
  end)
  eq(#child.api.nvim_list_tabpages(), 2)

  child.lua_func(function()
    M.toggle_diff_view { diff_type = "worktree-index" }
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
    M.open_diff_view { diff_type = "worktree-index" }
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
    M.open_diff_view { diff_type = "worktree-index" }
  end)
  expect_state(function()
    return #child.api.nvim_list_tabpages() == 2
  end)
  eq(#child.api.nvim_list_tabpages(), 2)
end

return T
