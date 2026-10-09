-- mod-version:4
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local DocView = require "core.docview"

local Cache = require "plugins.indentguideex.cache"
local Scope = require "plugins.indentguideex.scope"
local Renderer = require "plugins.indentguideex.renderer"

config.plugins.indentguideex = common.merge({
  enabled = true,
  show_level_0 = false,
  active_highlight = true,
  style = "solid", -- "solid", "dotted", "dashed"
  rainbow = false,
  line_width = nil,
  config_spec = {
    name = "Indent Guide Ex",
    {
      label = "Enable",
      description = "Toggle drawing of indentation indicator lines.",
      path = "enabled",
      type = "toggle",
      default = true,
    },
    {
      label = "Show Level 0",
      description = "Draw indent guide for column 0 (next to gutter).",
      path = "show_level_0",
      type = "toggle",
      default = false,
    },
    {
      label = "Highlight Active Scope",
      description = "Highlight indentation guide of current block.",
      path = "active_highlight",
      type = "toggle",
      default = true,
    },
    {
      label = "Style",
      description = "Visual style of guide lines.",
      path = "style",
      type = "selection",
      default = "solid",
      values = { "solid", "dotted", "dashed" },
    },
    {
      label = "Rainbow Indents",
      description = "Cycle colors per indentation level.",
      path = "rainbow",
      type = "toggle",
      default = false,
    },
  }
}, config.plugins.indentguideex)

-- Disable legacy indentguide to avoid duplicate drawing and redundant CPU load
if config.plugins.indentguide then
  config.plugins.indentguide.enabled = false
end

-- ============================================================================
-- DocView Hooks
-- ============================================================================

local old_dv_update = DocView.update
function DocView:update(...)
  old_dv_update(self, ...)

  local conf = config.plugins.indentguideex
  if not conf or not conf.enabled or not self:is(DocView) or not self.doc or self.doc.large_file then
    self._igex_active_scope = nil
    return
  end

  if not conf.active_highlight then
    self._igex_active_scope = nil
    return
  end

  local line1, col1 = self.doc:get_selection()
  local change_id = self.doc:get_change_id()

  -- Check memoized caret/doc state: when scrolling without moving caret, NEVER recalculate!
  local last = self._igex_last_state
  if last
    and last.line == line1
    and last.col == col1
    and last.change_id == change_id
    and self._igex_active_scope ~= nil
  then
    return
  end

  self._igex_last_state = {
    line = line1,
    col = col1,
    change_id = change_id,
  }

  local s_line, e_line, lvl = Scope.get_active_scope(self)
  if s_line then
    self._igex_active_scope = { s_line = s_line, e_line = e_line, lvl = lvl }
  else
    self._igex_active_scope = false
  end
end

local old_draw_line_text = DocView.draw_line_text
-- Guides are drawn after the text (they sit in leading whitespace) so the
-- returned height is known: linewrapping returns one line height per wrapped
-- row, and the guides span all of them.
function DocView:draw_line_text(line, x, y)
  local h = old_draw_line_text(self, line, x, y)
  Renderer.draw_line(self, line, x, y, h)
  return h
end

-- ============================================================================
-- Commands
-- ============================================================================

command.add("core.docview", {
  ["indentguideex:toggle"] = function()
    local conf = config.plugins.indentguideex
    conf.enabled = not conf.enabled
    core.redraw = true
  end,

  ["indentguideex:toggle-level-0"] = function()
    local conf = config.plugins.indentguideex
    conf.show_level_0 = not conf.show_level_0
    core.redraw = true
  end,

  ["indentguideex:toggle-active-highlight"] = function()
    local conf = config.plugins.indentguideex
    conf.active_highlight = not conf.active_highlight
    core.redraw = true
  end,

  ["indentguideex:toggle-rainbow"] = function()
    local conf = config.plugins.indentguideex
    conf.rainbow = not conf.rainbow
    core.redraw = true
  end,

  ["indentguideex:cycle-style"] = function()
    local conf = config.plugins.indentguideex
    local styles = { "solid", "dotted", "dashed" }
    local next_idx = 1
    for idx, s in ipairs(styles) do
      if s == conf.style then
        next_idx = (idx % #styles) + 1
        break
      end
    end
    conf.style = styles[next_idx]
    core.log("Indent Guide style: %s", conf.style)
    core.redraw = true
  end,
})

return {
  cache = Cache,
  scope = Scope,
  renderer = Renderer,
}
