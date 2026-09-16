local up_song_xml = {}

local up_zip = require("up_zip")
local up_xml = require("up_xml")
local up_preset = require("up_preset")

-- When a plugin is missing on the machine, renoise.song().instruments[i]
-- .plugin_properties.plugin_device is nil, so the live API exposes no path or
-- name for it. But the .xrns song file is a zip archive containing Song.xml,
-- which stores <PluginType>/<PluginIdentifier>/<PluginDisplayName> for EVERY
-- plugin -- including missing ones. We parse that to learn what the song
-- referenced, so a missing instrument can still be matched against an installed
-- candidate and upgraded.
--
-- This only recovers the *identity* (so we can match + swap). The actual plugin
-- state lives in the host/plugin, not the song, so a replacement loads at
-- default state unless the user's preset name (the instrument name) resolves in
-- the installed plugin's own bank.

local _cache = { file = nil, data = nil, parsed = nil }

-- up_xml.descendant_text returns "" (truthy) for an empty or self-closing element,
-- e.g. <PluginShortDisplayName/>. Left as-is that empty string wins every
-- `a or b` fallback and, worse, gets used as a lookup key (out[""] = entry), so a
-- later name lookup with a blank string would resolve to an unrelated instrument.
-- Collapse absent/blank fields to nil so the fallbacks and indexes behave.
local function nonempty(s)
  if type(s) == "string" and s ~= "" then return s end
  return nil
end

local function read_song_xml(song)
  local ok_app, app = pcall(function() return renoise.app() end)
  if not ok_app or not app then
    return nil
  end
  -- The absolute path to the loaded/saved song is exposed as song().file_name
  -- (empty string when the song has never been saved). Older/incorrect spellings
  -- (app.song_filename, song().song_filename) are kept only as fallbacks in case a
  -- Renoise build differs. Guarding each access is essential: reading a property
  -- that does not exist on the API object throws, which would otherwise silence
  -- recovery entirely -- and without recovery, missing plugins whose instrument
  -- name carries no protocol token (e.g. "Dark Dreams 1") can never be matched.
  local path
  local ok_f, fv = pcall(function() return song.file_name end)
  if ok_f and fv and fv ~= "" then
    path = fv
  else
    local ok_p, pv = pcall(function() return app.song_filename end)
    if ok_p and pv and pv ~= "" then
      path = pv
    else
      local ok_s, sv = pcall(function() return renoise.song().song_filename end)
      if ok_s and sv and sv ~= "" then
        path = sv
      end
    end
  end
  if not path or path == "" then
    return nil
  end
  if _cache.file == path and _cache.data then
    return _cache.data
  end
  -- Pure-Lua ZIP reader only: no system dependency, and no shell-out (which
  -- would be a command-injection risk on `app.song_filename`). Renoise `.xrns`
  -- files use the stored or deflate methods, both of which this covers; if
  -- extraction fails we simply report that no XML could be recovered.
  local ok_z, xml = pcall(function() return up_zip.extract(path, "Song.xml") end)
  if ok_z and xml and xml ~= "" then
    _cache.file = path
    _cache.data = xml
    -- The parsed tree belongs to the previous raw XML, so drop it here; recover()
    -- rebuilds and caches it lazily.
    _cache.parsed = nil
    return xml
  end
  return nil
end

-- Parse a Song.xml string into per-instrument plugin identities, keyed by
-- 1-based instrument index (parallel to song.instruments). Only instruments
-- that actually have a plugin (a <PluginType> element) are included, so samplers
-- are skipped. Exposed separately from recover() so it can be unit-tested
-- without a real .xrns file.
function up_song_xml.parse_instruments(xml)
  local out = {}
  if type(xml) ~= "string" or xml == "" then
    return out
  end
  local root = up_xml.parse(xml)
  if not root then
    return out
  end
  -- Walk the XML tree and collect every <Instrument> element at any depth, including
  -- those nested inside an <InstrumentGroup>. Grouping is handled structurally, not by
  -- fragile string matching, so it can never desync the index or drop an instrument.
  -- Each entry is also indexed by name / display name / identifier so callers can
  -- look a plugin up by the live instrument's name -- robust against reordering or
  -- non-plugin instruments (e.g. ext. MIDI) that shift the indices between the song
  -- and its Song.xml.
  local instruments = up_xml.find_all(root, "Instrument")
  local idx = 0
  for _, block in ipairs(instruments) do
    idx = idx + 1
    local ptype = nonempty(up_xml.descendant_text(block, "PluginType"))
    -- A missing/empty <PluginType> means this is not a plugin, so never classify
    -- it as one (otherwise malformed/edge Song.xml inputs mis-include samplers).
    if ptype then
      local identifier = nonempty(up_xml.descendant_text(block, "PluginIdentifier"))
      local disp = nonempty(up_xml.descendant_text(block, "PluginDisplayName"))
      local sdisp = nonempty(up_xml.descendant_text(block, "PluginShortDisplayName"))
      local iname = nonempty(up_xml.descendant_text(block, "Name"))
      -- Recover the loaded ensemble/preset name that Renoise stores inside the
      -- plugin's opaque ParameterChunk (base64-encoded CDATA). For Reaktor / Kontakt
      -- this is the "file://.../Name.ext" path of the loaded ensemble; surfacing it
      -- lets the tool show the preset even when the plugin itself failed to load on
      -- this machine (so the live API exposes no preset name). Attribute-bearing and
      -- indented ParameterChunks are handled by the tree parser for free.
      local preset_name
      local ensemble_url
      local cdata = up_xml.descendant_cdata(block, "ParameterChunk")
      if cdata then
        preset_name = up_preset.extract_name({ active_preset_data = cdata })
        ensemble_url = up_preset.find_ensemble_url(cdata)
      end
      -- Renoise records the active plugin program number. Reaktor keeps the same
      -- program bank across major versions (Razor's snapshots), so carrying the
      -- number over lets the replacement select the same patch even when the
      -- snapshot name can't be recovered (e.g. it lives only in the opaque chunk).
      local active_program = tonumber(up_xml.descendant_text(block, "ActiveProgram"))
      local entry = {
        index = idx,
        instrument_name = iname,
        protocol = ptype,
        identifier = identifier,
        display_name = disp or sdisp,
        short_display_name = sdisp or disp,
        preset_name = preset_name,
        ensemble_url = ensemble_url,
        active_program = active_program,
      }
      out[idx] = entry
      if iname then out[iname] = entry end
      if disp then out[disp] = entry end
      if sdisp then out[sdisp] = entry end
      if identifier then out[identifier] = entry end
    end
  end
  return out
end

-- Recover plugin identity per instrument, keyed by 1-based instrument index
-- (parallel to song.instruments). Only instruments that actually have a plugin
-- (a <PluginType> element) are included, so samplers are skipped.
function up_song_xml.recover(song)
  local xml = read_song_xml(song)
  if not xml then
    return {}
  end
  -- Parsing the whole Song.xml tree is the expensive part, and recover() is called
  -- repeatedly for the same song (e.g. per-row reinspection after an upgrade, while
  -- the file on disk is unchanged). Cache the parsed result so it runs once per song.
  if not _cache.parsed then
    _cache.parsed = up_song_xml.parse_instruments(xml)
  end
  return _cache.parsed
end

function up_song_xml.invalidate_cache()
  _cache.file = nil
  _cache.data = nil
  _cache.parsed = nil
end

return up_song_xml
