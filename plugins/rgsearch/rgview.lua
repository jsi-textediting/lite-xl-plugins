local core     = require "core"
local common   = require "core.common"
local config   = require "core.config"
local style    = require "core.style"
local ListView = require "plugins.shared.listview"
local H        = require "plugins.shared.search_helpers"

config.plugins.rgsearch = common.merge({
  executable     = "rg",
  extra_flags    = { "--vimgrep", "--smart-case", "--follow" },
  max_results    = 10000,  -- rg is stopped after this many matches
  live_filter    = true,   -- re-run rg with the filter text as the pattern once typing pauses
  live_min_chars = 2,      -- shorter filter text only filters the loaded results
}, config.plugins.rgsearch)

-- Lazy pattern: handles Windows drive-letter colons (e.g. C:\foo:10:5:text)
local function parse_line(line)
  local file, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)")
  if file then
    return { file = file, line = tonumber(lnum), col = tonumber(col), text = text }
  end
end

local RgView = ListView:extend()

function RgView:__tostring() return "RgView" end

function RgView:new(query, root)
  RgView.super.new(self)
  self.query      = ""
  self.base_query = ""
  self.root       = root
  -- results of a live search are rg's matches for the filter text; fuzzy
  -- filtering them again would drop regex matches
  self.live_exact = true
  self:begin_search(query)
end

function RgView:get_name()
  return "Rg: " .. (self.query or "")
end

-- ---------------------------------------------------------------------------
-- Abstract method implementations
-- ---------------------------------------------------------------------------

function RgView:get_item_text(item)
  return common.basename(item.file) .. " " .. item.text
end

function RgView:get_status_text()
  local ft = self.filter_doc:get_text(1, 1, 1, math.huge)
  if self.searching then
    return string.format("Searching (%d matches) for %q...", self:get_result_count(), self.query)
  elseif self.search_error then
    return self.search_error
  end
  local limit = #self.results >= config.plugins.rgsearch.max_results and " (limit reached)" or ""
  if ft ~= "" and ft ~= self.query then
    return string.format("%d / %d matches for %q%s", #self.filtered_results, #self.results, self.query, limit)
  else
    return string.format("Found %d matches for %q%s", #self.results, self.query, limit)
  end
end

function RgView:draw_item(i, item, x, y, w, h)
  local match_color = (i == self.selected_idx) and style.accent or style.text
  x = x + style.padding.x
  local project = core.root_project()
  local rel = (project and project.path ~= "")
    and project:normalize_path(item.file)
    or common.basename(item.file)
  local loc = string.format(":%d:%d: ", item.line, item.col)
  x = common.draw_text(style.font,      style.accent,   rel,       "left", x, y, w, h)
  x = common.draw_text(style.font,      style.text,     loc,       "left", x, y, w, h)
  x = common.draw_text(style.code_font, match_color,    item.text, "left", x, y, w, h)
  self.max_h_scroll = math.max(self.max_h_scroll, x)
end

function RgView:open_selected()
  local res = self.filtered_results[self.selected_idx]
  if not res then return end
  core.try(function()
    local dv = core.root_view:open_doc(core.open_doc(res.file))
    core.root_view.root_node:update_layout()
    dv.doc:set_selection(res.line, res.col)
    dv:scroll_to_line(res.line, false, true)
  end)
  return true
end

-- Keep old name as alias (used from rgsearch/init.lua).
RgView.open_selected_result = RgView.open_selected

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------

-- New search for `query`: clears the filter text.
function RgView:begin_search(query)
  self.filter_doc:remove(1, 1, math.huge, math.huge)
  self.filter_change_id = self.filter_doc:get_change_id()
  self.base_query       = query
  self.base_results     = nil
  self:run_search("")
end

-- Runs rg with the filter `text` as the pattern, or with the base query
-- when `text` is "", replacing the current results.
function RgView:run_search(text)
  self.live_text = text
  self.query     = text ~= "" and text or self.base_query

  local cfg = config.plugins.rgsearch
  local cmd = H.build_cmd(cfg.executable, cfg.extra_flags, "--", self.query, self.root)

  core.log("rg-search: %s", table.concat(cmd, " "))

  self:start_search(function(run)
    return run(cmd, parse_line, cfg.max_results)
  end, { base = text == "" })
end

function RgView:live_search(text)
  local cfg = config.plugins.rgsearch
  if not cfg.live_filter then return end
  if text ~= "" and #text >= cfg.live_min_chars then
    self:run_search(text)
  elseif self.live_text ~= "" then
    -- too short to search: back to the base query's results, narrowed locally
    self.query = self.base_query
    if not self:restore_base_results() then self:run_search("") end
  end
end

function RgView:refresh()
  local ft  = self.filter_doc:get_text(1, 1, 1, math.huge)
  local cfg = config.plugins.rgsearch
  if cfg.live_filter then
    -- re-run for the filter text, keeping it
    local text = (ft ~= "" and #ft >= cfg.live_min_chars) and ft or ""
    if text == "" then self.base_results = nil end
    self:run_search(text)
  else
    self:begin_search(ft ~= "" and ft or self.query)
  end
end

-- ---------------------------------------------------------------------------
-- Update — keep redrawing while rg is running
-- ---------------------------------------------------------------------------

function RgView:update()
  RgView.super.update(self)
  if self.searching then
    core.redraw = true
  end
end

return RgView
