-- Tests for up_swap: the actual plugin replacement (track device + instrument
-- plugin), preset/parameter/automation transfer, and the up-to-date / rejected
-- / error branches.

section("up_swap.swap_instrument handles missing (unloaded) plugin")
do
  -- A missing plugin has no live device, so captured_auto would be nil; this must
  -- not crash on pairs(nil) in restore_automation_data.
  local new_dev = { is_active = true, active_preset_data = "", presets = {}, parameters = {} }
  local pp = {
    plugin_loaded = false,
    plugin_device = nil,
    load_plugin = function(self)
      self.plugin_device = new_dev
      return true
    end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = {
    kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "VST: Kick - Nicky Romero ()", analysis = { protocol = "VST" }, device_path = nil,
  }
  local candidate = { path = "/P/Kick2.vst" }
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  if not ok then print("SWAP ERROR:", tostring(res)) end
  check(ok, "swap_instrument does not crash on a missing plugin")
  check(ok and res and res.status ~= nil, "swap_instrument returns a status for a missing plugin")
end

section("up_swap.swap_instrument skips an already-current plugin")
do
  -- When the auto-selected candidate is the plugin already loaded at an instrument,
  -- reloading it via load_plugin is wasted work and, for heavy synths, can exceed
  -- Renoise's script-time budget and trip the "script busy" watchdog. The swap
  -- must be skipped (status up-to-date) instead of reloading the same plugin.
  local captured_count = 0
  local new_dev = { is_active = true, active_preset_data = "", presets = {}, parameters = {} }
  local pp = {
    plugin_loaded = true,
    plugin_device = new_dev,
    load_plugin = function(self, _path)
      captured_count = captured_count + 1
      self.plugin_device = new_dev
      return true
    end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = {
    kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "LD SidMon", analysis = { protocol = "VST" }, device_path = "/P/Sylenth1.vst",
  }
  local candidate = { path = "/P/Sylenth1.vst" }
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok, "swap_instrument handles an already-current plugin")
  check(ok and res and res.status == "up-to-date", "already-current plugin is skipped (no reload)")
  check(captured_count == 0, "load_plugin was NOT called for an already-current plugin")
end

section("up_swap.swap_instrument uses parenthetical label as preset for broken plugins")
do
  -- For a missing/recovered plugin named "VST: Reaktor5 (Make It Bright)", the
  -- parenthetical is the real preset; it must be extracted (not the full identity)
  -- so it can match a factory preset on the replacement plugin.
  local new_dev = {
    is_active = true, active_preset_data = "", presets = { "Make It Bright", "Other" }, parameters = {} }
  local pp = {
    plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "VST: Reaktor5 (Make It Bright)", analysis = { protocol = "VST" }, device_path = nil }
  local candidate = { path = "/P/Reaktor6.vst", protocol = "VST" }
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-name-matched-preset",
    "broken plugin's parenthetical preset name matches a factory preset")
end

section("up_swap.swap_instrument ignores an empty () in a broken instrument name")
do
  -- Renoise appends an empty "()" to some broken instrument names. The empty
  -- parenthetical must NOT be kept as a (truthy) preset name; the full name
  -- should fall through as the preset instead.
  local new_dev = {
    is_active = true, active_preset_data = "", presets = { "My Song ()", "Other" }, parameters = {} }
  local pp = {
    plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "My Song ()", analysis = { protocol = "VST" }, device_path = nil }
  local candidate = { path = "/P/Reaktor6.vst", protocol = "VST" }
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-name-matched-preset",
    "empty parenthetical does not shadow the real preset name")
end

section("up_swap.swap_instrument uses a healthy plugin's preset label")
do
  -- Renoise renames an instrument to "VST: Massive (Acid Raw)" when that preset
  -- is selected. Massive exposes no program bank, but the label in the
  -- instrument name (and therefore Song.xml) is still the host-visible preset
  -- name and must be used when the replacement does expose a matching preset.
  local new_dev = {
    is_active = true, active_preset_data = "", presets = { "Acid Raw", "Other" }, parameters = {} }
  local pp = {
    plugin_loaded = true,
    plugin_device = { device_path = "/P/Massive.au", name = "AU: Native Instruments: Massive",
      active_preset_data = "", presets = {}, parameters = {} },
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "VST: Massive (Acid Raw)",
    analysis = analyze("VST: Native Instruments: Massive", "/P/Massive.vst", "VST"), device_path = nil }
  local candidate = analyze("AU: Native Instruments: Massive", "/P/Massive.au", "AU")
  candidate.path = "/P/Massive.au"
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-name-matched-preset",
    "the parenthetical preset label from a healthy instrument is used")
  check(new_dev.active_preset == 1, "the Acid Raw preset is selected by name")
end

section("up_swap.swap_instrument selects the recovered Reaktor ensemble")
do
  -- A missing Reaktor exposes no live preset, but its loaded ensemble ("Razor")
  -- is recovered from Song.xml into active_preset_name. The replacement must
  -- select that ensemble (not only try the instrument-name patch), otherwise the
  -- new Reaktor6 instance opens without Razor loaded. Reaktor's bank labels the
  -- entry with its file extension ("Razor.rkplr"), so the match must ignore it.
  local new_dev = {
    is_active = true, active_preset_data = "", presets = { "Razor.rkplr", "Other.rkplr" }, parameters = {} }
  local pp = {
    plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "Dark Dreams 1", active_preset_name = "Razor",
    analysis = { protocol = "AU" }, device_path = nil }
  local candidate = { path = "/P/Reaktor6.au", protocol = "AU" }
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok, "swap_instrument handles a recovered Reaktor ensemble")
  check(ok and res and res.status == "upgraded-name-matched-preset",
    "recovered ensemble name matches an extension-bearing program")
  check(new_dev.active_preset == 1, "replacement selects the recovered Razor.rkplr ensemble")
end

section("up_swap.swap_instrument selects the ensemble then its patch")
do
  -- Reaktor's program bank changes once an ensemble is selected: loading "Razor"
  -- exposes that ensemble's snapshots, so the user's patch ("Dark Dreams 1") can
  -- be resolved too. The preset list must be re-read after each load so both the
  -- ensemble and the old preset end up selected. Bank entries carry file
  -- extensions, while the recovered/instrument names do not.
  local state = { active_preset = 0, selected = {} }
  local new_dev = setmetatable({ is_active = true, active_preset_data = "", parameters = {} }, {
    __index = function(_, key)
      if key == "active_preset" then return state.active_preset end
      if key == "presets" then
        if state.active_preset == 0 then return { "Razor.rkplr", "Other Ensemble.rkplr" } end
        return { "Bright Dreams.nrkt", "Dark Dreams 1.nrkt" }
      end
      return nil
    end,
    __newindex = function(_, key, value)
      if key == "active_preset" then
        state.active_preset = value
        state.selected[#state.selected + 1] = value
      else
        rawset(_, key, value)
      end
    end,
  })
  local pp = {
    plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "Dark Dreams 1", active_preset_name = "Razor",
    analysis = { protocol = "AU" }, device_path = nil }
  local candidate = { path = "/P/Reaktor6.au", protocol = "AU" }
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-name-matched-preset",
    "replacement loads the ensemble and then the patch")
  check(state.selected[1] == 1, "the Razor ensemble is selected first")
  check(state.selected[2] == 2, "the old patch within Razor is selected next")
  check(new_dev.presets[state.active_preset] == "Dark Dreams 1.nrkt",
    "the active program is the old patch")
end

section("up_swap.swap_instrument resolves the patch when the bank loads in stages")
do
  -- A missing Reaktor reports the ensemble ("Razor") and the user's patch as the
  -- instrument name ("Dark Dreams 1"). The candidate order puts the ensemble first;
  -- selecting it replaces the bank with the ensemble's snapshots, and a second pass
  -- must then resolve the patch (whose bank name lacks the " 1" suffix).
  local snapshots = {}
  for i = 1, 60 do snapshots[i] = "Snap " .. i end
  snapshots[48] = "Dark Dreams"
  local state = { active_preset = 0 }
  local new_dev = setmetatable({ is_active = true, parameters = {} }, {
    __index = function(_, key)
      if key == "active_preset" then return state.active_preset end
      if key == "active_preset_data" then return "" end
      if key == "presets" then
        if state.active_preset == 0 then return { "Razor.rkplr" } end
        return snapshots
      end
      return nil
    end,
    __newindex = function(_, key, value)
      if key == "active_preset" then state.active_preset = value
      else rawset(_, key, value) end
    end,
  })
  local pp = { plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _p) self.plugin_device = new_dev; return true end }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "Dark Dreams 1", active_preset_name = "Razor",
    analysis = { protocol = "AU" }, device_path = nil }
  local candidate = { path = "/P/Reaktor6.vst3", protocol = "VST3" }
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-name-matched-preset",
    "the patch is found after the ensemble populates the bank")
  check(state.active_preset == 48, "the Dark Dreams snapshot is active")
end

section("up_swap.swap_instrument restores the active program number")
do
  -- Reaktor 5 and 6 share the program bank: program 48 is the same snapshot. When
  -- the snapshot's name can't be matched (it lives only in the old opaque chunk)
  -- the recorded program number is restored instead, after the ensemble is loaded.
  -- No donor is used here, so the name/program fallback path is exercised.
  local real_chunk_for = up_donor.chunk_for
  up_donor.chunk_for = function() return nil end
  local snapshots = {}
  for i = 1, 60 do snapshots[i] = "Snap " .. i end
  local state = { active_preset = 0 }
  local new_dev = setmetatable({ is_active = true, active_preset_data = "", parameters = {} }, {
    __index = function(_, key)
      if key == "active_preset" then return state.active_preset end
      if key == "presets" then
        if state.active_preset == 0 then return { "Razor.rkplr" } end
        return snapshots
      end
      return nil
    end,
    __newindex = function(_, key, value)
      if key == "active_preset" then state.active_preset = value
      else rawset(_, key, value) end
    end,
  })
  local pp = { plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _p) self.plugin_device = new_dev; return true end }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "Dark Dreams 1", active_preset_name = "Razor", active_preset = 48,
    ensemble_preset = true,
    analysis = analyze("AU: Native Instruments: Reaktor5", nil, "AU"), device_path = nil }
  local candidate = analyze("VST3: Native Instruments: Reaktor 6", "/P/Reaktor6.vst3", "VST3")
  candidate.path = "/P/Reaktor6.vst3"
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-name-matched-preset",
    "the ensemble is loaded and the program number restored")
  check(state.active_preset == 48, "the recorded program number (48) is restored")
  up_donor.chunk_for = real_chunk_for
end

section("up_swap.swap_instrument does not carry a program number to a flat bank")
do
  -- A normal plugin (no ensemble file) has a flat factory bank, so the old
  -- program number may mean a different preset in the new version. The name match
  -- must win and the number must not be applied.
  local new_dev = { is_active = true, active_preset_data = "", presets = { "Some Preset" }, parameters = {} }
  local pp = { plugin_loaded = true,
    plugin_device = { device_path = "/P/ProQ2.vst3", name = "VST3: FabFilter Pro-Q 2",
      active_preset = 5, presets = { "Some Preset" }, active_preset_data = "", parameters = {} },
    load_plugin = function(self, _p) self.plugin_device = new_dev; return true end }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "ProQ", active_preset_name = "Some Preset", active_preset = 5,
    analysis = analyze("VST3: FabFilter Pro-Q 2", "/P/ProQ2.vst3", "VST3"), device_path = "/P/ProQ2.vst3" }
  local candidate = analyze("VST3: FabFilter Pro-Q 3", "/P/ProQ3.vst3", "VST3")
  candidate.path = "/P/ProQ3.vst3"
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-name-matched-preset",
    "the flat-bank preset is matched by name")
  check(new_dev.active_preset == 1, "the name match is kept, not the old program number")
end

section("up_swap.swap_instrument matches a bank name that lacks the index suffix")
do
  -- Renoise instrument names carry a numeric suffix ("Dark Dreams 1") while the
  -- Reaktor snapshot does not ("Dark Dreams"); the lookup must ignore the suffix.
  local new_dev = { is_active = true, active_preset_data = "", presets = { "Dark Dreams" }, parameters = {} }
  local pp = { plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _p) self.plugin_device = new_dev; return true end }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "Dark Dreams 1", analysis = { protocol = "AU" }, device_path = nil }
  local candidate = { path = "/P/Reaktor6.au", protocol = "VST3" }
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-name-matched-preset",
    "the suffix-less snapshot name is matched")
  check(new_dev.active_preset == 1, "the Dark Dreams snapshot is selected")
end

section("up_swap.swap_instrument injects a recovered chunk into the XML wrapper")
do
  -- active_preset_data is Renoise's XML wrapper; a chunk recovered from Song.xml
  -- is the raw plugin binary, so it must be base64-injected into the wrapper's
  -- <ParameterChunk> rather than assigned directly (which Renoise rejects). No
  -- donor, so the recovered chunk itself is what gets injected.
  local real_chunk_for = up_donor.chunk_for
  up_donor.chunk_for = function() return nil end
  local raw = "\0\0file://localhost/Users/Shared/Razor/Razor.rkplr\0\0"
  local wrapper = '<?xml version="1.0" encoding="UTF-8"?>\n'
    .. '<FilterDevicePreset doc_version="14"><DeviceSlot type="AudioPluginDevice">'
    .. '<PluginType>VST3</PluginType><PluginIdentifier>5653544E695236</PluginIdentifier>'
    .. '<ParameterChunk><![CDATA[]]></ParameterChunk></DeviceSlot></FilterDevicePreset>'
  local new_dev = { is_active = true, active_preset_data = wrapper, presets = {}, parameters = {} }
  local pp = { plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _p) self.plugin_device = new_dev; return true end }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "Dark Dreams 1", active_preset_name = "Razor", active_preset = 48,
    active_preset_data = raw, ensemble_preset = true,
    analysis = analyze("AU: Native Instruments: Reaktor5", nil, "AU"), device_path = nil }
  local candidate = analyze("VST3: Native Instruments: Reaktor 6", "/P/Reaktor6.vst3", "VST3")
  candidate.path = "/P/Reaktor6.vst3"
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-with-parameters",
    "the recovered chunk is injected and counts as a transfer")
  check(new_dev.active_preset_data:find("<ParameterChunk><![CDATA[", 1, true) ~= nil
    and #new_dev.active_preset_data > #wrapper,
    "the raw chunk is base64-injected into the wrapper's ParameterChunk")
  check(new_dev.active_preset_data:find(up_preset.encode_chunk(raw), 1, true) ~= nil,
    "the injected base64 is the recovered chunk")
  up_donor.chunk_for = real_chunk_for
end

section("up_swap detects a loaded Reaktor device from its XML wrapper")
do
  -- A loaded Reaktor device exposes active_preset_data as Renoise's XML wrapper,
  -- whose base64 <ParameterChunk> hides the ensemble reference. Searching the
  -- wrapper text for "file://" never matches, so the container must be detected
  -- from the decoded chunk (and the donor path taken) -- otherwise a loaded
  -- Reaktor 5 -> 6 upgrade silently falls back to the flat-plugin path.
  local function utf16(s)
    local out = {}
    for i = 1, #s do out[#out + 1] = s:sub(i, i) .. "\0" end
    return table.concat(out)
  end
  local ensemble = "\1\2\3" .. utf16("file://Razor.rkplr") .. "\0\0"
  local function wrapper(chunk)
    return '<?xml version="1.0"?><FilterDevicePreset><DeviceSlot><ParameterChunk><![CDATA['
      .. up_preset.encode_chunk(chunk) .. ']]></ParameterChunk></DeviceSlot></FilterDevicePreset>'
  end
  local donor_raw = "\0\0file://Razor.rkplr\0\0"
  local real_chunk_for = up_donor.chunk_for
  local donor_calls = {}
  up_donor.chunk_for = function(family, name)
    donor_calls[#donor_calls + 1] = { family = family, name = name }
    return donor_raw
  end
  local old_dev = { is_active = true, active_preset_data = wrapper(ensemble), parameters = {},
    active_preset = 48, presets = {} }
  local new_dev = { is_active = true, active_preset_data = wrapper(ensemble), parameters = {},
    presets = {} }
  local pp = { plugin_loaded = true, plugin_device = old_dev,
    load_plugin = function(self, _p) self.plugin_device = new_dev; return true end }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "Dark Dreams 1", active_preset_name = "Dark Dreams", active_preset = 48,
    analysis = analyze("VST: Native Instruments: Reaktor5", nil, "VST"), device_path = "/P/Reaktor5.vst" }
  local candidate = analyze("VST3: Native Instruments: Reaktor 6", "/P/Reaktor6.vst3", "VST3")
  candidate.path = "/P/Reaktor6.vst3"
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-with-parameters",
    "the donor chunk is injected for a loaded Reaktor container")
  check(#donor_calls == 1 and donor_calls[1].name == "Razor",
    "the donor lookup uses the chunk's ensemble, not the active snapshot name")
  up_donor.chunk_for = real_chunk_for
end

section("up_swap does not cross-format transplant a non-Reaktor container")
do
  -- Kontakt is file-backed too, but its chunk is not portable across major
  -- versions like Reaktor's, so a cross-format (VST -> VST3) upgrade must fall
  -- back to the name/parameter path instead of injecting the incompatible chunk.
  local function utf16(s)
    local out = {}
    for i = 1, #s do out[#out + 1] = s:sub(i, i) .. "\0" end
    return table.concat(out)
  end
  local raw = "\1\2" .. utf16("file://Legato.nki") .. "\0\0"
  local function wrapper(chunk)
    return '<?xml version="1.0"?><FilterDevicePreset><DeviceSlot><ParameterChunk><![CDATA['
      .. up_preset.encode_chunk(chunk) .. ']]></ParameterChunk></DeviceSlot></FilterDevicePreset>'
  end
  local new_dev = { is_active = true, active_preset_data = wrapper(raw), parameters = {},
    presets = {}, active_preset = 0 }
  local old_dev = { is_active = true, active_preset_data = wrapper(raw), parameters = {},
    presets = {} }
  local pp = { plugin_loaded = true, plugin_device = old_dev,
    load_plugin = function(self, _p) self.plugin_device = new_dev; return true end }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "Legato", analysis = analyze("VST: Native Instruments: Kontakt6", nil, "VST"),
    device_path = "/P/Kontakt6.vst" }
  local candidate = analyze("VST3: Native Instruments: Kontakt 7", "/P/Kontakt7.vst3", "VST3")
  candidate.path = "/P/Kontakt7.vst3"
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status ~= "upgraded-with-parameters",
    "a non-Reaktor container is not chunk-transplanted across formats")
end

section("up_swap does not use the Reaktor path for a cross-family swap")
do
  -- A Kontakt -> Reaktor upgrade is not same-family, so it must not inject the
  -- Reaktor donor chunk or drive the Reaktor bank scan on an unrelated plugin.
  local real_chunk_for = up_donor.chunk_for
  local donor_calls = 0
  up_donor.chunk_for = function() donor_calls = donor_calls + 1; return "\1\2donor" end
  local new_dev = { is_active = true, active_preset_data = "", parameters = {},
    presets = { "Reaktor Init" }, active_preset = 0 }
  local old_dev = { is_active = true, active_preset_data = "", parameters = {}, presets = {} }
  local pp = { plugin_loaded = true, plugin_device = old_dev,
    load_plugin = function(self, _p) self.plugin_device = new_dev; return true end }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "Legato", ensemble_preset = true, active_preset = 3,
    analysis = analyze("VST: Native Instruments: Kontakt6", nil, "VST"),
    device_path = "/P/Kontakt6.vst" }
  local candidate = analyze("VST3: Native Instruments: Reaktor 6", "/P/Reaktor6.vst3", "VST3")
  candidate.path = "/P/Reaktor6.vst3"
  local ok = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok, "the cross-family swap completes")
  check(donor_calls == 0, "the Reaktor donor is not consulted for a cross-family swap")
  up_donor.chunk_for = real_chunk_for
end

section("coverage: up_swap.swap_track_device upgrades a track plugin")
do
  local track = {
    devices = { [1] = {}, [2] = { is_active = true, active_preset_data = "", parameters = {} } },
    insert_device_at = function(self, _path, idx)
      local dev = { is_active = true, active_preset_data = "", presets = {}, parameters = {} }
      table.insert(self.devices, idx, dev); return dev
    end,
    delete_device_at = function(self, idx) table.remove(self.devices, idx) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/Sylenth1.vst", device_name = "VST: Lennardigital Sylenth1",
    analysis = analyze("VST: Lennardigital Sylenth1", "/P/Sylenth1.vst", "VST") }
  local candidate = { name = "Sylenth1", protocol = "VST", path = "/P/Sylenth1-VST3.vst" }
  local ok, res = pcall(function() return up_swap.swap_track_device(song, rec, candidate) end)
  check(ok and res and res.status ~= nil, "swap_track_device upgrades the track plugin")
end

section("coverage: up_swap.swap_track_device up-to-date + rejected")
do
  local track = {
    devices = { [1] = {}, [2] = { is_active = true, active_preset_data = "", parameters = {} } },
    insert_device_at = function(self, _path, idx)
      local dev = { is_active = true, active_preset_data = "", presets = {}, parameters = {} }
      table.insert(self.devices, idx, dev); return dev
    end,
    delete_device_at = function(self, idx) table.remove(self.devices, idx) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }

  -- Candidate is the plugin already loaded at this device: skip (up-to-date).
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/Sylenth1.vst", device_name = "VST: Lennardigital Sylenth1",
    analysis = analyze("VST: Lennardigital Sylenth1", "/P/Sylenth1.vst", "VST") }
  local same = up_swap.swap_track_device(song, rec, { name = "Sylenth1", protocol = "VST",
    path = "/P/Sylenth1.vst" })
  check(same and same.status == "up-to-date", "swap_track_device skips an already-current plugin")

  -- insert_device_at failing yields a transfer-rejected status (no crash).
  local track2 = {
    devices = { [1] = {}, [2] = { is_active = true, active_preset_data = "", parameters = {} } },
    insert_device_at = function() return nil end,
    delete_device_at = function() end,
  }
  local song2 = { tracks = { track2 }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rejected = up_swap.swap_track_device(song2, rec, { name = "Sylenth1", protocol = "VST",
    path = "/P/Sylenth1-VST3.vst" })
  check(rejected and rejected.status == "skipped-transfer-rejected",
    "swap_track_device reports rejected when insert fails")
end

section("coverage: up_swap.swap_instrument transfer-state branches")
do
  local mkrec = function(proto)
    return { kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
      instrument_name = "Old", device_path = "/P/MB.vst3", device_name = "VST3: Pro-MB",
      analysis = analyze("VST3: Pro-MB", "/P/MB.vst3", proto or "VST3") }
  end

  -- Same-format preset chunk transfer ("parameters"): same product AND version.
  local new_dev_p = { is_active = true, active_preset_data = "", presets = {}, parameters = {} }
  local pp_p = { plugin_loaded = true,
    plugin_device = { device_path = "/P/MB.vst3", name = "VST3: Pro-MB",
      active_preset_data = "<PresetName>Old</PresetName>", parameters = {} },
    load_plugin = function(self, _p) self.plugin_device = new_dev_p; return true end }
  local song_p = { instruments = { { plugin_properties = pp_p } }, tracks = {},
    automation = function() return { is_automated = false } end }
  local okp, rp = pcall(function() return up_swap.swap_instrument(song_p, mkrec("VST3"),
    analyze("VST3: Pro-MB", "/P/MB-reinstall.vst3", "VST3")) end)
  check(okp and rp, "swap_instrument transfers same-format preset chunk")
  check(okp and rp and rp.status == "upgraded-with-parameters", "same-format chunk transfer -> parameters")

  -- Factory-preset base name match ("name").
  local new_dev_n = { is_active = true, active_preset_data = "", presets = { "Old" }, parameters = {} }
  local pp_n = { plugin_loaded = true,
    plugin_device = { device_path = "/P/MB.vst3", name = "VST3: Pro-MB",
      active_preset = 1, presets = { "Old" }, active_preset_data = "" },
    load_plugin = function(self, _p) self.plugin_device = new_dev_n; return true end }
  local song_n = { instruments = { { plugin_properties = pp_n } }, tracks = {},
    automation = function() return { is_automated = false } end }
  local okn, rn = pcall(function() return up_swap.swap_instrument(song_n, mkrec("VST3"),
    { name = "Pro-MB 2", protocol = "VST3", path = "/P/MB2.vst3" }) end)
  check(okn and rn and rn.status == "upgraded-name-matched-preset", "factory-preset base name match -> name")

  -- Parameter overlay ("params").
  local new_dev_x = { is_active = true, active_preset_data = "", presets = {},
    parameters = { { name = "Mix", is_automatable = true } } }
  local pp_x = { plugin_loaded = true,
    plugin_device = { device_path = "/P/MB.vst3", name = "VST3: Pro-MB",
      active_preset_data = "", parameters = { { name = "Mix", value = 0.5, is_automatable = true } } },
    load_plugin = function(self, _p) self.plugin_device = new_dev_x; return true end }
  local song_x = { instruments = { { plugin_properties = pp_x } }, tracks = {},
    automation = function() return { is_automated = false } end }
  local okx, rx = pcall(function() return up_swap.swap_instrument(song_x, mkrec("AU"),
    { name = "Pro-MB 2", protocol = "AU", path = "/P/MB2.au" }) end)
  check(okx and rx and rx.status == "upgraded-parameter-synth", "cross-format parameter overlay -> params")

  -- load_plugin failing yields a transfer-rejected status (no crash).
  local pp_bad = { plugin_loaded = true,
    plugin_device = { device_path = "/P/MB.vst3", name = "VST3: Pro-MB", active_preset_data = "" },
    load_plugin = function() return nil end }
  local song_bad = { instruments = { { plugin_properties = pp_bad } }, tracks = {},
    automation = function() return { is_automated = false } end }
  local okb, rb = pcall(function() return up_swap.swap_instrument(song_bad, mkrec("VST3"),
    { name = "Pro-MB 2", protocol = "VST3", path = "/P/MB2.vst3" }) end)
  check(okb and rb and rb.status == "skipped-transfer-rejected", "swap_instrument reports rejected when load fails")
end

section("up_swap falls back to the parameter overlay for an incompatible same-format chunk")
do
  -- Kick -> Kick 2: both are VST (same protocol) but a different product
  -- version, so the opaque chunk is incompatible. Writing it would be accepted
  -- by the API and read back non-empty, silently losing the patch, so it must
  -- be skipped and the captured parameters overlaid by name instead.
  local new_dev = { is_active = true, active_preset_data = "",
    presets = {}, parameters = { { name = "Mix", is_automatable = true } } }
  local pp = { plugin_loaded = true,
    plugin_device = { device_path = "/P/Kick.vst", name = "VST: Kick",
      active_preset_data = "<PresetName>Kick Old</PresetName>",
      parameters = { { name = "Mix", value = 0.25, is_automatable = true } } },
    load_plugin = function(self, _p) self.plugin_device = new_dev; return true end }
  local song = { instruments = { { plugin_properties = pp } }, tracks = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "Old", device_path = "/P/Kick.vst", device_name = "VST: Kick",
    analysis = analyze("VST: Kick", "/P/Kick.vst", "VST") }
  local candidate = analyze("VST: Kick 2", "/P/Kick2.vst", "VST")
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res, "Kick -> Kick 2 swap succeeds")
  check(ok and res and res.status == "upgraded-parameter-synth",
    "incompatible same-format chunk falls back to the parameter overlay")
  check(new_dev.active_preset_data == "", "old chunk is not written to the new plugin")
  check(new_dev.parameters[1].value == 0.25, "shared parameter value is copied")

  -- The track-device path shares the same gate.
  local track_new_dev = { is_active = true, active_preset_data = "",
    presets = {}, parameters = { { name = "Mix", is_automatable = true } } }
  local track = {
    devices = { [1] = {}, [2] = { is_active = true,
      active_preset_data = "<PresetName>Kick Old</PresetName>",
      parameters = { { name = "Mix", value = 0.25, is_automatable = true } } } },
    insert_device_at = function(self, _path, idx)
      table.insert(self.devices, idx, track_new_dev); return track_new_dev
    end,
    delete_device_at = function(self, idx) table.remove(self.devices, idx) end,
  }
  local track_song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local track_rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/Kick.vst", device_name = "VST: Kick",
    analysis = analyze("VST: Kick", "/P/Kick.vst", "VST") }
  local track_res = up_swap.swap_track_device(track_song, track_rec, candidate)
  check(track_res and track_res.status == "upgraded-parameter-synth",
    "track Kick -> Kick 2 uses the parameter overlay")
  check(track_new_dev.active_preset_data == "", "track old chunk is not written")
  check(track_new_dev.parameters[1].value == 0.25, "track shared parameter value is copied")
end

section("up_swap rejects loose family matches and attached version bumps")
do
  -- Both pairs are offered by the matcher (loose token subset / family match)
  -- but are NOT the same product at the same version, so the opaque chunk must
  -- not be transplanted. Analyze both identities (as production does) instead
  -- of hand-supplying candidate versions.
  local function overlay_check(old_name, old_path, new_name, new_path, label)
    local new_dev = { is_active = true, active_preset_data = "",
      presets = {}, parameters = { { name = "Mix", is_automatable = true } } }
    local pp = { plugin_loaded = true,
      plugin_device = { device_path = old_path, name = old_name,
        active_preset_data = "<PresetName>Old</PresetName>",
        parameters = { { name = "Mix", value = 0.25, is_automatable = true } } },
      load_plugin = function(self, _p) self.plugin_device = new_dev; return true end }
    local song = { instruments = { { plugin_properties = pp } }, tracks = {},
      automation = function() return { is_automated = false } end }
    local rec = { kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
      instrument_name = "Old", device_path = old_path, device_name = old_name,
      analysis = analyze(old_name, old_path, "VST") }
    local candidate = analyze(new_name, new_path, "VST")
    local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
    check(ok and res and res.status == "upgraded-parameter-synth",
      label .. " falls back to the parameter overlay")
    check(new_dev.active_preset_data == "", label .. " does not write the old chunk")
    check(new_dev.parameters[1].value == 0.25, label .. " copies a shared parameter")
  end

  -- "Massive X" is a distinct product, even though its tokens are a superset of
  -- "Massive" (the old bidirectional subset check accepted this pair).
  overlay_check("VST: Massive", "/P/Massive.vst", "VST: Massive X", "/P/MassiveX.vst",
    "Massive -> Massive X")
  -- The version is attached to the product word, so extract_version() returned
  -- nil for both and the old check treated them as the same version.
  overlay_check("VST: Kontakt6", "/P/Kontakt6.vst", "VST: Kontakt7", "/P/Kontakt7.vst",
    "Kontakt6 -> Kontakt7")
  -- Dots are normalized to spaces, so only the last number was compared.
  overlay_check("VST: Pro-Q 2.0", "/P/ProQ2.vst", "VST: Pro-Q 3.0", "/P/ProQ3.vst",
    "Pro-Q 2.0 -> Pro-Q 3.0")
  -- The version is attached but not at the end of the name.
  overlay_check("VST: Kontakt6 FX", "/P/Kontakt6FX.vst", "VST: Kontakt7 FX", "/P/Kontakt7FX.vst",
    "Kontakt6 FX -> Kontakt7 FX")
  -- A product qualifier ("One") must not be filtered away by the loose
  -- matcher's stop list, which excludes "one".
  overlay_check("VST: SynthMaster", "/P/SynthMaster.vst",
    "VST: SynthMaster One", "/P/SynthMasterOne.vst",
    "SynthMaster -> SynthMaster One")

  -- A name made entirely of words filtered as non-product (vendor/generic
  -- words) still has an identity, so a same-product replacement keeps its
  -- compatible chunk instead of losing non-parameter state.
  local new_dev_s = { is_active = true, active_preset_data = "", presets = {}, parameters = {} }
  local pp_s = { plugin_loaded = true,
    plugin_device = { device_path = "/P/TAL-Sampler.vst", name = "VST: TAL-Sampler",
      active_preset_data = "<PresetName>Old</PresetName>", parameters = {} },
    load_plugin = function(self, _p) self.plugin_device = new_dev_s; return true end }
  local song_s = { instruments = { { plugin_properties = pp_s } }, tracks = {},
    automation = function() return { is_automated = false } end }
  local rec_s = { kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "Old", device_path = "/P/TAL-Sampler.vst", device_name = "VST: TAL-Sampler",
    analysis = analyze("VST: TAL-Sampler", "/P/TAL-Sampler.vst", "VST") }
  local ok_s, res_s = pcall(function() return up_swap.swap_instrument(song_s, rec_s,
    analyze("VST: TAL-Sampler", "/P/TAL-Sampler-reinstall.vst", "VST")) end)
  check(ok_s and res_s and res_s.status == "upgraded-with-parameters",
    "TAL-Sampler same-product reinstall transplants the chunk")
  check(new_dev_s.active_preset_data ~= "", "TAL-Sampler chunk is written")
end

section("up_swap keeps vendor-prefixed products and bypass state")
do
  -- A manufacturer prefix on only one side must not lose a compatible chunk.
  local new_dev = { is_active = true, active_preset_data = "", presets = {}, parameters = {} }
  local pp = { plugin_loaded = true,
    plugin_device = { device_path = "/P/u-he-ACE.vst", name = "VST: u-he ACE",
      active_preset_data = "<PresetName>Old</PresetName>", parameters = {} },
    load_plugin = function(self, _p) self.plugin_device = new_dev; return true end }
  local song = { instruments = { { plugin_properties = pp } }, tracks = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "Old", device_path = "/P/u-he-ACE.vst", device_name = "VST: u-he ACE",
    analysis = analyze("VST: u-he ACE", "/P/u-he-ACE.vst", "VST") }
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec,
    analyze("VST: ACE", "/P/ACE.vst", "VST")) end)
  check(ok and res and res.status == "upgraded-with-parameters",
    "u-he ACE -> ACE transplants the compatible chunk")
  check(new_dev.active_preset_data ~= "", "u-he ACE -> ACE writes the chunk")

  -- A matching factory preset can reactivate the new device during transfer;
  -- the saved bypass flag must be restored afterwards.
  local bypassed = setmetatable(
    { active_preset_data = "", presets = { "Old" }, parameters = {}, is_active = true },
    { __newindex = function(self, key, value)
        if key == "active_preset" then
          rawset(self, "active_preset", value)
          rawset(self, "is_active", true)
        else
          rawset(self, key, value)
        end
      end })
  local old_dev = { is_active = false, active_preset_data = "<PresetName>Old</PresetName>",
    parameters = {} }
  local pp_b = { plugin_loaded = true, plugin_device = old_dev,
    load_plugin = function(self, _p) self.plugin_device = bypassed; return true end }
  local song_b = { instruments = { { plugin_properties = pp_b } }, tracks = {},
    automation = function() return { is_automated = false } end }
  local rec_b = { kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "Old", device_path = "/P/Kontakt6.vst", device_name = "VST: Kontakt6",
    analysis = analyze("VST: Kontakt6", "/P/Kontakt6.vst", "VST") }
  local ok_b, res_b = pcall(function() return up_swap.swap_instrument(song_b, rec_b,
    analyze("VST: Kontakt7", "/P/Kontakt7.vst", "VST")) end)
  check(ok_b and res_b and res_b.status == "upgraded-name-matched-preset",
    "bypassed instrument loads the matching preset")
  check(bypassed.is_active == false, "bypass state is restored after preset transfer")
end

section("up_swap uses preset + parameters for a ParameterBag")
do
  -- Renoise serializes Saturn as a parameter bag (normalized values), not as a
  -- native FabFilter preset. Replaying the bag by index carries Saturn 1's
  -- "Warm Tape" style (4/15) into Saturn 2, whose larger style enum reads that
  -- value as "Old Tape". A bag contains only parameters, so match the old
  -- preset name first and then overlay the values, remapping changed enums by
  -- their display label. Both quanta are 0 here, as Renoise reports for some
  -- plugin parameters, so the label itself must trigger the remap.
  local function saturn_style_parameter(value)
    local state = { value = value }
    local labels = {
      [0] = "Subtle Tube", [1] = "Clean Tube", [2] = "Warm Tube", [3] = "Broken Tube",
      [4] = "Subtle Tape", [5] = "Clean Tape", [6] = "Warm Tape", [7] = "Old Tape",
    }
    local function label_for(current)
      local index = math.floor(current * 27 + 0.5)
      return labels[index] or ("Style " .. tostring(index))
    end
    return setmetatable({}, {
      __index = function(_, key)
        if key == "name" then return "Band 1 Style" end
        if key == "is_automatable" then return true end
        if key == "value" then return state.value end
        if key == "value_string" then return label_for(state.value) end
        if key == "value_quantum" then return 0 end
        if key == "value_min" then return 0 end
        if key == "value_max" then return 1 end
        return nil
      end,
      __newindex = function(_, key, new_value)
        if key == "value" then
          -- Plugin enum parameters snap to the nearest option.
          state.value = math.floor(new_value * 27 + 0.5) / 27
        else
          error("read-only " .. key)
        end
      end,
    }), state
  end

  local new_style, new_state = saturn_style_parameter(0)
  local new_dev = { is_active = true, active_preset_data = "",
    presets = { "Init", "Some Other" }, active_preset = 0, parameters = { new_style } }
  local old_dev = { is_active = true, active_preset = 1, presets = { "Init" },
    active_preset_data = '<FilterDevicePreset><DeviceSlot>'
      .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
      .. '<ParameterChunk><![CDATA[]]></ParameterChunk></DeviceSlot></FilterDevicePreset>',
    parameters = {
      { name = "Band 1 Style", value = 4 / 15, is_automatable = true,
        value_quantum = 0, value_string = "Warm Tape" },
    } }
  local track = {
    devices = { [1] = {}, [2] = old_dev },
    insert_device_at = function(self, _path, index)
      table.insert(self.devices, index, new_dev)
      return new_dev
    end,
    delete_device_at = function(self, index) table.remove(self.devices, index) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/Saturn.vst", device_name = "VST: FabFilter: Saturn",
    active_preset_name = "Init",
    analysis = analyze("VST: FabFilter: Saturn", "/P/Saturn.vst", "VST") }
  local candidate = { name = "FabFilter Saturn 2", protocol = "VST", path = "/P/Saturn2.vst" }

  local ok, res = pcall(function() return up_swap.swap_track_device(song, rec, candidate) end)
  check(ok, "the ParameterBag upgrade completes")
  check(ok and res and res.status == "upgraded-parameter-synth",
    "the bag uses preset + parameter overlay instead of a raw transplant")
  check(new_dev.active_preset == 1, "the old preset name ('Init') is matched first")
  check(math.abs(new_state.value - 6 / 27) < 0.000001,
    "Warm Tape is remapped by label to Saturn 2's index, not replayed as 4/15")
  check(new_dev.active_preset_data == "",
    "the old parameter bag is not transplanted verbatim")
end
section("up_swap remaps digit-bearing enum labels without a quantum")
do
  -- Renoise can report value_quantum = 0 even for enum parameters. Oversampling
  -- labels such as "2x" and "4x" must still be matched by label: the old bank
  -- [Off, 2x, 4x] stores 2x at 0.5, but in [Off, 2x, 4x, 8x, 16x] that value is
  -- 4x, while 2x is 0.25.
  local function enum_parameter(name, labels, value)
    local state = { value = value, writes = 0 }
    local last = #labels - 1
    local function label_for(current)
      local index = math.floor(current * last + 0.5)
      return labels[index + 1] or "?"
    end
    return setmetatable({}, {
      __index = function(_, key)
        if key == "name" then return name end
        if key == "is_automatable" then return true end
        if key == "value" then return state.value end
        if key == "value_string" then return label_for(state.value) end
        if key == "value_quantum" then return 0 end
        if key == "value_min" then return 0 end
        if key == "value_max" then return 1 end
        return nil
      end,
      __newindex = function(_, key, new_value)
        if key == "value" then
          state.writes = state.writes + 1
          -- Plugin enums snap to the nearest option.
          state.value = math.floor(new_value * last + 0.5) / last
        else
          error("read-only " .. key)
        end
      end,
    }), state
  end

  local new_param, new_state = enum_parameter("Oversampling", { "Off", "2x", "4x", "8x", "16x" }, 0)
  local new_dev = { is_active = true, active_preset_data = "", presets = {}, parameters = { new_param } }
  local old_dev = { is_active = true, active_preset_data = '<FilterDevicePreset><DeviceSlot>'
      .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
      .. '<ParameterChunk><![CDATA[]]></ParameterChunk></DeviceSlot></FilterDevicePreset>',
    parameters = {
      { name = "Oversampling", value = 0.5, is_automatable = true,
        value_quantum = 0, value_string = "2x" },
    } }
  local track = {
    devices = { [1] = {}, [2] = old_dev },
    insert_device_at = function(self, _path, index)
      table.insert(self.devices, index, new_dev)
      return new_dev
    end,
    delete_device_at = function(self, index) table.remove(self.devices, index) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/ProL.vst", device_name = "VST: FabFilter Pro-L",
    analysis = analyze("VST: FabFilter Pro-L", "/P/ProL.vst", "VST") }
  local candidate = { name = "FabFilter Pro-L 2", protocol = "VST", path = "/P/ProL2.vst" }

  local ok, res = pcall(function() return up_swap.swap_track_device(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-parameter-synth", "the enum overlay completes")
  check(math.abs(new_state.value - 0.25) < 0.000001,
    "2x is remapped to the new bank's index instead of replayed as 4x")
  check(new_state.value ~= 0.5, "the old normalized value must not select 4x")
end

section("up_swap remaps numeric-only enum labels using the captured quantum")
do
  -- Some option banks label their choices with bare integers ("1", "2", "4"),
  -- so the textual heuristic cannot spot them. The captured quantum (0.5 over
  -- three options) marks the parameter as discrete: the old "2" (0.5) must
  -- remap to the replacement's "2" (0.25), not replay 0.5 onto "4".
  local function numeric_enum_parameter(labels, quantum, value)
    local state = { value = value }
    local function label_for(current)
      local index = math.floor(current / quantum + 0.5)
      return labels[index + 1] or "?"
    end
    return setmetatable({}, {
      __index = function(_, key)
        if key == "name" then return "Ratio" end
        if key == "is_automatable" then return true end
        if key == "value" then return state.value end
        if key == "value_string" then return label_for(state.value) end
        if key == "value_quantum" then return quantum end
        if key == "value_min" then return 0 end
        if key == "value_max" then return 1 end
        return nil
      end,
      __newindex = function(_, key, new_value)
        if key == "value" then
          -- Plugin enums snap to the nearest option.
          state.value = math.floor(new_value / quantum + 0.5) * quantum
        else
          error("read-only " .. key)
        end
      end,
    }), state
  end

  local new_param, new_state = numeric_enum_parameter({ "1", "2", "4", "8", "16" }, 0.25, 0)
  local new_dev = { is_active = true, active_preset_data = "", presets = {}, parameters = { new_param } }
  local old_dev = { is_active = true, active_preset_data = '<FilterDevicePreset><DeviceSlot>'
      .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
      .. '<ParameterChunk><![CDATA[]]></ParameterChunk></DeviceSlot></FilterDevicePreset>',
    parameters = {
      { name = "Ratio", value = 0.5, is_automatable = true,
        value_quantum = 0.5, value_string = "2" },
    } }
  local track = {
    devices = { [1] = {}, [2] = old_dev },
    insert_device_at = function(self, _path, index)
      table.insert(self.devices, index, new_dev)
      return new_dev
    end,
    delete_device_at = function(self, index) table.remove(self.devices, index) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/Comp.vst", device_name = "VST: Example Comp",
    analysis = analyze("VST: Example Comp", "/P/Comp.vst", "VST") }
  local candidate = { name = "Example Comp 2", protocol = "VST", path = "/P/Comp2.vst" }

  local ok, res = pcall(function() return up_swap.swap_track_device(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-parameter-synth", "the numeric enum overlay completes")
  check(math.abs(new_state.value - 0.25) < 0.000001,
    "the numeric-only '2' remaps to the new bank's index instead of replaying 0.5 as '4'")
  check(new_state.value ~= 0.5, "the old normalized value must not select '4'")
end

section("up_swap remaps fractional musical-time enum labels")
do
  -- A quantized tempo-sync bank labels its choices "1/8", "1/4", "1/2". Those
  -- contain no letters and no bare integer, so the textual and integer
  -- heuristics miss them; the captured quantum reveals the small discrete bank,
  -- so the saved "1/4" (0.5 in a 3-option bank) must remap by label to the
  -- replacement's "1/4" (0.25), not replay 0.5 onto "1/2".
  local function sync_parameter(labels, quantum, value)
    local state = { value = value }
    local function label_for(current)
      local index = math.floor(current / quantum + 0.5)
      return labels[index + 1] or "?"
    end
    return setmetatable({}, {
      __index = function(_, key)
        if key == "name" then return "Sync" end
        if key == "is_automatable" then return true end
        if key == "value" then return state.value end
        if key == "value_string" then return label_for(state.value) end
        if key == "value_quantum" then return quantum end
        if key == "value_min" then return 0 end
        if key == "value_max" then return 1 end
        return nil
      end,
      __newindex = function(_, key, new_value)
        if key == "value" then
          state.value = math.floor(new_value / quantum + 0.5) * quantum
        else
          error("read-only " .. key)
        end
      end,
    }), state
  end

  local new_param, new_state = sync_parameter({ "1/8", "1/4", "1/2", "1", "2" }, 0.25, 0)
  local new_dev = { is_active = true, active_preset_data = "", presets = {}, parameters = { new_param } }
  local old_dev = { is_active = true, active_preset_data = '<FilterDevicePreset><DeviceSlot>'
      .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
      .. '<ParameterChunk><![CDATA[]]></ParameterChunk></DeviceSlot></FilterDevicePreset>',
    parameters = {
      { name = "Sync", value = 0.5, is_automatable = true,
        value_quantum = 0.5, value_string = "1/4" },
    } }
  local track = {
    devices = { [1] = {}, [2] = old_dev },
    insert_device_at = function(self, _path, index)
      table.insert(self.devices, index, new_dev)
      return new_dev
    end,
    delete_device_at = function(self, index) table.remove(self.devices, index) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/Delay.vst", device_name = "VST: Example Delay",
    analysis = analyze("VST: Example Delay", "/P/Delay.vst", "VST") }
  local candidate = { name = "Example Delay 2", protocol = "VST", path = "/P/Delay2.vst" }

  local ok, res = pcall(function() return up_swap.swap_track_device(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-parameter-synth", "the fractional enum overlay completes")
  check(math.abs(new_state.value - 0.25) < 0.000001,
    "the fractional '1/4' remaps to the new bank's index instead of replaying 0.5 as '1/2'")
  check(new_state.value ~= 0.5, "the old normalized value must not select '1/2'")
end

section("up_swap keeps label lookup for a zero-quantum numeric enum replacement")
do
  -- The replacement reports no quantum, so the discrete-quantum test cannot
  -- classify it. It is not fine-grained either, so the numeric-only enum label
  -- must keep using the label lookup; the sampling fallback finds "2" at 0.25
  -- instead of replaying the old 0.5 onto "4".
  local function zero_quantum_parameter(labels, step, value)
    local state = { value = value }
    local function label_for(current)
      local index = math.floor(current / step + 0.5)
      return labels[index + 1] or "?"
    end
    return setmetatable({}, {
      __index = function(_, key)
        if key == "name" then return "Ratio" end
        if key == "is_automatable" then return true end
        if key == "value" then return state.value end
        if key == "value_string" then return label_for(state.value) end
        if key == "value_quantum" then return 0 end
        if key == "value_min" then return 0 end
        if key == "value_max" then return 1 end
        return nil
      end,
      __newindex = function(_, key, new_value)
        if key == "value" then
          state.value = math.floor(new_value / step + 0.5) * step
        else
          error("read-only " .. key)
        end
      end,
    }), state
  end

  local new_param, new_state = zero_quantum_parameter({ "1", "2", "4", "8", "16" }, 0.25, 0)
  local new_dev = { is_active = true, active_preset_data = "", presets = {}, parameters = { new_param } }
  local old_dev = { is_active = true, active_preset_data = '<FilterDevicePreset><DeviceSlot>'
      .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
      .. '<ParameterChunk><![CDATA[]]></ParameterChunk></DeviceSlot></FilterDevicePreset>',
    parameters = {
      { name = "Ratio", value = 0.5, is_automatable = true,
        value_quantum = 0.5, value_string = "2" },
    } }
  local track = {
    devices = { [1] = {}, [2] = old_dev },
    insert_device_at = function(self, _path, index)
      table.insert(self.devices, index, new_dev)
      return new_dev
    end,
    delete_device_at = function(self, index) table.remove(self.devices, index) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/Comp.vst", device_name = "VST: Example Comp",
    analysis = analyze("VST: Example Comp", "/P/Comp.vst", "VST") }
  local candidate = { name = "Example Comp 2", protocol = "VST", path = "/P/Comp2.vst" }

  local ok, res = pcall(function() return up_swap.swap_track_device(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-parameter-synth",
    "the zero-quantum numeric enum overlay completes")
  check(math.abs(new_state.value - 0.25) < 0.000001,
    "the sampling fallback finds '2' at 0.25 instead of replaying 0.5 as '4'")
  check(new_state.value ~= 0.5, "the old normalized value must not select '4'")
end

section("up_swap bounds exhaustive label probing")
do
  -- A tiny reported quantum (or a formatted numeric label that never matches)
  -- must not make label lookup walk a million plugin steps. The probe budget is
  -- 256; exceeding it leaves the base option alone instead of replaying an
  -- unrelated enum index.
  local state = { value = 0, writes = 0 }
  local parameter = setmetatable({}, {
    __index = function(_, key)
      if key == "name" then return "Band 1 Style" end
      if key == "is_automatable" then return true end
      if key == "value" then return state.value end
      if key == "value_string" then return "Other" end
      if key == "value_quantum" then return 0.000001 end
      if key == "value_min" then return 0 end
      if key == "value_max" then return 1 end
      return nil
    end,
    __newindex = function(_, key, new_value)
      if key == "value" then
        state.writes = state.writes + 1
        state.value = new_value
      else
        error("read-only " .. key)
      end
    end,
  })
  local new_dev = { is_active = true, active_preset_data = "", presets = {}, parameters = { parameter } }
  local old_dev = { is_active = true, active_preset_data = '<FilterDevicePreset><DeviceSlot>'
      .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
      .. '<ParameterChunk><![CDATA[]]></ParameterChunk></DeviceSlot></FilterDevicePreset>',
    parameters = {
      { name = "Band 1 Style", value = 4 / 15, is_automatable = true,
        value_quantum = 0, value_string = "Warm Tape" },
    } }
  local track = {
    devices = { [1] = {}, [2] = old_dev },
    insert_device_at = function(self, _path, index)
      table.insert(self.devices, index, new_dev)
      return new_dev
    end,
    delete_device_at = function(self, index) table.remove(self.devices, index) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/Saturn.vst", device_name = "VST: FabFilter: Saturn",
    analysis = analyze("VST: FabFilter: Saturn", "/P/Saturn.vst", "VST") }
  local candidate = { name = "FabFilter Saturn 2", protocol = "VST", path = "/P/Saturn2.vst" }

  local ok = pcall(function() return up_swap.swap_track_device(song, rec, candidate) end)
  check(ok, "the bounded probe completes")
  check(state.writes <= 256, "label lookup performs at most 256 plugin writes")
  check(state.value == 0, "the base option is kept when the label cannot be probed")
end

section("up_swap keeps the raw bag fallback within one format")
do
  local bag = '<FilterDevicePreset><DeviceSlot>'
    .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
    .. '<ParameterChunk><![CDATA[]]></ParameterChunk></DeviceSlot></FilterDevicePreset>'
  local function run(old_protocol, candidate_protocol)
    local new_dev = { is_active = true, active_preset_data = "", presets = {}, active_preset = 0,
      parameters = {} }
    local old_dev = { is_active = true, active_preset = 0, presets = {},
      active_preset_data = bag, parameters = {} }
    local track = {
      devices = { [1] = {}, [2] = old_dev },
      insert_device_at = function(self, _path, index)
        table.insert(self.devices, index, new_dev); return new_dev
      end,
      delete_device_at = function(self, index) table.remove(self.devices, index) end,
    }
    local song = { tracks = { track }, instruments = {},
      automation = function() return { is_automated = false } end }
    local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
      device_path = "/P/OD.vst", device_name = "VST: Example Overdrive",
      analysis = analyze("VST: Example Overdrive", "/P/OD.vst", old_protocol) }
    local candidate = { name = "Example Overdrive 2", protocol = candidate_protocol,
      path = "/P/OD2.vst3" }
    local ok, res = pcall(function() return up_swap.swap_track_device(song, rec, candidate) end)
    return ok, res, new_dev
  end

  local ok_same, res_same, new_same = run("VST", "VST")
  check(ok_same and res_same and res_same.status == "upgraded-with-parameters",
    "a same-format unmapped bag still falls back to a raw transplant")
  check(new_same.active_preset_data == bag, "the same-format bag is transplanted")

  local ok_cross, res_cross, new_cross = run("VST", "VST3")
  check(ok_cross and res_cross and res_cross.status == "upgraded-default",
    "a cross-format unmapped bag is not replayed by index")
  check(new_cross.active_preset_data == "", "the cross-format bag is left at default state")
end

section("up_swap bounds label probing on a fine-grained numeric parameter")
do
  -- A continuous parameter can report a tiny positive quantum, which would make
  -- an exhaustive step walk millions of synchronous writes and stall Renoise.
  -- The walk must bail out and fall back to the numeric transfer.
  local value_writes = 0
  local state = { value = 0 }
  local param = setmetatable({}, {
    __index = function(_, key)
      if key == "name" then return "Cutoff" end
      if key == "is_automatable" then return true end
      if key == "value" then return state.value end
      if key == "value_string" then return string.format("%.2f", state.value) end
      if key == "value_quantum" then return 0.000001 end
      if key == "value_min" then return 0 end
      if key == "value_max" then return 1 end
      return nil
    end,
    __newindex = function(_, key, new_value)
      if key == "value" then
        value_writes = value_writes + 1
        state.value = new_value
      else
        error("read-only " .. key)
      end
    end,
  })
  local new_dev = { is_active = true, active_preset_data = "", presets = {}, active_preset = 0,
    parameters = { param } }
  local old_dev = { is_active = true, active_preset = 0, presets = {},
    active_preset_data = '<FilterDevicePreset><DeviceSlot>'
      .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
      .. '<ParameterChunk><![CDATA[]]></ParameterChunk></DeviceSlot></FilterDevicePreset>',
    parameters = {
      { name = "Cutoff", value = 0.4, is_automatable = true,
        value_quantum = 0.01, value_string = "0.40" },
    } }
  local track = {
    devices = { [1] = {}, [2] = old_dev },
    insert_device_at = function(self, _path, index)
      table.insert(self.devices, index, new_dev); return new_dev
    end,
    delete_device_at = function(self, index) table.remove(self.devices, index) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/EQ.vst", device_name = "VST: Example EQ",
    analysis = analyze("VST: Example EQ", "/P/EQ.vst", "VST") }
  local candidate = { name = "Example EQ 2", protocol = "VST", path = "/P/EQ2.vst" }

  local ok, res = pcall(function() return up_swap.swap_track_device(song, rec, candidate) end)
  check(ok, "the fine-grained parameter upgrade completes")
  check(ok and res and res.status == "upgraded-parameter-synth",
    "a fine-grained parameter falls back instead of probing every step")
  check(value_writes < 300, "the label probe stays within its budget")
  check(math.abs(state.value - 0.4) < 0.000001, "the numeric value is transferred")
end

section("up_swap keeps an instrument bypassed after a preset load")
do
  -- A matching factory preset can reset is_active when it is loaded. The
  -- instrument caller must restore the old bypass flag after transfer_state,
  -- just like the track-device caller does. The replacement maps the captured
  -- control, so the preset load runs before the parameter overlay.
  local new_state = { active_preset = 0, is_active = true }
  local new_dev = setmetatable({}, {
    __index = function(_, key)
      if key == "presets" then return { "Init" } end
      if key == "parameters" then return { { name = "Mix", value = 0, is_automatable = true } } end
      if key == "active_preset_data" then return "" end
      if key == "active_preset" then return new_state.active_preset end
      if key == "is_active" then return new_state.is_active end
      return nil
    end,
    __newindex = function(_, key, value)
      if key == "active_preset" then
        new_state.active_preset = value
        -- A preset load re-enables the plugin.
        new_state.is_active = true
      elseif key == "is_active" then
        new_state.is_active = value
      else
        rawset(_, key, value)
      end
    end,
  })
  local old_dev = { is_active = false, active_preset = 1, presets = { "Init" },
    active_preset_data = '<FilterDevicePreset><DeviceSlot>'
      .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
      .. '<ParameterChunk><![CDATA[]]></ParameterChunk></DeviceSlot></FilterDevicePreset>',
    parameters = { { name = "Mix", value = 0.5, is_automatable = true } } }
  local pp = { plugin_loaded = true, plugin_device = old_dev,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end }
  local song = { instruments = { { plugin_properties = pp } }, tracks = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "Saturn 2", device_path = "/P/Saturn2.vst3",
    analysis = analyze("VST3: FabFilter: Saturn 2", "/P/Saturn2.vst3", "VST3") }
  local candidate = analyze("VST3: FabFilter: Saturn 2", "/P/Saturn2-new.vst3", "VST3")
  candidate.path = "/P/Saturn2-new.vst3"

  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-parameter-synth",
    "the mapped control is overlaid after the preset load")
  check(new_state.is_active == false, "the instrument's old bypass state is restored last")
end

section("up_swap does not replay a bag when enum labels were rejected")
do
  -- No preset matches and the replacement does not expose the old enum label.
  -- The overlay deliberately keeps the replacement's option instead of an
  -- unrelated index; the raw same-format fallback must not undo that decision.
  local new_state = { value = 0 }
  local new_param = setmetatable({}, {
    __index = function(_, key)
      if key == "name" then return "Band 1 Style" end
      if key == "is_automatable" then return true end
      if key == "value" then return new_state.value end
      if key == "value_string" then return "Other" end
      if key == "value_quantum" then return 0 end
      if key == "value_min" then return 0 end
      if key == "value_max" then return 1 end
      return nil
    end,
    __newindex = function(_, key, new_value)
      if key == "value" then
        new_state.value = new_value
      else
        error("read-only " .. key)
      end
    end,
  })
  local new_dev = { is_active = true, active_preset_data = "", presets = {},
    parameters = { new_param } }
  local bag = '<FilterDevicePreset><DeviceSlot>'
    .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
    .. '<ParameterChunk><![CDATA[]]></ParameterChunk></DeviceSlot></FilterDevicePreset>'
  local old_dev = { is_active = true, presets = {}, active_preset_data = bag,
    parameters = {
      { name = "Band 1 Style", value = 4 / 15, is_automatable = true,
        value_quantum = 0, value_string = "Warm Tape" },
    } }
  local track = {
    devices = { [1] = {}, [2] = old_dev },
    insert_device_at = function(self, _path, index)
      table.insert(self.devices, index, new_dev); return new_dev
    end,
    delete_device_at = function(self, index) table.remove(self.devices, index) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/Saturn2-old.vst", device_name = "VST: FabFilter: Saturn 2",
    analysis = analyze("VST: FabFilter: Saturn 2", "/P/Saturn2-old.vst", "VST") }
  local candidate = { name = "FabFilter Saturn 2", protocol = "VST", path = "/P/Saturn2.vst" }

  local ok, res = pcall(function() return up_swap.swap_track_device(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-default",
    "an unavailable enum label falls back to the default state, not a raw replay")
  check(new_dev.active_preset_data == "", "the bag is not replayed after a rejected label")
end

section("up_swap transfers attached-unit numeric values")
do
  -- Continuous displays may attach their unit ("0.413ms", "-3.0dB"). Those
  -- must keep the numeric transfer; only genuine option labels like "2x" are
  -- enum-like. The replacement's formatted label differs, so label lookup
  -- cannot recover the value either.
  local new_state = { value = 0 }
  local new_param = setmetatable({}, {
    __index = function(_, key)
      if key == "name" then return "Attack" end
      if key == "is_automatable" then return true end
      if key == "value" then return new_state.value end
      if key == "value_string" then return string.format("%.2f ms", new_state.value) end
      if key == "value_quantum" then return 0 end
      if key == "value_min" then return 0 end
      if key == "value_max" then return 1 end
      return nil
    end,
    __newindex = function(_, key, new_value)
      if key == "value" then
        new_state.value = new_value
      else
        error("read-only " .. key)
      end
    end,
  })
  local new_dev = { is_active = true, active_preset_data = "", presets = {},
    parameters = { new_param } }
  local old_dev = { is_active = true, active_preset_data = '<FilterDevicePreset><DeviceSlot>'
      .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
      .. '<ParameterChunk><![CDATA[]]></ParameterChunk></DeviceSlot></FilterDevicePreset>',
    parameters = {
      { name = "Attack", value = 0.413, is_automatable = true,
        value_quantum = 0, value_string = "0.413ms" },
    } }
  local track = {
    devices = { [1] = {}, [2] = old_dev },
    insert_device_at = function(self, _path, index)
      table.insert(self.devices, index, new_dev); return new_dev
    end,
    delete_device_at = function(self, index) table.remove(self.devices, index) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/Comp.vst", device_name = "VST: Example Comp",
    analysis = analyze("VST: Example Comp", "/P/Comp.vst", "VST") }
  local candidate = { name = "Example Comp 2", protocol = "VST", path = "/P/Comp2.vst" }

  local ok, res = pcall(function() return up_swap.swap_track_device(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-parameter-synth", "the numeric overlay completes")
  check(math.abs(new_state.value - 0.413) < 0.000001,
    "an attached-unit display keeps its numeric value")
end

section("up_swap transplant a missing instrument's recovered bag")
do
  -- A missing plugin has no live parameters to overlay. Its recovered
  -- ParameterBag must still take the compatible direct transplant; selecting a
  -- factory preset instead would lose the saved parameter tweaks.
  local bag = '<FilterDevicePreset><DeviceSlot>'
    .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
    .. '<ParameterChunk><![CDATA[warm-tape-state]]></ParameterChunk></DeviceSlot></FilterDevicePreset>'
  local new_dev = { is_active = true, active_preset_data = "", presets = { "Init" },
    active_preset = 0, parameters = {} }
  local pp = { plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end }
  local song = { instruments = { { plugin_properties = pp } }, tracks = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "Saturn 2", active_preset_name = "Init", active_preset_data = bag,
    analysis = analyze("VST3: FabFilter: Saturn 2", nil, "VST3") }
  local candidate = analyze("VST3: FabFilter: Saturn 2", "/P/Saturn2.vst3", "VST3")
  candidate.path = "/P/Saturn2.vst3"

  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-with-parameters",
    "the recovered bag is transplanted instead of only matching the preset")
  check(new_dev.active_preset_data == bag, "the saved parameter state is preserved")
end

section("up_swap does not replay a bag when parameters mapped but failed")
do
  -- A mapped parameter whose value cannot be written is still a mapping. The
  -- raw bag must not be replayed, because that would overwrite the overlay's
  -- deliberate result with unrelated source indices.
  local new_state = { value = 0.5 }
  local new_param = setmetatable({}, {
    __index = function(_, key)
      if key == "name" then return "Mix" end
      if key == "is_automatable" then return true end
      if key == "value" then return new_state.value end
      if key == "value_string" then return "0.50" end
      if key == "value_quantum" then return 0 end
      if key == "value_min" then return 0 end
      if key == "value_max" then return 1 end
      return nil
    end,
    __newindex = function(_, key, _new_value)
      error("read-only " .. key)
    end,
  })
  local new_dev = { is_active = true, active_preset_data = "", presets = {},
    parameters = { new_param } }
  local bag = '<FilterDevicePreset><DeviceSlot>'
    .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
    .. '<ParameterChunk><![CDATA[]]></ParameterChunk></DeviceSlot></FilterDevicePreset>'
  local old_dev = { is_active = true, presets = {}, active_preset_data = bag,
    parameters = {
      { name = "Mix", value = 0.7, is_automatable = true,
        value_quantum = 0, value_string = "0.70" },
    } }
  local track = {
    devices = { [1] = {}, [2] = old_dev },
    insert_device_at = function(self, _path, index)
      table.insert(self.devices, index, new_dev); return new_dev
    end,
    delete_device_at = function(self, index) table.remove(self.devices, index) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/Saturn2-old.vst", device_name = "VST: FabFilter: Saturn 2",
    analysis = analyze("VST: FabFilter: Saturn 2", "/P/Saturn2-old.vst", "VST") }
  local candidate = { name = "FabFilter Saturn 2", protocol = "VST", path = "/P/Saturn2.vst" }

  local ok, res = pcall(function() return up_swap.swap_track_device(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-default",
    "a mapped-but-unwritable parameter keeps the default state")
  check(new_dev.active_preset_data == "", "the bag is not replayed after a mapping")
end

section("up_swap keeps a compatible track bag without captured parameters")
do
  -- A same-product/version, same-format track replacement whose controls are all
  -- non-automatable captures no live parameters, but its compatible ParameterBag
  -- still holds the saved state. A matching factory preset must not shadow the
  -- direct transplant and discard those tweaks.
  local bag = '<FilterDevicePreset><DeviceSlot>'
    .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
    .. '<ParameterChunk><![CDATA[custom-state]]></ParameterChunk></DeviceSlot></FilterDevicePreset>'
  local new_dev = { is_active = true, active_preset_data = "", presets = { "Init" },
    active_preset = 0, parameters = {} }
  local old_dev = { is_active = true, active_preset = 0, presets = {}, active_preset_data = bag,
    parameters = {} }
  local track = {
    devices = { [1] = {}, [2] = old_dev },
    insert_device_at = function(self, _path, index)
      table.insert(self.devices, index, new_dev); return new_dev
    end,
    delete_device_at = function(self, index) table.remove(self.devices, index) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/Saturn2.vst", device_name = "VST: FabFilter: Saturn 2",
    active_preset_name = "Init",
    analysis = analyze("VST: FabFilter: Saturn 2", "/P/Saturn2.vst", "VST") }
  local candidate = analyze("VST: FabFilter: Saturn 2", "/P/Saturn2-new.vst", "VST")
  candidate.path = "/P/Saturn2-new.vst"

  local ok, res = pcall(function() return up_swap.swap_track_device(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-with-parameters",
    "a compatible bag is transplanted even with no captured parameters")
  check(new_dev.active_preset_data == bag, "the saved parameter state is preserved")
  check(new_dev.active_preset == 0, "the matching preset does not shadow the compatible bag")
end

section("up_swap does not wrap a missing instrument's bag across formats")
do
  -- A missing instrument across VST -> VST3 has no live parameters to verify a
  -- write against, and a ParameterBag is host parameter data, not native engine
  -- state. A converted transplant must not wrap it as a Comp chunk; a matching
  -- factory preset is used instead.
  local bag = '<FilterDevicePreset><DeviceSlot>'
    .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
    .. '<ParameterChunk><![CDATA[custom-state]]></ParameterChunk></DeviceSlot></FilterDevicePreset>'
  local new_dev = { is_active = true, active_preset_data = "", presets = { "Saturn 2 Init" },
    active_preset = 0, parameters = {} }
  local pp = { plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end }
  local song = { instruments = { { plugin_properties = pp } }, tracks = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "Saturn 2", active_preset_name = "Saturn 2 Init", active_preset_data = bag,
    analysis = analyze("VST: FabFilter: Saturn 2", nil, "VST") }
  local candidate = analyze("VST3: FabFilter: Saturn 2", "/P/Saturn2.vst3", "VST3")
  candidate.path = "/P/Saturn2.vst3"

  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-name-matched-preset",
    "a cross-format bag uses a matching preset instead of a native wrap")
  check(new_dev.active_preset == 1, "the matching factory preset is selected")
  check(new_dev.active_preset_data == "",
    "the host parameter bag is not injected as native plugin state")
end

section("up_swap falls back to a raw bag when parameters cannot be read")
do
  -- If reading the replacement's parameters fails or returns nil,
  -- apply_parameter_values must still report zero mappings (not nil), so a
  -- same-format ParameterBag with no matching preset falls back to the raw
  -- transplant instead of being left at default state.
  local bag = '<FilterDevicePreset><DeviceSlot>'
    .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
    .. '<ParameterChunk><![CDATA[]]></ParameterChunk></DeviceSlot></FilterDevicePreset>'
  local new_dev = { is_active = true, active_preset_data = "", presets = {}, active_preset = 0 }
  local old_dev = { is_active = true, active_preset = 0, presets = {}, active_preset_data = bag,
    parameters = {
      { name = "Mix", value = 0.7, is_automatable = true, value_quantum = 0, value_string = "0.70" },
    } }
  local track = {
    devices = { [1] = {}, [2] = old_dev },
    insert_device_at = function(self, _path, index)
      table.insert(self.devices, index, new_dev); return new_dev
    end,
    delete_device_at = function(self, index) table.remove(self.devices, index) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/OD.vst", device_name = "VST: Example Overdrive",
    analysis = analyze("VST: Example Overdrive", "/P/OD.vst", "VST") }
  local candidate = { name = "Example Overdrive 2", protocol = "VST", path = "/P/OD2.vst" }

  local ok, res = pcall(function() return up_swap.swap_track_device(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-with-parameters",
    "an unreadable parameter list still allows the raw same-format fallback")
  check(new_dev.active_preset_data == bag, "the bag is transplanted when nothing could be mapped")
end

section("up_swap applies continuous values that share a rounded display")
do
  -- Continuous controls can round to the same display string ("0.41") while
  -- holding different values (0.413 vs 0.410). Display equality must not skip
  -- the numeric write just because the quanta differ.
  local new_state = { value = 0.410 }
  local new_param = setmetatable({}, {
    __index = function(_, key)
      if key == "name" then return "Attack" end
      if key == "is_automatable" then return true end
      if key == "value" then return new_state.value end
      if key == "value_string" then return "0.41" end
      if key == "value_quantum" then return 0.000001 end
      if key == "value_min" then return 0 end
      if key == "value_max" then return 1 end
      return nil
    end,
    __newindex = function(_, key, new_value)
      if key == "value" then
        new_state.value = new_value
      else
        error("read-only " .. key)
      end
    end,
  })
  local new_dev = { is_active = true, active_preset_data = "", presets = {},
    parameters = { new_param } }
  local bag = '<FilterDevicePreset><DeviceSlot>'
    .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
    .. '<ParameterChunk><![CDATA[]]></ParameterChunk></DeviceSlot></FilterDevicePreset>'
  local old_dev = { is_active = true, presets = {}, active_preset_data = bag,
    parameters = {
      { name = "Attack", value = 0.413, is_automatable = true,
        value_quantum = 0.001, value_string = "0.41" },
    } }
  local track = {
    devices = { [1] = {}, [2] = old_dev },
    insert_device_at = function(self, _path, index)
      table.insert(self.devices, index, new_dev); return new_dev
    end,
    delete_device_at = function(self, index) table.remove(self.devices, index) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/Saturn2-old.vst", device_name = "VST: FabFilter: Saturn 2",
    analysis = analyze("VST: FabFilter: Saturn 2", "/P/Saturn2-old.vst", "VST") }
  local candidate = { name = "FabFilter Saturn 2", protocol = "VST", path = "/P/Saturn2.vst" }

  local ok, res = pcall(function() return up_swap.swap_track_device(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-parameter-synth", "the continuous overlay completes")
  check(math.abs(new_state.value - 0.413) < 0.000001,
    "the saved continuous value is written even when the display strings match")
end

section("up_swap transplants a bag when capture omits non-automatable controls")
do
  -- A track snapshot only captures automatable controls. When a non-automatable
  -- control is omitted, the compatible bag must be transplanted so the omitted
  -- saved setting is not lost with the old device.
  local bag = '<FilterDevicePreset><DeviceSlot>'
    .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
    .. '<ParameterChunk><![CDATA[]]></ParameterChunk></DeviceSlot></FilterDevicePreset>'
  local new_dev = { is_active = true, active_preset_data = "", presets = {},
    parameters = { { name = "Mix", value = 0.5, is_automatable = true } } }
  local old_dev = { is_active = true, presets = {}, active_preset_data = bag,
    parameters = {
      { name = "Mix", value = 0.7, is_automatable = true },
      { name = "Hidden", value = 0.3, is_automatable = false },
    } }
  local track = {
    devices = { [1] = {}, [2] = old_dev },
    insert_device_at = function(self, _path, index)
      table.insert(self.devices, index, new_dev); return new_dev
    end,
    delete_device_at = function(self, index) table.remove(self.devices, index) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/Saturn2-old.vst", device_name = "VST: FabFilter: Saturn 2",
    analysis = analyze("VST: FabFilter: Saturn 2", "/P/Saturn2-old.vst", "VST") }
  local candidate = analyze("VST: FabFilter: Saturn 2", "/P/Saturn2.vst", "VST")
  candidate.path = "/P/Saturn2.vst"

  local ok, res = pcall(function() return up_swap.swap_track_device(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-with-parameters",
    "an incomplete snapshot keeps the compatible direct transplant")
  check(new_dev.active_preset_data == bag, "the omitted non-automatable setting is preserved")
end

section("up_swap transplants a bag when captured control names are duplicated")
do
  -- The name-keyed overlay can restore only the first of two controls sharing a
  -- name, so a duplicated snapshot is not complete. The compatible ParameterBag
  -- must be transplanted so the second control's saved value is not lost.
  local bag = '<FilterDevicePreset><DeviceSlot>'
    .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
    .. '<ParameterChunk><![CDATA[]]></ParameterChunk></DeviceSlot></FilterDevicePreset>'
  local new_dev = { is_active = true, active_preset_data = "", presets = {},
    parameters = {
      { name = "Gain", value = 0.5, is_automatable = true },
      { name = "Gain", value = 0.5, is_automatable = true },
    } }
  local old_dev = { is_active = true, presets = {}, active_preset_data = bag,
    parameters = {
      { name = "Gain", value = 0.7, is_automatable = true },
      { name = "Gain", value = 0.3, is_automatable = true },
    } }
  local track = {
    devices = { [1] = {}, [2] = old_dev },
    insert_device_at = function(self, _path, index)
      table.insert(self.devices, index, new_dev); return new_dev
    end,
    delete_device_at = function(self, index) table.remove(self.devices, index) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/Saturn2-old.vst", device_name = "VST: FabFilter: Saturn 2",
    analysis = analyze("VST: FabFilter: Saturn 2", "/P/Saturn2-old.vst", "VST") }
  local candidate = analyze("VST: FabFilter: Saturn 2", "/P/Saturn2.vst", "VST")
  candidate.path = "/P/Saturn2.vst"

  local ok, res = pcall(function() return up_swap.swap_track_device(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-with-parameters",
    "a duplicated snapshot keeps the compatible direct transplant")
  check(new_dev.active_preset_data == bag, "the duplicate-named control's saved value is preserved")
end

section("up_swap remaps unit-bearing discrete option banks")
do
  -- A slope bank labels its choices with integer values and a unit
  -- ("12 dB/oct"). The bounded quantum (0.5 over three options) marks it as
  -- discrete, so the saved 24 dB/oct (0.5) must remap by label into the
  -- replacement's five-option bank (0.75), not replay 0.5 as 18 dB/oct.
  local function slope_parameter(labels, quantum, value)
    local state = { value = value }
    local function label_for(current)
      local index = math.floor(current / quantum + 0.5)
      return labels[index + 1] or "?"
    end
    return setmetatable({}, {
      __index = function(_, key)
        if key == "name" then return "Slope" end
        if key == "is_automatable" then return true end
        if key == "value" then return state.value end
        if key == "value_string" then return label_for(state.value) end
        if key == "value_quantum" then return quantum end
        if key == "value_min" then return 0 end
        if key == "value_max" then return 1 end
        return nil
      end,
      __newindex = function(_, key, new_value)
        if key == "value" then
          -- Plugin enums snap to the nearest option.
          state.value = math.floor(new_value / quantum + 0.5) * quantum
        else
          error("read-only " .. key)
        end
      end,
    }), state
  end

  local new_param, new_state = slope_parameter(
    { "6 dB/oct", "12 dB/oct", "18 dB/oct", "24 dB/oct", "48 dB/oct" }, 0.25, 0)
  local new_dev = { is_active = true, active_preset_data = "", presets = {}, parameters = { new_param } }
  local old_dev = { is_active = true, active_preset_data = '<FilterDevicePreset><DeviceSlot>'
      .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
      .. '<ParameterChunk><![CDATA[]]></ParameterChunk></DeviceSlot></FilterDevicePreset>',
    parameters = {
      { name = "Slope", value = 0.5, is_automatable = true,
        value_quantum = 0.5, value_string = "24 dB/oct" },
    } }
  local track = {
    devices = { [1] = {}, [2] = old_dev },
    insert_device_at = function(self, _path, index)
      table.insert(self.devices, index, new_dev)
      return new_dev
    end,
    delete_device_at = function(self, index) table.remove(self.devices, index) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/Saturn2-old.vst", device_name = "VST: FabFilter: Saturn 2",
    analysis = analyze("VST: FabFilter: Saturn 2", "/P/Saturn2-old.vst", "VST") }
  local candidate = { name = "FabFilter Saturn 2", protocol = "VST", path = "/P/Saturn2.vst" }

  local ok, res = pcall(function() return up_swap.swap_track_device(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-parameter-synth", "the slope-bank overlay completes")
  check(math.abs(new_state.value - 0.75) < 0.000001,
    "24 dB/oct is remapped by label instead of replayed as 18 dB/oct")
  check(new_state.value ~= 0.5, "the old normalized value must not select 18 dB/oct")
end

section("up_swap writes a continuous value displayed as an integer")
do
  -- An integer-formatted display ("40") can belong to a continuous control, not
  -- a discrete option bank. The replacement has a far finer quantum, so a
  -- coincident "40" display must not count as transferred; the saved 0.4 is
  -- written instead of leaving the replacement's 0.404 in place.
  local new_state = { value = 0.404 }
  local new_param = setmetatable({}, {
    __index = function(_, key)
      if key == "name" then return "Level" end
      if key == "is_automatable" then return true end
      if key == "value" then return new_state.value end
      if key == "value_string" then return string.format("%.0f", new_state.value * 100) end
      if key == "value_quantum" then return 0.000001 end
      if key == "value_min" then return 0 end
      if key == "value_max" then return 1 end
      return nil
    end,
    __newindex = function(_, key, new_value)
      if key == "value" then
        new_state.value = new_value
      else
        error("read-only " .. key)
      end
    end,
  })
  local new_dev = { is_active = true, active_preset_data = "", presets = {},
    parameters = { new_param } }
  local old_dev = { is_active = true, active_preset_data = '<FilterDevicePreset><DeviceSlot>'
      .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
      .. '<ParameterChunk><![CDATA[]]></ParameterChunk></DeviceSlot></FilterDevicePreset>',
    parameters = {
      { name = "Level", value = 0.4, is_automatable = true,
        value_quantum = 0.01, value_string = "40" },
    } }
  local track = {
    devices = { [1] = {}, [2] = old_dev },
    insert_device_at = function(self, _path, index)
      table.insert(self.devices, index, new_dev)
      return new_dev
    end,
    delete_device_at = function(self, index) table.remove(self.devices, index) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/Saturn2-old.vst", device_name = "VST: FabFilter: Saturn 2",
    analysis = analyze("VST: FabFilter: Saturn 2", "/P/Saturn2-old.vst", "VST") }
  local candidate = { name = "FabFilter Saturn 2", protocol = "VST", path = "/P/Saturn2.vst" }

  local ok, res = pcall(function() return up_swap.swap_track_device(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-parameter-synth", "the integer-display overlay completes")
  check(math.abs(new_state.value - 0.4) < 0.000001,
    "a coincident integer display does not skip the numeric write")
end

section("up_swap transplants a compatible bag when the replacement mapping is incomplete")
do
  -- A complete source snapshot does not guarantee the replacement can restore
  -- every control: a renamed or non-automatable target control is omitted from
  -- the name mapping. The compatible ParameterBag must be transplanted so those
  -- saved values are not lost when the old device is removed.
  local bag = '<FilterDevicePreset><DeviceSlot>'
    .. '<ParameterChunkType>ParameterBag</ParameterChunkType>'
    .. '<ParameterChunk><![CDATA[]]></ParameterChunk></DeviceSlot></FilterDevicePreset>'
  local new_dev = { is_active = true, active_preset_data = "", presets = {},
    parameters = { { name = "Mix", value = 0.5, is_automatable = true } } }
  local old_dev = { is_active = true, presets = {}, active_preset_data = bag,
    parameters = {
      { name = "Mix", value = 0.7, is_automatable = true },
      { name = "Gain", value = 0.3, is_automatable = true },
    } }
  local track = {
    devices = { [1] = {}, [2] = old_dev },
    insert_device_at = function(self, _path, index)
      table.insert(self.devices, index, new_dev); return new_dev
    end,
    delete_device_at = function(self, index) table.remove(self.devices, index) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/Saturn2-old.vst", device_name = "VST: FabFilter: Saturn 2",
    analysis = analyze("VST: FabFilter: Saturn 2", "/P/Saturn2-old.vst", "VST") }
  local candidate = analyze("VST: FabFilter: Saturn 2", "/P/Saturn2.vst", "VST")
  candidate.path = "/P/Saturn2.vst"

  local ok, res = pcall(function() return up_swap.swap_track_device(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-with-parameters",
    "an unmappable replacement control keeps the compatible direct transplant")
  check(new_dev.active_preset_data == bag, "the unmapped control's saved value is preserved")
end
