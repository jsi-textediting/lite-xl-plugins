local config  = require "core.config"
local common  = require "core.common"
local DocView = require "core.docview"

config.plugins.isearch = common.merge({
  -- Default highlight color for non-current matches (translucent yellow).
  -- RGBA values 0-255.
  match_color    = { 255, 200, 50, 80 },
  case_sensitive = false,
}, config.plugins.isearch)

-- Shared state table.  init.lua modifies the fields at runtime; this module
-- only reads them during drawing.
local state = {
  active         = false,
  query          = "",
  direction      = "forward",
  view           = nil,   -- DocView where the search is active
  origin         = nil,   -- {l1, c1, l2, c2} cursor position to restore on cancel
  match          = nil,   -- {l1, c1, l2, c2} current match, or nil
  case_sensitive = false, -- per-session; seeded from config on each isearch_start
}

-- Paints the match at columns [s, e] of `line`.  Positions come from
-- get_line_screen_position(), which linewrapping makes wrap-aware: a match on
-- a wrapped continuation row lands on that row, and a match crossing a wrap
-- break gets one rect per row.
local function draw_match(dv, line, s, e, lh, color)
  local text   = dv.doc.lines[line]
  local font   = dv:get_font()
  local x1, y1 = dv:get_line_screen_position(line, s)
  local xe, ye = dv:get_line_screen_position(line, e)
  if ye == y1 then
    local x2, y2 = dv:get_line_screen_position(line, e + 1)
    if y2 ~= y1 then
      -- the match ends its row: extend over the last char instead
      x2 = xe + font:get_width(text:sub(e, e))
    end
    renderer.draw_rect(x1, y1, x2 - x1, lh, color)
    return
  end
  -- spans rows: walk the chars, flushing a rect whenever the row changes
  local rx, ry, last_x, last_w = x1, y1, x1, 0
  local col = s
  while col <= e do
    local n = col + 1
    while n <= e and common.is_utf8_cont(text, n) do n = n + 1 end
    local cx, cy = dv:get_line_screen_position(line, col)
    if cy ~= ry then
      renderer.draw_rect(rx, ry, last_x + last_w - rx, lh, color)
      rx, ry = cx, cy
    end
    last_x, last_w = cx, font:get_width(text:sub(col, n - 1))
    col = n
  end
  renderer.draw_rect(rx, ry, last_x + last_w - rx, lh, color)
end

-- Hook into draw_line_text so that highlight rects are painted BEFORE text,
-- making text readable on top of the solid-color rectangles.
local old_draw_line_text = DocView.draw_line_text

function DocView:draw_line_text(line, x, y)
  if state.active and self == state.view and state.query ~= "" then
    local lh   = self:get_line_height()
    local text = self.doc.lines[line]
    local cs   = state.case_sensitive
    local q    = cs and state.query or state.query:lower()
    local src  = cs and text       or text:lower()
    local col  = 1
    while col <= #text do
      local s, e = src:find(q, col, true)
      if not s then break end
      -- The current match is already shown by the normal doc selection
      -- highlight; skip it here to avoid double-drawing.
      local is_current = state.match
        and state.match[1] == line
        and state.match[2] == s
        and state.match[4] == e + 1
      if not is_current then
        draw_match(self, line, s, e, lh, config.plugins.isearch.match_color)
      end
      col = s + 1
    end
  end
  return old_draw_line_text(self, line, x, y)
end

return state
