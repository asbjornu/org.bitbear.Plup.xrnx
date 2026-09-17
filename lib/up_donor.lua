local up_zip = require("up_zip")
local up_song_xml = require("up_song_xml")
local up_plugin_analysis = require("up_plugin_analysis")
local up_preset = require("up_preset")
local up_donor_data = require("up_donor_data")

local up_donor = {}

-- A container plugin (Reaktor) keeps its whole patch -- ensemble and snapshot --
-- inside the opaque plugin state chunk, and its program bank is empty until that
-- state is loaded. The replacement (Reaktor 6) rejects the old version's chunk,
-- so there is nothing the upgrade can synthesize. Instead it can borrow a
-- known-good chunk from a "donor" song that already has the ensemble loaded in
-- the replacement version, and inject that into each upgraded instance.
up_donor.path = nil

local _cache = { path = nil, entries = nil }

function up_donor.reset()
  _cache.path = nil
  _cache.entries = nil
end

function up_donor.set_path(path)
  if path ~= up_donor.path then
    up_donor.path = path
    up_donor.reset()
  end
end

-- Parse the donor .xrns (once) into its per-instrument Song.xml identities.
local function donor_entries()
  if not up_donor.path or up_donor.path == "" then return nil end
  if _cache.path == up_donor.path and _cache.entries then
    return _cache.entries
  end
  local ok, xml = pcall(function() return up_zip.extract(up_donor.path, "Song.xml") end)
  if not ok or type(xml) ~= "string" or xml == "" then
    _cache.path = up_donor.path
    _cache.entries = {}
    return _cache.entries
  end
  _cache.path = up_donor.path
  _cache.entries = up_song_xml.parse_instruments(xml) or {}
  return _cache.entries
end

-- Case-folded base name, so "Razor" and "Razor.rkplr" compare equal.
local function donor_ensemble_matches(entry, ensemble)
  if not ensemble or ensemble == "" then return false end
  local function base(name)
    local trimmed = name:match("^%s*(.-)%s*$")
    if trimmed == "" then return "" end
    return (trimmed:match("^(.-)%.%w+$") or trimmed):lower()
  end
  local wanted = base(ensemble)
  if wanted == "" then return false end
  local function matches(name)
    return type(name) == "string" and base(name) == wanted
  end
  return matches(entry.preset_name) or matches(entry.display_name)
end

-- Confirm a bundled chunk is for the requested ensemble before offering it, so a
-- Razor donor is never injected into a different (or unknown) Reaktor ensemble.
-- An unknown ensemble is not a match: the bundled state is ensemble-specific, so
-- it may only be used once the instance's ensemble is known to be the same.
local function bundled_matches(ensemble)
  if not ensemble or ensemble == "" then return false end
  local chunk = up_preset.decode_chunk(up_donor_data.chunk_b64)
  if not chunk then return false end
  local name = up_preset._extract_chunk_name(chunk)
  if not name or name == "" then return false end
  local function base(value)
    return ((value or ""):match("^(.-)%.%w+$") or (value or "")):lower()
  end
  return base(name) == base(ensemble)
end

-- Return the raw plugin state chunk of the first donor instrument in the given
-- plugin family (e.g. "native instruments: reaktor"), or nil. A configured donor
-- song takes precedence; otherwise the bundled donor state is used. When
-- `ensemble` is given, only a donor that actually holds that ensemble is
-- returned, so injecting it cannot replace the instance's patch with another.
function up_donor.chunk_for(family_base, ensemble)
  if type(family_base) ~= "string" or family_base == "" then return nil end
  local entries = donor_entries()
  if entries then
    for _, entry in pairs(entries) do
      if type(entry) == "table" and type(entry.preset_data) == "string"
        and entry.preset_data ~= "" and entry.display_name
        and donor_ensemble_matches(entry, ensemble) then
        local analysis = up_plugin_analysis.analyze_plugin(nil, entry.display_name)
        if up_plugin_analysis.family_base(analysis.base or analysis.product or "") == family_base then
          return entry.preset_data, entry.active_program
        end
      end
    end
  end
  if up_donor_data and up_donor_data.family == family_base and up_donor_data.chunk_b64
    and bundled_matches(ensemble) then
    return up_preset.decode_chunk(up_donor_data.chunk_b64), up_donor_data.active_program
  end
  return nil
end

return up_donor
