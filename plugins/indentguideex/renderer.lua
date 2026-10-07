-- mod-version:3
local style = require "core.style"
local config = require "core.config"
local Cache = require "plugins.indentguideex.cache"

local Renderer = {}

local DEFAULT_RAINBOW_COLORS = {
  { 220, 110, 110, 120 }, -- red/pink
  { 220, 180, 100, 120 }, -- amber/gold
  { 110, 200, 130, 120 }, -- green
  { 100, 180, 220, 120 }, -- cyan/blue
  { 180, 130, 220, 120 }, -- purple
  { 220, 130, 190, 120 }, -- magenta
}

---Draw indentation guide lines for a single document line
---@param docview core.docview
---@param line integer
---@param x number
---@param y number
---@param line_h number? height drawn for the line, all its rows when wrapped
function Renderer.draw_line(docview, line, x, y, line_h)
  local conf = config.plugins.indentguideex
  if not conf or not conf.enabled or not docview.doc or docview.doc.large_file then
    return
  end

  local spaces = Cache.get_guide_spaces(docview.doc, line)
  if spaces <= 0 then return end

  local _, indent_size = docview.doc:get_indent_info()
  indent_size = indent_size or config.indent_size or 2

  local font = docview:get_font()
  local space_sz = docview._igex_space_sz
  if not space_sz or docview._igex_font ~= font then
    space_sz = font:get_width(" ")
    docview._igex_space_sz = space_sz
    docview._igex_font = font
  end
  local lh = docview:get_line_height()
  -- continuation rows of a wrapped line start at this x offset: guides left
  -- of it span every row, the others only the first (text is under them)
  local wrap_x = docview.wrapped_line_offsets and docview.wrapped_line_offsets[line] or 0
  local full_h = line_h or lh

  local w = conf.line_width or math.max(1, math.ceil(space_sz * 0.15))
  local guide_style = conf.style or "solid"
  local show_level_0 = conf.show_level_0
  local rainbow = conf.rainbow
  local rainbow_colors = conf.rainbow_colors or DEFAULT_RAINBOW_COLORS

  local base_color = style.guide or style.selection or { 255, 255, 255, 40 }
  local highlight_color = style.guide_highlight or style.accent or { 255, 255, 255, 120 }

  local scope = docview._igex_active_scope
  local active_lvl = (scope and line >= scope.s_line and line <= scope.e_line) and scope.lvl or -1

  local start_i = show_level_0 and 0 or indent_size
  for i = start_i, spaces - 1, indent_size do
    local is_active = (i < active_lvl and (i + indent_size) >= active_lvl)

    local color = base_color
    if rainbow then
      local level_idx = math.floor(i / indent_size)
      color = rainbow_colors[(level_idx % #rainbow_colors) + 1] or base_color
    end
    if is_active and conf.active_highlight then
      color = highlight_color
    end

    local rx = math.ceil(x + space_sz * i)
    local h = (space_sz * i < wrap_x) and full_h or lh

    if guide_style == "solid" then
      renderer.draw_rect(rx, y, w, h, color)
    elseif guide_style == "dotted" then
      local dot_sz = math.max(1, w)
      local step = dot_sz * 3
      for py = y, y + h - dot_sz, step do
        renderer.draw_rect(rx, py, w, dot_sz, color)
      end
    elseif guide_style == "dashed" then
      local dash_len = math.max(3, math.floor(h / 3))
      local gap = math.max(2, math.floor(h / 6))
      local step = dash_len + gap
      for py = y, y + h - dash_len, step do
        renderer.draw_rect(rx, py, w, dash_len, color)
      end
    else
      renderer.draw_rect(rx, y, w, h, color)
    end
  end
end

return Renderer
