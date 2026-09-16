local up_preset = require("up_preset")
local up_plugin_analysis = require("up_plugin_analysis")

local up_swap = {}

-- True when the old and new plugins are the same product family (version aside),
-- e.g. Reaktor5 -> Reaktor6. Vendor prefixes are asymmetric (the live API may
-- report "Reaktor 6" without "Native Instruments"), so compare significant tokens
-- with subset in either direction rather than requiring identical stems.
local function same_family(old_analysis, new_analysis)
  if not old_analysis or not new_analysis then return false end
  local old_tokens = up_plugin_analysis.token_set(old_analysis.base or old_analysis.product or "")
  local new_tokens = up_plugin_analysis.token_set(new_analysis.base or new_analysis.product or "")
  if not next(old_tokens) or not next(new_tokens) then return false end
  return up_plugin_analysis.token_subset(old_tokens, new_tokens)
    or up_plugin_analysis.token_subset(new_tokens, old_tokens)
end

-- Capture the old plugin's exposed parameter values so we can re-apply them to
-- the replacement plugin as a best-effort "synthesized" preset when the native
-- preset chunk can't be transferred (e.g. across plugin formats). Only
-- automatable parameters are captured; internal/non-parameter state is skipped.
local function snapshot_parameters(device)
  local captured = {}
  if not device then return captured end
  local ok, parameters = pcall(function() return device.parameters end)
  if not ok or not parameters then return captured end
  for _, parameter in ipairs(parameters) do
    -- Only automatable parameters can be re-applied to the replacement; skip
    -- internal/non-parameter state.
    local ok_auto, is_automatable = pcall(function() return parameter.is_automatable end)
    if ok_auto and is_automatable then
      local ok_value, value = pcall(function() return parameter.value end)
      local ok_name, name = pcall(function() return parameter.name end)
      -- Skip parameters whose name can't be read: apply_parameter_values
      -- matches strictly by (non-empty) name, so nameless entries can never be
      -- re-applied and would only add noise/work.
      if ok_value and ok_name and type(name) == "string" and name ~= "" then
        captured[#captured + 1] = { name = name, value = value }
      end
    end
  end
  return captured
end

-- Re-apply captured parameter values onto the new device, matched strictly by
-- parameter name. Only automatable parameters are written. Returns the number
-- of parameters that were transferred.
local function apply_parameter_values(new_device, old_parameters)
  local ok_parameters, parameters = pcall(function() return new_device.parameters end)
  if not ok_parameters or not parameters then return 0 end
  local by_name = {}
  for index, parameter in ipairs(parameters) do
    local ok_name, name = pcall(function() return parameter.name end)
    if ok_name and type(name) == "string" and name ~= "" then
      by_name[name] = index
    end
  end
  local applied = 0
  for _, old_parameter in ipairs(old_parameters) do
    local parameter_index = by_name[old_parameter.name]
    if parameter_index then
      local target = parameters[parameter_index]
      local ok_auto, is_automatable = pcall(function() return target.is_automatable end)
      if ok_auto and is_automatable then
        local ok_set = pcall(function() target.value = old_parameter.value end)
        if ok_set then applied = applied + 1 end
      end
    end
  end
  return applied
end

-- Preserve plugin automation across a replacement. Renoise discards a device's
-- automation when the device is removed, so we rebind (track devices) or
-- re-create (instrument plugins) the automation onto the replacement device's
-- parameters, matched by name. All of this is best-effort and fully guarded: a
-- failure here must never abort the upgrade itself.

local function capture_automation(device, song)
  local captured = {}
  if not device or not song then return captured end
  local ok_parameters, parameters = pcall(function() return device.parameters end)
  if not ok_parameters or not parameters then return captured end
  for _, parameter in ipairs(parameters) do
    local ok_automation, automation = pcall(function() return song:automation(parameter) end)
    if ok_automation and automation and automation.is_automated then
      local ok_name, name = pcall(function() return parameter.name end)
      if ok_name and type(name) == "string" and name ~= "" then
        captured[name] = { parameter = parameter, automation = automation }
      end
    end
  end
  return captured
end

-- Track devices: both devices briefly coexist (new inserted at old_index, old
-- pushed to old_index+1), so we can rebind the live automation objects onto the
-- new device's same-named parameters before deleting the old device.
local function rebind_automation(captured, new_device)
  local count = 0
  if not new_device then return count end
  local ok_parameters, parameters = pcall(function() return new_device.parameters end)
  if not ok_parameters or not parameters then return count end
  local by_name = {}
  for _, parameter in ipairs(parameters) do
    local ok_name, name = pcall(function() return parameter.name end)
    if ok_name and type(name) == "string" and name ~= "" then by_name[name] = parameter end
  end
  for name, captured_entry in pairs(captured) do
    local new_parameter = by_name[name]
    if new_parameter then
      local ok = pcall(function() captured_entry.automation.device_parameter = new_parameter end)
      if ok then count = count + 1 end
    end
  end
  return count
end

-- Instrument plugins are replaced in place (load_plugin), so the old device is
-- gone by the time the new one exists. Snapshot the automation data and rebuild
-- it on the new device's same-named parameters.
local function capture_automation_data(device, song)
  local captured = {}
  if not device or not song then return captured end
  local ok_parameters, parameters = pcall(function() return device.parameters end)
  if not ok_parameters or not parameters then return captured end
  for _, parameter in ipairs(parameters) do
    local ok_automation, automation = pcall(function() return song:automation(parameter) end)
    if ok_automation and automation and automation.is_automated then
      local ok_name, name = pcall(function() return parameter.name end)
      if not (ok_name and type(name) == "string" and name ~= "") then name = nil end
      local data = { playback = automation.playback_mode }
      if automation.linked_device_parameter then
        local ok_linked, linked_name = pcall(function() return automation.linked_device_parameter.name end)
        data.linked = (ok_linked and type(linked_name) == "string" and linked_name ~= "") and linked_name or nil
      else
        local points = {}
        local ok_points, source_points = pcall(function() return automation.points end)
        if ok_points and source_points then
          for _, point in ipairs(source_points) do
            points[#points + 1] = { time = point.time, value = point.value }
          end
        end
        data.points = points
      end
      -- Only bindable-by-name entries are useful: restore_automation_data can
      -- only rebind by parameter name, so skip any parameter without a stable
      -- non-empty name (a numeric fallback key would be unreliable in a
      -- name-keyed map and could never be restored).
      if name then
        captured[name] = data
      end
    end
  end
  return captured
end

local function restore_automation_data(captured, new_device, song)
  local count = 0
  if not new_device or not song then return count end
  if not captured or type(captured) ~= "table" then return count end
  local ok_parameters, parameters = pcall(function() return new_device.parameters end)
  if not ok_parameters or not parameters then return count end
  local by_name = {}
  for _, parameter in ipairs(parameters) do
    local ok_name, name = pcall(function() return parameter.name end)
    if ok_name and type(name) == "string" and name ~= "" then by_name[name] = parameter end
  end
  for name, data in pairs(captured) do
    local new_parameter = by_name[name]
    if new_parameter then
      local ok_automation, new_automation = pcall(function() return song:automation(new_parameter) end)
      if ok_automation and new_automation then
        pcall(function() new_automation.playback_mode = data.playback end)
        if data.linked then
          local linked_parameter = by_name[data.linked]
          if linked_parameter then
            pcall(function() new_automation.linked_device_parameter = linked_parameter end)
          end
        else
          local points = data.points or {}
          local ok_set = pcall(function() new_automation.points = points end)
          if not ok_set then
            pcall(function() if new_automation.clear then new_automation:clear() end end)
            for _, point in ipairs(points) do
              pcall(function() new_automation:add_point_at(point.time, point.value) end)
            end
          end
        end
        count = count + 1
      end
    end
  end
  return count
end

-- Ordered names to try when selecting a preset/program in the replacement: the
-- preset/ensemble recovered from the plugin's own state first (e.g. Reaktor's
-- "Razor" ensemble), then the user's patch name (the live active preset or, for
-- a missing plugin, the instrument name). Trying the recovered ensemble first
-- means the replacement loads the right synth; the patch name that follows then
-- resolves within that ensemble. Blank names and duplicates are dropped.
local function preset_name_candidates(recovered_name, patch_name)
  local names = {}
  local seen = {}
  local function add(name)
    if type(name) == "string" then
      local trimmed = name:match("^%s*(.-)%s*$")
      if trimmed ~= "" and not seen[trimmed] then
        seen[trimmed] = true
        names[#names + 1] = trimmed
      end
    end
  end
  add(recovered_name)
  add(patch_name)
  return names
end

-- Match a wanted preset name against a plugin's bank entry. Plugin banks often
-- label entries with the preset file's extension (e.g. Reaktor's "Razor.rkplr")
-- while the name recovered from the plugin state is the extension-less base
-- ("Razor"), so exact equality misses. Compare exact first, then on the trimmed,
-- extension-stripped, case-folded base name so either spelling selects the entry.
-- Also ignore a trailing numeric suffix, because Renoise instrument names carry
-- one ("Dark Dreams 1") while the Reaktor snapshot does not ("Dark Dreams").
local function preset_name_matches(wanted, candidate)
  if type(wanted) ~= "string" or type(candidate) ~= "string" then return false end
  if wanted == candidate then return true end
  local function base(name)
    local trimmed = name:match("^%s*(.-)%s*$")
    if trimmed == "" then return "" end
    return (trimmed:match("^(.-)%.%w+$") or trimmed):lower()
  end
  local function strip_index(name)
    return (name:gsub("%s+%d+$", ""))
  end
  local wanted_base = base(wanted)
  if wanted_base == "" then return false end
  local candidate_base = base(candidate)
  return wanted_base == candidate_base
    or strip_index(wanted_base) == strip_index(candidate_base)
end

-- Load the first of `preset_names` that exists in the new plugin's preset/program
-- bank. The names are tried in order and the preset list is re-read after each
-- successful load, so a container plugin whose bank changes once an ensemble is
-- selected (e.g. Reaktor: selecting the "Razor" ensemble replaces the program
-- list with that ensemble's snapshots) can then resolve the patch name that
-- follows it. A pass that changes the active program triggers another pass, so
-- the patch is still found when the ensemble name happens to be tried first
-- (or vice versa). Returns true when at least one preset was loaded.
local function load_matching_preset(new_device, preset_names)
  if type(preset_names) ~= "table" then return false end
  local function active_index()
    local ok_active, active = pcall(function() return new_device.active_preset end)
    return ok_active and active or nil
  end
  local loaded = false
  for _ = 1, #preset_names + 1 do
    local before = active_index()
    for _, wanted in ipairs(preset_names) do
      local ok_presets, presets = pcall(function() return new_device.presets end)
      if ok_presets and presets then
        for index, preset_name in ipairs(presets) do
          if preset_name_matches(wanted, preset_name) then
            local ok_set = pcall(function() new_device.active_preset = index end)
            if ok_set then loaded = true end
            break
          end
        end
      end
    end
    -- Stop once a full pass no longer moves the active program: the bank has
    -- stabilised (or nothing matched), so another pass cannot find anything new.
    if active_index() == before then break end
  end
  return loaded
end

-- Try to move the old plugin's state onto the newly inserted device.
-- Returns ("parameters"|"name"|"params") on success, or (nil, reason) on
-- failure. A parameter-chunk transplant only works within the SAME plugin
-- format, so when the source and target protocols differ we skip it (the chunk
-- is inherently incompatible, e.g. VST<->VST3). In that cross-format case we
-- load a same-named factory preset as a base (so unmapped parameters keep a
-- sensible default), then overlay the old plugin's captured parameter values
-- (matched by name) on top -- which is what actually carries the user's tweaks
-- such as Mix. If no parameters map, we keep the loaded preset; otherwise we
-- return the synthesized result.
local function transfer_state(new_device, old_data, preset_names, same_format, old_parameters, old_active_preset)
  if old_data and old_data ~= "" and same_format then
    local ok = pcall(function() new_device.active_preset_data = old_data end)
    if ok then
      local ok_written, written = pcall(function() return new_device.active_preset_data end)
      if ok_written and written and written ~= "" then
        return "parameters"
      end
    end
  end

  -- Establish a base state from a same-named factory preset (if one exists in
  -- the new plugin). This gives unmapped parameters a sensible starting point.
  local preset_loaded = load_matching_preset(new_device, preset_names)

  -- Container plugins (Reaktor and friends) keep the patch as a program number in
  -- a bank supplied by the loaded ensemble. Same-family versions share that
  -- numbering (Reaktor 5 -> 6: program 48 is the same snapshot), so after name
  -- matching has loaded the ensemble, restore the exact program number. Only
  -- containers reach here (callers pass old_active_preset only then), so a flat
  -- factory bank (e.g. Pro-Q) is never clobbered. Read the value back to be sure
  -- the plugin accepted it.
  if old_active_preset and old_active_preset > 0 then
    local ok_set = pcall(function() new_device.active_preset = old_active_preset end)
    if ok_set then
      local ok_get, got = pcall(function() return new_device.active_preset end)
      if ok_get and got == old_active_preset then
        preset_loaded = true
      end
    end
  end

  -- Overlay the old plugin's saved parameter values on top of the base. This is
  -- what actually carries the user's tweaks (e.g. Mix) across formats, since it
  -- applies the captured values rather than resetting to a factory default.
  if old_parameters and #old_parameters > 0 then
    local applied = apply_parameter_values(new_device, old_parameters)
    if applied > 0 then
      return "params", tostring(applied)
    end
  end

  -- If we couldn't map any parameters but did load a base preset, keep it.
  if preset_loaded then
    return "name"
  end

  return nil, "no transfer method succeeded"
end

function up_swap.swap_track_device(song, record, candidate)
  local track = song.tracks[record.track_index]
  local old_index = record.device_index
  local old_device = track.devices[old_index]
  local captured_automation = capture_automation(old_device, song)
  local old_data = nil
  local ok_preset_data, preset_data = pcall(function() return old_device.active_preset_data end)
  if ok_preset_data then
    old_data = preset_data
  end
  local old_parameters = snapshot_parameters(old_device)
  local old_preset_name = up_preset.extract_name(old_device)
  local preset_names = preset_name_candidates(record.active_preset_name, old_preset_name)
  local old_active = nil
  local ok_active, is_active = pcall(function() return old_device.is_active end)
  if ok_active then old_active = is_active end
  local was_broken = record.broken
  local old_protocol = record.analysis and record.analysis.protocol
  local same_format = (old_protocol and old_protocol == candidate.protocol)
  -- The program number is only meaningful for a same-family container plugin whose
  -- patch lives in an external ensemble (Reaktor): a "file://" reference in the old
  -- chunk, or one recovered from the song for a missing plugin.
  local container = (old_data and old_data:find("file://") ~= nil) or record.ensemble_preset
  local old_active_preset = (same_family(record.analysis, candidate) and container)
    and record.active_preset or nil

  -- See swap_instrument: skip a candidate that is already the loaded device.
  if record.device_path and record.device_path == candidate.path then
    return { status = "up-to-date", new_path = candidate.path,
      detail = "plugin already current" }
  end

  local ok_insert, inserted_or_error = pcall(function()
    return track:insert_device_at(candidate.path, old_index)
  end)
  if not ok_insert or not inserted_or_error then
    return {
      status = "skipped-transfer-rejected",
      new_path = candidate.path,
      detail = "insert failed: " .. tostring(inserted_or_error),
    }
  end
  local new_device = inserted_or_error
  local automation_count = rebind_automation(captured_automation, new_device)
  local method, err = transfer_state(new_device, old_data, preset_names, same_format, old_parameters, old_active_preset)
  -- Set is_active last: transfer_state may load a base preset, which can reset
  -- the device to active; applying it afterwards keeps the old bypass state.
  if old_active ~= nil then
    pcall(function() new_device.is_active = old_active end)
  end
  if method then
    pcall(function() track:delete_device_at(old_index + 1) end)
    local status = method == "parameters" and "upgraded-with-parameters"
      or method == "name" and "upgraded-name-matched-preset"
      or "upgraded-parameter-synth"
    return {
      status = status,
      new_path = candidate.path,
      method = method,
      detail = (automation_count and automation_count > 0)
        and ("automation preserved: " .. automation_count .. " parameter(s)")
        or nil,
    }
  end
  -- The new plugin is inserted and valid. The upgrade (protocol change) still
  -- happens; only the old state couldn't be carried over. Remove the old device
  -- and keep the new one at default state rather than silently reverting.
  pcall(function() track:delete_device_at(old_index + 1) end)
  return {
    status = "upgraded-default",
    new_path = candidate.path,
    detail = (was_broken and "old plugin was broken; " or "preset not transferred: ") .. tostring(err),
  }
end

function up_swap.swap_instrument(song, record, candidate)
  local instrument = song.instruments[record.instrument_index]
  local plugin_properties = instrument.plugin_properties
  local old_data = nil
  local old_parameters = {}
  local old_preset_name = nil
  local old_active = nil
  local captured_automation = {}
  if record.plugin_loaded and plugin_properties.plugin_device then
    local ok_preset_data, preset_data = pcall(function() return plugin_properties.plugin_device.active_preset_data end)
    if ok_preset_data then
      old_data = preset_data
    end
    old_parameters = snapshot_parameters(plugin_properties.plugin_device)
    old_preset_name = up_preset.extract_name(plugin_properties.plugin_device)
    local ok_active, is_active = pcall(function() return plugin_properties.plugin_device.is_active end)
    if ok_active then old_active = is_active end
    captured_automation = capture_automation_data(plugin_properties.plugin_device, song)
  end
  -- Missing plugin: the live API exposes no preset, but the instrument name is
  -- usually the user's patch/preset. The replacement plugin keeps its own presets
  -- (stored in the plugin, not the song), so try to load it by that name in the
  -- newly inserted plugin. Extract the parenthetical label when present (e.g.
  -- "VST: Reaktor5 (Make It Bright)" -> "Make It Bright") so it can match a real
  -- factory preset; otherwise only treat the name as a preset when it isn't a
  -- "PROTO:"-prefixed plugin identity.
  if not old_preset_name and record.broken and record.instrument_name and record.instrument_name ~= "" then
    local parenthetical_label = record.instrument_name:match("%(([^()]*)%)$")
    -- Renoise appends an empty "()" to some broken instrument names; treat the
    -- parenthetical as a preset only when it holds non-whitespace text (and trim
    -- it), otherwise the empty string would be kept as a truthy "real" preset.
    if parenthetical_label and parenthetical_label:match("%S") then
      old_preset_name = parenthetical_label:match("^%s*(.-)%s*$")
    elseif not record.instrument_name:match("^%s*[%w%+%-]+%s*:%s*") then
      old_preset_name = record.instrument_name
    end
  end
  -- Prefer the ensemble/preset recovered from the plugin's own state (e.g. the
  -- "Razor" ensemble in a missing Reaktor) over the instrument-name patch, so the
  -- replacement selects the right synth before its patch.
  local preset_names = preset_name_candidates(record.active_preset_name, old_preset_name)
  local was_broken = record.broken
  local old_protocol = record.analysis and record.analysis.protocol
  local same_format = (old_protocol and old_protocol == candidate.protocol)
  -- The program number is only meaningful for a same-family container plugin whose
  -- patch lives in an external ensemble (Reaktor): a "file://" reference in the old
  -- chunk, or one recovered from the song for a missing plugin.
  local container = (old_data and old_data:find("file://") ~= nil) or record.ensemble_preset
  local old_active_preset = (same_family(record.analysis, candidate) and container)
    and record.active_preset or nil

  -- No-op upgrade: the candidate is the plugin that is already loaded at this
  -- instrument. Reloading it (via load_plugin) is wasted work and, for heavy
  -- synths, can exceed Renoise's script-time budget and trip the "script busy"
  -- watchdog. The instrument is already current, so skip it.
  if record.device_path and record.device_path == candidate.path then
    return { status = "up-to-date", new_path = candidate.path,
      detail = "plugin already current" }
  end

  local ok_load, loaded = pcall(function() return plugin_properties:load_plugin(candidate.path) end)
  if not ok_load or not loaded then
    return {
      status = "skipped-transfer-rejected",
      new_path = candidate.path,
      detail = "load_plugin failed: " .. tostring(loaded),
    }
  end
  local ok_device, new_device = pcall(function() return plugin_properties.plugin_device end)
  new_device = (ok_device and new_device) or nil
  if old_active ~= nil and new_device then
    pcall(function() new_device.is_active = old_active end)
  end
  local automation_count = restore_automation_data(captured_automation, new_device, song)
  if not new_device then
    if record.device_path then
      pcall(function() plugin_properties:load_plugin(record.device_path) end)
    end
    return {
      status = "skipped-transfer-rejected",
      new_path = candidate.path,
      detail = "new plugin device unavailable after load",
    }
  end
  local method, err = transfer_state(new_device, old_data, preset_names, same_format, old_parameters, old_active_preset)
  if method then
    local status = method == "parameters" and "upgraded-with-parameters"
      or method == "name" and "upgraded-name-matched-preset"
      or "upgraded-parameter-synth"
    return {
      status = status,
      new_path = candidate.path,
      method = method,
      detail = (automation_count and automation_count > 0)
        and ("automation preserved: " .. automation_count .. " parameter(s)")
        or nil,
    }
  end
  -- load_plugin already replaced the instrument plugin in place, so the upgrade
  -- is effective; only the old state couldn't be carried over.
  return {
    status = "upgraded-default",
    new_path = candidate.path,
    detail = (was_broken and "old plugin was broken; " or "preset not transferred: ") .. tostring(err),
  }
end

return up_swap
