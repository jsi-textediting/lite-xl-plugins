-- Shared search helper functions used by rgsearch, fd-files, and similar plugins.

local core   = require "core"
local common = require "core.common"

local M = {}

function M.get_active_doc()
  local view = core.active_view
  return view and view.doc or nil
end

local VCS_MARKERS = { ".git", ".hg", ".svn" }

function M.find_vcs_root(dir)
  local current = dir
  while true do
    for _, marker in ipairs(VCS_MARKERS) do
      if system.get_file_info(current .. PATHSEP .. marker) then
        return current
      end
    end
    local parent = common.dirname(current)
    if not parent or parent == current then break end
    current = parent
  end
  return nil
end

function M.get_search_root()
  local doc      = M.get_active_doc()
  -- (doc.filename is relative to the project: as a search root it would be
  -- resolved against the local cwd, never against a remote project)
  local file     = doc and (doc.abs_filename or doc.filename)
  local file_dir = file and common.dirname(file)
  if file_dir then
    local vcs_root = M.find_vcs_root(file_dir)
    if vcs_root then return vcs_root end
  end
  local project   = core.root_project()
  local proj_path = project and project.path
  if file and proj_path and common.path_belongs_to(file, proj_path) then
    return proj_path
  end
  if file_dir then return file_dir end
  return proj_path or "."
end

function M.get_selection_or_word()
  local doc = M.get_active_doc()
  if not doc then return "" end
  local l1, c1, l2, c2 = doc:get_selection()
  if l1 == l2 and c1 == c2 then
    local translate = require "core.doc.translate"
    local wl1, wc1 = doc:position_offset(l1, c1, translate.start_of_word)
    local wl2, wc2 = doc:position_offset(l1, c1, translate.end_of_word)
    return doc:get_text(wl1, wc1, wl2, wc2)
  end
  return doc:get_text(l1, c1, l2, c2)
end

-- Concatenate strings and arrays into a flat command table.
-- Each argument may be a string or an array of strings.
function M.build_cmd(...)
  local t = {}
  for _, part in ipairs({...}) do
    if type(part) == "string" then
      t[#t+1] = part
    else
      for _, v in ipairs(part) do t[#t+1] = v end
    end
  end
  return t
end

return M
