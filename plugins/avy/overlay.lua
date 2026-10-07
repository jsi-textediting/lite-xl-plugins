local config  = require "core.config"
local common  = require "core.common"
local DocView = require "core.docview"

config.plugins.avy = common.merge({
  -- Characters used to generate jump labels, in priority order.
  keys     = "asdfghjklqwertyuiopzxcvbnm",
  -- Label background color (RGBA).
  label_bg = { 255, 175, 0, 230 },
  -- Label foreground (text) color (RGBA).
  label_fg = { 0, 0, 0, 255 },
}, config.plugins.avy)

-- Shared state.  init.lua drives the state machine; this module only reads
-- it during the draw pass.
local state = {
  active      = false,
  phase       = "idle",  -- "input" | "select"
  mode        = nil,     -- "char" | "word" | "line"
  view        = nil,     -- DocView where avy is active
  query       = "",      -- chars accumulated during input phase
  query_len   = 1,       -- how many chars the current mode needs
  candidates  = {},      -- array of { line, col, label }
  label_input = "",      -- prefix typed so far during select phase
}

-- Hook draw_overlay so that labels are painted ON TOP of all line text.
-- Not draw_line_text: plugins loaded later may replace it without chaining
-- (linewrapping draws wrapped lines itself), which would drop the labels.
-- get_line_screen_position() is wrap-aware, so labels land on wrapped rows.
local old_draw_overlay = DocView.draw_overlay

function DocView:draw_overlay(...)
  local result = old_draw_overlay(self, ...)

  if not (state.active and state.phase == "select" and self == state.view) then
    return result
  end

  local lh     = self:get_line_height()
  local tyo    = self:get_line_text_y_offset()
  local font   = self:get_font()
  -- Padding derived from the font's own metrics rather than the raw
  -- `SCALE' global -- `SCALE' only tracks live display-scale changes
  -- when `config.plugins.scale.mode' is "ui"; the document's own font
  -- (returned by `get_font()') always does, regardless of that mode.
  local pad    = math.max(1, math.ceil(font:get_width(" ") * 0.3))
  local prefix = state.label_input

  for _, c in ipairs(state.candidates) do
    -- Only show labels that still match the typed prefix.
    if prefix == "" or c.label:sub(1, #prefix) == prefix then
      local remaining = c.label:sub(#prefix + 1)
      if remaining ~= "" then
        local cx, cy = self:get_line_screen_position(c.line, c.col)
        local lw = font:get_width(remaining) + pad
        renderer.draw_rect(cx, cy, lw, lh, config.plugins.avy.label_bg)
        renderer.draw_text(font, remaining,
          cx + pad / 2, cy + tyo, config.plugins.avy.label_fg)
      end
    end
  end

  return result
end

return state
