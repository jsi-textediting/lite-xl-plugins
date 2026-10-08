local core     = require "core"
local common   = require "core.common"
local config   = require "core.config"
local style    = require "core.style"
local ListView = require "plugins.shared.listview"
local H        = require "plugins.shared.search_helpers"

config.plugins.fd_files = common.merge({
  executable     = "fd",
  extra_flags    = { "--type", "f", "--follow" },
  max_results    = 500,
  live_filter    = true,  -- re-run fd with the filter text once typing pauses
  live_min_chars = 1,     -- shorter filter text only filters the loaded results
}, config.plugins.fd_files)

local function is_remote(path)
  local ok, remote = pcall(require, "plugins.thither")
  return ok and remote.is_remote(path)
end

-- Filter text as a list of the characters it fuzzy-matches (spaces are
-- ignored by common.fuzzy_match).
local function filter_chars(text)
  local chars = {}
  for c in text:gsub(" ", ""):gmatch(utf8 and utf8.charpattern or ".") do
    chars[#chars + 1] = c
  end
  return chars
end

-- Escapes for a Rust regex: ASCII punctuation as \x{HH} (some of it may not
-- be backslash-escaped), path separators match either separator.
local function regex_escape(s)
  return (s:gsub("[^%w\128-\255]", function(c)
    if c == "/" or c == "\\" then return "[\\\\/]" end
    return string.format("\\x{%02X}", c:byte())
  end))
end

local function glob_escape(s)
  return (s:gsub("[%*%?%[%]\\]", "\\%0"))
end

local function is_absolute(path)
  return path:match("^/") or path:match("^%a:[\\/]") or path:match("^\\\\")
end

-- fd regex matching the filter characters in order below `root`, so that
-- characters of the root path itself do not match every file. The root is
-- left out for remote roots, whose paths the server sees differently.
local function fd_pattern(root, text)
  local parts = {}
  for _, c in ipairs(filter_chars(text)) do parts[#parts + 1] = regex_escape(c) end
  local pattern = table.concat(parts, ".*")
  if root and is_absolute(root) and not is_remote(root) then
    local prefix = regex_escape((root:gsub("[\\/]+$", "")))
    return "^" .. prefix .. "[\\\\/].*" .. pattern
  end
  return pattern
end

local function parse_line(line)
  if line ~= "" then return { path = line } end
end

local FdView = ListView:extend()

function FdView:__tostring() return "FdView" end

function FdView:new(root)
  FdView.super.new(self)
  self.is_file_list = true
  self.root         = root
  self:begin_search()
end

function FdView:get_name()
  return "fd: " .. (self.root or ".")
end

-- ---------------------------------------------------------------------------
-- Abstract method implementations
-- ---------------------------------------------------------------------------

-- Either separator in the filter matches either separator in the path, as
-- in the fd pattern.
function FdView:get_item_text(item)
  return (item.path:gsub("\\", "/"))
end

function FdView:get_filter_needle(text)
  return (text:gsub("\\", "/"))
end

function FdView:get_status_text()
  local ft = self.filter_doc:get_text(1, 1, 1, math.huge)
  local where = self.root
  if self.live_text ~= "" then
    where = string.format("%s matching %q", self.root, self.live_text)
  end
  if self.searching then
    return string.format("Searching (%d files) in %s...", #self.results, where)
  elseif self.search_error then
    return self.search_error
  elseif ft ~= "" then
    return string.format("%d / %d files in %s", #self.filtered_results, #self.results, where)
  else
    return string.format("%d files in %s", #self.results, where)
  end
end

function FdView:draw_item(i, item, x, y, w, h)
  local col = (i == self.selected_idx) and style.accent or style.text
  x = x + style.padding.x
  local project = core.root_project()
  local rel = (project and project.path ~= "")
    and project:normalize_path(item.path)
    or common.basename(item.path)
  x = common.draw_text(style.font, col, rel, "left", x, y, w, h)
  self.max_h_scroll = math.max(self.max_h_scroll, x)
end

function FdView:open_selected()
  local item = self.filtered_results[self.selected_idx]
  if not item then return end
  core.try(function()
    local dv = core.root_view:open_doc(core.open_doc(item.path))
    core.root_view.root_node:update_layout()
    dv:scroll_to_line(1, false, true)
  end)
  return true
end

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------

-- New unfiltered search: clears the filter text.
function FdView:begin_search()
  self.filter_doc:remove(1, 1, math.huge, math.huge)
  self.filter_change_id = self.filter_doc:get_change_id()
  self.base_results     = nil
  self:run_search("")
end

-- Runs fd for `text` ("" lists all files), replacing the current results.
function FdView:run_search(text)
  self.live_text = text
  local root = self.root
  local cfg  = config.plugins.fd_files
  local max  = cfg.max_results
  local cmd
  if text == "" then
    cmd = H.build_cmd(cfg.executable, cfg.extra_flags, "--max-results", tostring(max), ".", root)
  else
    cmd = H.build_cmd(cfg.executable, cfg.extra_flags, "--max-results", tostring(max),
      "--ignore-case", "--full-path", fd_pattern(root, text), root)
  end

  core.log("fd-files: %s", table.concat(cmd, " "))

  self:start_search(function(run)
    local count, code, err = run(cmd, parse_line, max)
    if count == 0 and code ~= 0 and is_remote(root) then
      -- fd is not installed (typical on remote hosts): fall back to find,
      -- which every POSIX host has, skipping .git directories
      core.log("fd-files: %s failed (%s), falling back to find", cfg.executable, tostring(code))
      local find = { "find", root, "-name", ".git", "-prune", "-o", "-type", "f" }
      if text ~= "" then
        local glob = {}
        for _, c in ipairs(filter_chars(text)) do glob[#glob + 1] = glob_escape(c) end
        table.insert(find, "-ipath")
        table.insert(find, "*" .. table.concat(glob, "*") .. "*")
      end
      table.insert(find, "-print")
      count, code, err = run(find, parse_line, max)
      if count == 0 and code ~= 0 and text == "" then
        core.error("fd-files: search failed: %s", tostring(err))
      end
    end
    return count, code, err
  end, { base = text == "" })
end

function FdView:live_search(text)
  local cfg = config.plugins.fd_files
  if not cfg.live_filter then return end
  if text ~= "" and #filter_chars(text) >= cfg.live_min_chars then
    self:run_search(text)
  elseif self.live_text ~= "" then
    -- too short to search: back to the unfiltered results, narrowed locally
    if not self:restore_base_results() then self:run_search("") end
  end
end

function FdView:refresh()
  local root = self.root
  -- Re-detect root in case the active doc changed.
  self.root = H.get_search_root()
  if self.root ~= root then
    core.log("fd-files: refresh root changed to %s", self.root)
  end
  self.base_results = nil
  local cfg  = config.plugins.fd_files
  local ft   = self.filter_doc:get_text(1, 1, 1, math.huge)
  local live = cfg.live_filter and ft ~= "" and #filter_chars(ft) >= cfg.live_min_chars
  self:run_search(live and ft or "")
end

-- ---------------------------------------------------------------------------
-- Update — keep redrawing while fd is running
-- ---------------------------------------------------------------------------

function FdView:update()
  FdView.super.update(self)
  if self.searching then
    core.redraw = true
  end
end

return FdView
