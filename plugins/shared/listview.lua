-- Shared list-view base class.
--
-- Provides a scrollable list with:
--   - a sticky header (status text row + inline filter editor row)
--   - fuzzy filter via common.fuzzy_match
--   - keyboard / mouse navigation
--   - overlay rendering: opens as a floating panel above the status bar
--     (does not touch the node tree)
--
-- Subclasses must implement:
--   ListView:get_item_text(item)        → string for fuzzy matching
--   ListView:get_status_text()          → string for header row 1
--   ListView:draw_item(i, item, x, y, w, h)
--   ListView:open_selected()            → called on Enter / click
--
-- Subclasses may implement:
--   ListView:live_search(text)          → re-run the search for the filter
--                                         text, called once typing pauses
--                                         for config.plugins.listview.live_delay

local core     = require "core"
local common   = require "core.common"
local config   = require "core.config"
local command  = require "core.command"
local style    = require "core.style"
local process  = require "core.process"
local Doc      = require "core.doc"
local DocView  = require "core.docview"
local View     = require "core.view"
local RootView = require "core.rootview"

config.plugins.listview = common.merge({
  rows       = 10,   -- number of result rows visible in the overlay panel
  live_delay = 0.3,  -- seconds of typing pause before a live search re-runs
}, config.plugins.listview)

-- Minimum seconds between re-filters while results are streaming in.
local REFILTER_INTERVAL = 0.1
-- Seconds of output processing per frame before the search thread yields.
local READ_BUDGET = 0.008
-- Bytes of stderr kept for the status line.
local MAX_STDERR = 4096

-- ---------------------------------------------------------------------------
-- SingleLineDoc — a Doc that strips newlines so the filter stays on one line.
-- ---------------------------------------------------------------------------

local SingleLineDoc = Doc:extend()
function SingleLineDoc:insert(line, col, text)
  SingleLineDoc.super.insert(self, line, col, text:gsub("\n", ""))
end

-- ---------------------------------------------------------------------------
-- ListView
-- ---------------------------------------------------------------------------

local ListView = View:extend()

ListView.context = "session"

-- Overlay state (class-level, shared across all subclasses).
ListView._overlay_view      = nil  -- the currently open overlay view
ListView._overlay_prev_view = nil  -- the view to restore focus to on close

function ListView:new()
  ListView.super.new(self)
  self.scrollable       = true
  self.results          = {}
  self.filtered_results = {}
  self.selected_idx     = 0
  self.max_h_scroll     = 0

  -- Embedded single-line editor for the filter input.
  self.filter_doc  = SingleLineDoc()
  self.filter_view = DocView(self.filter_doc)
  self.filter_view.context                  = "session"
  self.filter_view.scrollable               = false
  self.filter_view.get_gutter_width         = function() return 0 end
  self.filter_view.scroll_to_make_visible   = function() end
  self.filter_view.get_scrollable_size      = function() return 0 end
  self.filter_view.get_h_scrollable_size    = function() return 0 end
  self.filter_view.draw_line_highlight      = function() end
  self.filter_change_id = self.filter_doc:get_change_id()

  -- Search state.
  self.searching        = false
  self.search_gen       = 0      -- bumped to cancel the running search
  self.proc             = nil    -- process of the running search
  self.search_error     = nil    -- stderr of a search that found nothing
  self.base_results     = nil    -- complete results of the unfiltered search
  self.live_text        = ""     -- filter text the current results were searched with
  self.live_exact       = false  -- true: results for live_text are shown unfiltered
  self.live_seq         = 0      -- bumped on each filter edit to debounce live_search
  self.filter_dirty     = false  -- results changed since the last re-filter
  self.last_filter_time = 0
end

function ListView:supports_text_input()
  return true
end

-- ---------------------------------------------------------------------------
-- Filter helpers
-- ---------------------------------------------------------------------------

local function filter_text(self)
  return self.filter_doc:get_text(1, 1, 1, math.huge)
end

local function compare_score(a, b)
  if a.score == b.score then
    return a.idx < b.idx
  end
  return a.score > b.score
end

-- reset_selection: true when filter text changed (jump to item 1),
-- false when streaming (preserve current selection).
function ListView:update_filter(reset_selection)
  local ft = filter_text(self)
  self.filter_dirty     = false
  self.last_filter_time = system.get_time()
  if ft == "" or (self.live_exact and ft == self.live_text) then
    self.filtered_results = self.results
  else
    local matches = {}
    local is_files = self.is_file_list or false
    local needle = self:get_filter_needle(ft)
    for idx, item in ipairs(self.results) do
      local hay = self:get_item_text(item)
      local score = common.fuzzy_match(hay, needle, is_files)
      if score then
        table.insert(matches, { item = item, score = score, idx = idx })
      end
    end
    table.sort(matches, compare_score)
    self.filtered_results = {}
    for i, m in ipairs(matches) do
      self.filtered_results[i] = m.item
    end
  end
  if reset_selection or self.selected_idx == 0 then
    self.selected_idx = #self.filtered_results > 0 and 1 or 0
    if reset_selection then self.scroll.to.y = 0 end
  else
    self.selected_idx = math.min(self.selected_idx, #self.filtered_results)
  end
  core.redraw = true
end

-- ---------------------------------------------------------------------------
-- Search lifecycle
-- ---------------------------------------------------------------------------

-- Appends one result; the visible list is re-filtered at most every
-- REFILTER_INTERVAL from update() instead of once per streamed line.
function ListView:push_result(item)
  if self.results_stale then
    -- first result of a new search replaces the previous ones, so they stay
    -- visible until there is something to show instead
    self.results_stale = false
    self.results       = {}
    self.selected_idx  = 0
    self.max_h_scroll  = 0
    self.scroll.to.y   = 0
  end
  table.insert(self.results, item)
  self.filter_dirty = true
  core.redraw = true
end

-- Stops the running search, if any, and kills its process.
function ListView:cancel_search()
  self.search_gen = self.search_gen + 1
  if self.proc then
    pcall(self.proc.kill, self.proc)
    self.proc = nil
  end
  self.searching = false
end

local function drain_stderr(proc, err)
  while true do
    local ok, chunk = pcall(proc.read_stderr, proc, 65536)
    if not ok or not chunk or chunk == "" then return end
    if #err.text < MAX_STDERR then err.text = err.text .. chunk end
  end
end

-- Starts a search in a new thread, cancelling the running one. `fn(run)` is
-- called inside the thread; `run(cmd, parse_line, max_results)` executes
-- one command, adds parse_line(line) for each output line that parses, and
-- returns the number of results, the exit code (nil when the process could
-- not be started or was cut off at max_results) and its stderr.
-- opts.base: the search is unfiltered, keep its results for restore_base_results().
function ListView:start_search(fn, opts)
  opts = opts or {}
  self:cancel_search()
  local gen = self.search_gen
  self.searching     = true
  self.search_error  = nil
  self.results_stale = true
  core.redraw = true

  local function run(cmd, parse_line, max_results)
    if self.search_gen ~= gen then return 0 end
    local ok, proc = pcall(process.start, cmd)
    if not ok or not proc then return 0, nil, tostring(proc) end
    if self.search_gen ~= gen then pcall(proc.kill, proc) return 0 end
    self.proc = proc
    local count, rest, err = 0, "", { text = "" }
    local done, exited = false, false
    while not done do
      local start = system.get_time()
      while true do
        local chunk = proc:read_stdout(65536)
        -- end of output: nil, or still "" after the process exited (a
        -- process that wrote nothing may never report end of stream)
        if not chunk or (chunk == "" and exited) then done = true break end
        if chunk == "" then
          if proc:running() then break end
          exited = true  -- read once more, output may still be buffered
        end
        rest = rest .. chunk
        local pos = 1
        while true do
          local nl = rest:find("\n", pos, true)
          if not nl then break end
          local item = parse_line((rest:sub(pos, nl - 1):gsub("\r$", "")))
          pos = nl + 1
          if item then
            count = count + 1
            self:push_result(item)
            if max_results and count >= max_results then
              pcall(proc.kill, proc)
              if self.proc == proc then self.proc = nil end
              return count, nil, err.text
            end
          end
        end
        rest = rest:sub(pos)
        if system.get_time() - start > READ_BUDGET then break end
      end
      -- keep stderr flowing so the process cannot block on a full pipe
      drain_stderr(proc, err)
      if not done then coroutine.yield() end
      if self.search_gen ~= gen then
        pcall(proc.kill, proc)
        return count
      end
    end
    if rest ~= "" then
      local item = parse_line((rest:gsub("\r$", "")))
      if item then count = count + 1; self:push_result(item) end
    end
    local code = proc:wait(5)
    drain_stderr(proc, err)
    if self.proc == proc then self.proc = nil end
    return count, code, err.text
  end

  core.add_thread(function()
    local count, code, err = fn(run)
    if self.search_gen ~= gen then return end
    if self.results_stale then
      -- nothing found: drop the previous results
      self.results_stale = false
      self.results       = {}
    end
    if count == 0 and code ~= 0 and err and err ~= "" then
      -- one line for the status row, e.g. rg's multi-line regex errors
      self.search_error = err:gsub("%s+", " "):match("^%s*(.-)%s*$"):sub(1, 200)
    end
    if opts.base then self.base_results = self.results end
    self.searching = false
    self:update_filter(false)
  end)
end

-- Shows the results of the unfiltered search again without re-running it.
-- Returns false when there are none (the base search never completed).
function ListView:restore_base_results()
  if not self.base_results then return false end
  self:cancel_search()
  self.results_stale = false
  self.search_error  = nil
  self.live_text     = ""
  self.results       = self.base_results
  self:update_filter(true)
  return true
end

-- Calls live_search() once the filter text has not changed for live_delay.
function ListView:schedule_live_search()
  self.live_seq = self.live_seq + 1
  if not self.live_search then return end
  local seq = self.live_seq
  core.add_thread(function()
    coroutine.yield(config.plugins.listview.live_delay)
    if seq ~= self.live_seq or ListView._overlay_view ~= self then return end
    local text = filter_text(self)
    if text ~= self.live_text then self:live_search(text) end
  end)
end

-- ---------------------------------------------------------------------------
-- Abstract methods (subclass must override)
-- ---------------------------------------------------------------------------

function ListView:get_item_text(item)
  return tostring(item)
end

-- Filter text as matched against get_item_text().
function ListView:get_filter_needle(text)
  return text
end

function ListView:get_status_text()
  return string.format("%d items", #self.filtered_results)
end

function ListView:draw_item(i, item, x, y, w, h) end

function ListView:open_selected() end

-- ---------------------------------------------------------------------------
-- Overlay geometry
-- ---------------------------------------------------------------------------

function ListView:get_overlay_height()
  local lh       = style.font:get_height() + style.padding.y
  local header_h = lh * 2 + style.padding.y * 2
  return header_h + config.plugins.listview.rows * lh
end

-- Recompute position/size so the panel sits just above the status bar,
-- spanning the full width of the root view.
function ListView:_sync_overlay_geometry()
  local rv   = core.root_view
  local sv_h = core.status_view and core.status_view.size.y or 0
  local h    = self:get_overlay_height()
  self.position.x = rv.position.x
  self.position.y = rv.position.y + rv.size.y - h - sv_h
  self.size.x     = rv.size.x
  self.size.y     = h
end

-- ---------------------------------------------------------------------------
-- Overlay lifecycle
-- ---------------------------------------------------------------------------

-- Returns the currently open overlay if it is an instance of `cls`.
function ListView.find_overlay_view(cls)
  local ov = ListView._overlay_view
  if ov and ov:is(cls) then return ov end
  return nil
end

function ListView:open_as_overlay()
  -- Save the previous active view so close() can restore it.
  -- Skip saving if the previous "active" view was another ListView overlay
  -- (reopening a different list type should still return to the editor).
  local prev = core.active_view
  if not (prev and prev:is(ListView)) then
    ListView._overlay_prev_view = prev
  end

  ListView._overlay_view = self
  self:_sync_overlay_geometry()
  core.set_active_view(self)
  core.redraw = true
end

function ListView:close()
  if ListView._overlay_view ~= self then return end
  ListView._overlay_view = nil
  self:cancel_search()
  self.live_seq = self.live_seq + 1
  -- Only restore previous focus if we still own it.
  -- If open_selected() already moved focus to the editor, leave it there.
  if core.active_view == self then
    local prev = ListView._overlay_prev_view
    if prev then core.set_active_view(prev) end
  end
  ListView._overlay_prev_view = nil
  core.redraw = true
end

-- ---------------------------------------------------------------------------
-- Input forwarding
-- ---------------------------------------------------------------------------

function ListView:on_text_input(text)
  self.filter_view:on_text_input(text)
  core.blink_reset()
end

-- ---------------------------------------------------------------------------
-- Layout helpers
-- ---------------------------------------------------------------------------

function ListView:get_results_yoffset()
  return (style.font:get_height() + style.padding.y) * 2 + style.padding.y * 2
end

function ListView:get_line_height()
  return style.padding.y + style.font:get_height()
end

function ListView:get_scrollable_size()
  return self:get_results_yoffset() + #self.filtered_results * self:get_line_height()
end

function ListView:get_h_scrollable_size()
  return self.max_h_scroll
end

function ListView:get_visible_results_range()
  local lh  = self:get_line_height()
  local oy  = self:get_results_yoffset()
  local min = math.max(1, math.floor((self.scroll.y + oy - style.font:get_height()) / lh))
  return min, min + math.floor(self.size.y / lh) + 1
end

function ListView:each_visible_result()
  return coroutine.wrap(function()
    local lh       = self:get_line_height()
    local x, y     = self:get_content_offset()
    local min, max = self:get_visible_results_range()
    y = y + self:get_results_yoffset() + lh * (min - 1)
    for i = min, max do
      local item = self.filtered_results[i]
      if not item then break end
      local _, _, w = self:get_content_bounds()
      coroutine.yield(i, item, x, y, w, lh)
      y = y + lh
    end
  end)
end

function ListView:scroll_to_make_selected_visible()
  local h  = self:get_line_height()
  local y  = h * (self.selected_idx - 1)
  local oy = self:get_results_yoffset()
  self.scroll.to.y = math.min(self.scroll.to.y, y)
  self.scroll.to.y = math.max(self.scroll.to.y, y + h - self.size.y + oy)
end

-- ---------------------------------------------------------------------------
-- Mouse handling
-- ---------------------------------------------------------------------------

function ListView:on_mouse_moved(mx, my, ...)
  ListView.super.on_mouse_moved(self, mx, my, ...)
  self.selected_idx = 0
  for i, item, x, y, w, h in self:each_visible_result() do
    if mx >= x and my >= y and mx < x + w and my < y + h then
      self.selected_idx = i
      break
    end
  end
end

function ListView:on_mouse_pressed(...)
  local caught = ListView.super.on_mouse_pressed(self, ...)
  if not caught then
    local selected = self:open_selected()
    if selected then self:close() end
    return selected
  end
end

-- ---------------------------------------------------------------------------
-- Update
-- ---------------------------------------------------------------------------

function ListView:update()
  -- Keep overlay geometry in sync with window size every frame.
  if ListView._overlay_view == self then
    self:_sync_overlay_geometry()
  end

  ListView.super.update(self)

  -- Position the embedded filter DocView in the header area.
  local lh      = style.font:get_height() + style.padding.y
  local label_w = style.font:get_width("/ ")
  local fx      = self.position.x + style.padding.x + label_w
  local fy      = self.position.y + lh + style.padding.y
  local fw      = self.size.x - style.padding.x - label_w
  self.filter_view.position.x = fx
  self.filter_view.position.y = fy
  self.filter_view.size.x     = fw
  self.filter_view.size.y     = lh

  -- Update filter_view with fake focus so DocView's blink timer advances.
  local prev = core.active_view
  core.active_view = self.filter_view
  self.filter_view:update()
  core.active_view = prev

  -- Detect changes in the filter doc and re-filter.
  local cid = self.filter_doc:get_change_id()
  if cid ~= self.filter_change_id then
    self.filter_change_id = cid
    self:update_filter(true)
    self:schedule_live_search()
  elseif self.filter_dirty
    and system.get_time() - self.last_filter_time >= REFILTER_INTERVAL then
    self:update_filter(false)
  end
end

-- ---------------------------------------------------------------------------
-- Draw
-- ---------------------------------------------------------------------------

function ListView:draw()
  self:draw_background(style.background)

  local ox, oy  = self.position.x, self.position.y
  local yoffset = self:get_results_yoffset()

  -- Sticky header background.
  renderer.draw_rect(ox, oy, self.size.x, yoffset, style.background)
  if self.scroll.y ~= 0 then
    renderer.draw_rect(ox, oy + yoffset, self.size.x, style.divider_size, style.divider)
  end

  -- Top border to separate from editor content below.
  renderer.draw_rect(ox, oy, self.size.x, style.divider_size, style.divider)

  -- Status text (row 1).
  renderer.draw_text(style.font, self:get_status_text(),
    ox + style.padding.x, oy + style.padding.y, style.text)

  -- Filter input (row 2): "/ " label + embedded DocView.
  local fy = oy + style.font:get_height() + style.padding.y * 2
  renderer.draw_text(style.font, "/ ", ox + style.padding.x, fy, style.dim)
  self.filter_view:draw()

  -- Result rows.
  local _, _, bw = self:get_content_bounds()
  core.push_clip_rect(ox, oy + yoffset + style.divider_size, bw, self.size.y - yoffset)
  self.max_h_scroll = 0
  for i, item, x, y, w, h in self:each_visible_result() do
    if i == self.selected_idx then
      renderer.draw_rect(x, y, w, h, style.line_highlight)
    end
    self:draw_item(i, item, x, y, w, h)
  end
  core.pop_clip_rect()

  self:draw_scrollbar()
end

-- ---------------------------------------------------------------------------
-- RootView hooks — overlay update, drawing, and mouse forwarding
-- ---------------------------------------------------------------------------

local old_rv_update = RootView.update
function RootView:update()
  old_rv_update(self)
  -- Drive the overlay's update manually since it is not in the node tree.
  local ov = ListView._overlay_view
  if ov then ov:update() end
end

local old_rv_draw = RootView.draw
function RootView:draw()
  old_rv_draw(self)
  local ov = ListView._overlay_view
  if ov then
    local p, s = ov.position, ov.size
    core.push_clip_rect(p.x, p.y, s.x, s.y)
    ov:draw()
    core.pop_clip_rect()
  end
end

local old_rv_mouse_pressed = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(button, x, y, clicks)
  local ov = ListView._overlay_view
  if ov then
    local p, s = ov.position, ov.size
    if x >= p.x and y >= p.y and x < p.x + s.x and y < p.y + s.y then
      core.set_active_view(ov)
      return ov:on_mouse_pressed(button, x, y, clicks)
    else
      -- Click outside overlay: close it, then let the click reach the editor.
      ov:close()
    end
  end
  return old_rv_mouse_pressed(self, button, x, y, clicks)
end

local old_rv_mouse_moved = RootView.on_mouse_moved
function RootView:on_mouse_moved(x, y, dx, dy)
  local ov = ListView._overlay_view
  if ov then
    local p, s = ov.position, ov.size
    if x >= p.x and y >= p.y and x < p.x + s.x and y < p.y + s.y then
      self.mouse.x, self.mouse.y = x, y
      ov:on_mouse_moved(x, y, dx, dy)
      return
    end
  end
  return old_rv_mouse_moved(self, x, y, dx, dy)
end

local old_rv_wheel = RootView.on_mouse_wheel
function RootView:on_mouse_wheel(...)
  local ov = ListView._overlay_view
  if ov then
    local p, s = ov.position, ov.size
    local mx, my = self.mouse.x, self.mouse.y
    if mx >= p.x and my >= p.y and mx < p.x + s.x and my < p.y + s.y then
      return ov:on_mouse_wheel(...)
    end
  end
  return old_rv_wheel(self, ...)
end

-- ---------------------------------------------------------------------------
-- Shared command: delete-forward in the filter editor.
-- Scoped to ListView so any subclass (RgView, BufferExView, KillRingView, …)
-- gets ctrl+d delete-forward automatically — the key binding lives in
-- configs/keymap/init.lua.
-- ---------------------------------------------------------------------------

command.add(ListView, {
  ["listview:delete-forward"] = function(v)
    local prev = core.active_view
    core.active_view = v.filter_view
    command.perform("doc:delete")
    core.active_view = prev
  end,

  ["listview:close"] = function(v)
    v:close()
  end,
})

-- Prevent workspace.lua from serializing ListView subclass instances.
-- workspace.lua matches views by checking getmetatable(view) == package.loaded[name].
-- Replacing each subclass entry with `true` breaks that identity check, so views
-- are neither saved on exit nor restored on startup (once the workspace file refreshes).
-- rawget(mod, "super") avoids __index; it equals ListView only for direct subclasses
-- (RgView, BufferExView, KillRingView) and not for ListView itself (super = View).
core.add_thread(function()
  for name, mod in pairs(package.loaded) do
    if type(mod) == "table" and rawget(mod, "super") == ListView then
      package.loaded[name] = true
    end
  end
end)

return ListView
