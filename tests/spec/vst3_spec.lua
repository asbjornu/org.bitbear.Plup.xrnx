-- Tests for lib/up_vst3.lua (the .vstpreset container reader/writer) and for
-- carrying plugin state across a VST2 <-> VST3 upgrade of the same product.

local up_vst3 = require("up_vst3")

local CLASS_ID = "5653544E69324D617373697665202020" -- 32 hex chars

local function parameter(name, value, automatable_error)
  local entry = { name = name, value = value }
  if automatable_error then
    return setmetatable(entry, {
      __index = function(_, key)
        if key == "is_automatable" then
          error("is_automatable is not valid for instrument devices")
        end
      end,
    })
  end
  entry.is_automatable = true
  return entry
end

local function b64(data)
  return up_preset.encode_chunk(data)
end

local function wrapper_with_chunk(chunk)
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
    .. '<FilterDevicePreset doc_version="14"><DeviceSlot type="AudioPluginDevice">'
    .. '<PluginType>VST3</PluginType><PluginIdentifier>' .. CLASS_ID .. '</PluginIdentifier>'
    .. '<ParameterChunk><![CDATA[' .. b64(chunk) .. ']]></ParameterChunk>'
    .. '</DeviceSlot></FilterDevicePreset>'
end

local function chunk_from_wrapper(xml)
  local cdata = xml:match("<ParameterChunk>%s*<!%[CDATA%[(.-)%]%]>%s*</ParameterChunk>")
  if not cdata then return nil end
  return up_preset.decode_chunk(cdata)
end

section("up_vst3 reads and rebuilds a preset container")
do
  local component = "\1component-state"
  local preset = up_vst3.build(1, CLASS_ID, {
    { id = "Cont", data = "" },
    { id = "Comp", data = component },
  })
  check(preset ~= nil, "build returns a preset container")
  local parsed = up_vst3.parse(preset)
  check(parsed ~= nil, "parse accepts a built container")
  check(parsed and parsed.class_id == CLASS_ID, "parse keeps the class id")
  check(up_vst3.component(preset) == component, "component returns the Comp chunk")

  local replaced = up_vst3.replace_component(preset, "\1new-state")
  check(replaced ~= nil, "replace_component returns a new container")
  check(up_vst3.component(replaced) == "\1new-state", "replace_component swaps only the state")
  local parsed_replaced = up_vst3.parse(replaced)
  check(parsed_replaced and parsed_replaced.class_id == CLASS_ID, "class id survives a replacement")
  check(parsed_replaced and #parsed_replaced.chunks == 2, "other chunks survive a replacement")
  check(up_vst3.parse("not a preset") == nil, "parse rejects non-preset data")
  check(up_vst3.build(1, "short", {}) == nil, "build rejects an invalid class id")

  local without_component = up_vst3.build(1, CLASS_ID, { { id = "Cont", data = "" } })
  local added = up_vst3.replace_component(without_component, "\1added-state")
  check(up_vst3.component(added) == "\1added-state",
    "replace_component adds a missing Comp chunk")
end

section("up_swap carries instrument parameters when is_automatable is invalid")
do
  -- Renoise documents is_automatable as invalid for instrument devices. Reading
  -- it throws, so the old code captured no instrument parameters at all and the
  -- replacement opened at its defaults -- e.g. Massive VST -> VST3.
  local old_param = parameter("OSC1 Wt-position", 0.42, true)
  local new_param = parameter("OSC1 Wt-position", 0.1, true)
  local new_dev = {
    is_active = true, active_preset_data = "", presets = {},
    parameters = { new_param },
  }
  local old_dev = {
    is_active = true, active_preset_data = "", presets = {},
    parameters = { old_param },
  }
  local pp = {
    plugin_loaded = true, plugin_device = old_dev,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = {
    kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "Massive Bass", device_path = nil,
    analysis = analyze("VST: Native Instruments Massive", "/P/Massive.vst", "VST"),
  }
  local candidate = analyze("VST3: Native Instruments Massive", "/P/Massive.vst3", "VST3")
  candidate.path = "/P/Massive.vst3"
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok, "swap_instrument handles instrument parameters without is_automatable")
  check(ok and res and res.status == "upgraded-parameter-synth",
    "instrument parameters are captured and re-applied")
  check(new_param.value == 0.42, "the old parameter value is written to the replacement")
end

section("up_swap matches cross-format parameter names case/punctuation-insensitively")
do
  local old_param = parameter("OSC1 Wt-position", 0.42, true)
  local new_param = parameter("OSC 1 WT Position", 0.1, true)
  local new_dev = {
    is_active = true, active_preset_data = "", presets = {},
    parameters = { new_param },
  }
  local old_dev = {
    is_active = true, active_preset_data = "", presets = {},
    parameters = { old_param },
  }
  local pp = {
    plugin_loaded = true, plugin_device = old_dev,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = {
    kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "Massive Bass", device_path = nil,
    analysis = analyze("VST: Native Instruments Massive", "/P/Massive.vst", "VST"),
  }
  local candidate = analyze("AU: Native Instruments Massive", "/P/Massive.au", "AU")
  candidate.path = "/P/Massive.au"
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-parameter-synth",
    "renamed parameters still match by normalized name")
  check(new_param.value == 0.42, "the renamed parameter receives the old value")
end

section("up_swap converts a broken VST2 plugin's saved chunk to VST3")
do
  -- If Massive VST2 is no longer installed, its only remaining state is the
  -- chunk recovered from Song.xml; the replacement must still get the patch.
  local old_chunk = "\1MASSIVE-SAVED-STATE"
  local base_preset = up_vst3.build(1, CLASS_ID, {
    { id = "Comp", data = "\1MASSIVE-DEFAULT" },
  })
  local new_dev = {
    is_active = true, presets = {}, parameters = {},
    active_preset_data = wrapper_with_chunk(base_preset),
  }
  local pp = {
    plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = {
    kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "Massive Bass", active_preset_data = old_chunk, device_path = nil,
    analysis = analyze("VST: Native Instruments Massive", nil, "VST"),
  }
  local candidate = analyze("VST3: Native Instruments Massive", "/P/Massive.vst3", "VST3")
  candidate.path = "/P/Massive.vst3"
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-with-parameters",
    "the recovered VST2 chunk is transplanted into the VST3 plugin")
  check(up_vst3.component(chunk_from_wrapper(new_dev.active_preset_data)) == old_chunk,
    "the saved engine state ends up in the VST3 component chunk")
end

section("up_swap falls back when a converted chunk is ignored")
do
  -- A container that the plugin rejects still reads back non-empty, so the
  -- transplant is only trusted when a captured parameter value actually
  -- survived. Here the plugin ignores it and the overlay must restore the value.
  local old_chunk = "\1MASSIVE-VST2-STATE"
  local base_preset = up_vst3.build(1, CLASS_ID, {
    { id = "Comp", data = "\1MASSIVE-DEFAULT" },
  })
  local old_param = parameter("Cutoff", 0.3, true)
  local new_param = parameter("Cutoff", 0.9, true)
  -- An unchanged default must not be mistaken for evidence that the chunk was
  -- restored; only Cutoff differs between source and replacement.
  local old_bypass = parameter("Bypass", 0, true)
  local new_bypass = parameter("Bypass", 0, true)
  local old_dev = {
    is_active = true, presets = {}, parameters = { old_param, old_bypass },
    active_preset_data = wrapper_with_chunk(old_chunk),
  }
  local new_dev = {
    is_active = true, presets = {}, parameters = { new_param, new_bypass },
    active_preset_data = wrapper_with_chunk(base_preset),
  }
  local pp = {
    plugin_loaded = true, plugin_device = old_dev,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = {
    kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "Massive Bass", device_path = nil,
    analysis = analyze("VST: Native Instruments Massive", "/P/Massive.vst", "VST"),
  }
  local candidate = analyze("VST3: Native Instruments Massive", "/P/Massive.vst3", "VST3")
  candidate.path = "/P/Massive.vst3"
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-parameter-synth",
    "an ignored converted chunk falls back to the parameter overlay")
  check(new_param.value == 0.3, "the fallback still restores the old parameter value")
  check(new_bypass.value == 0, "the unchanged default does not mask the mismatch")
end

section("up_swap converts a VST3 preset back into a VST2 chunk")
do
  local old_component = "\1MASSIVE-VST3-STATE"
  local preset = up_vst3.build(1, CLASS_ID, {
    { id = "Comp", data = old_component },
  })
  local old_dev = {
    is_active = true, presets = {}, parameters = {},
    active_preset_data = wrapper_with_chunk(preset),
  }
  local new_dev = {
    is_active = true, presets = {}, parameters = {},
    active_preset_data = '<?xml version="1.0" encoding="UTF-8"?>\n'
      .. '<FilterDevicePreset doc_version="14"><DeviceSlot type="AudioPluginDevice">'
      .. '<PluginType>VST</PluginType><ParameterChunk/></DeviceSlot></FilterDevicePreset>',
  }
  local pp = {
    plugin_loaded = true, plugin_device = old_dev,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = {
    kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "Massive Bass", device_path = nil,
    analysis = analyze("VST3: Native Instruments Massive", "/P/Massive.vst3", "VST3"),
  }
  local candidate = analyze("VST: Native Instruments Massive", "/P/Massive.vst", "VST")
  candidate.path = "/P/Massive.vst"
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-with-parameters",
    "a VST3 preset is transplanted into the VST2 device")
  check(chunk_from_wrapper(new_dev.active_preset_data) == old_component,
    "the VST3 component chunk becomes the raw VST2 chunk")
end

section("up_swap converts a VST2 chunk into a VST3 preset container")
do
  -- A same-product, same-version VST2 -> VST3 upgrade must not write the raw
  -- VST2 chunk into the VST3 wrapper (Renoise expects a .vstpreset there).
  -- Put the engine state into the replacement container's Comp chunk instead.
  local old_chunk = "\1MASSIVE-VST2-STATE"
  local default_component = "\1MASSIVE-DEFAULT"
  local base_preset = up_vst3.build(1, CLASS_ID, {
    { id = "Cont", data = "" },
    { id = "Comp", data = default_component },
  })
  local old_dev = {
    is_active = true, presets = {}, parameters = {},
    active_preset_data = wrapper_with_chunk(old_chunk),
  }
  local new_dev = {
    is_active = true, presets = {}, parameters = {},
    active_preset_data = wrapper_with_chunk(base_preset),
  }
  local pp = {
    plugin_loaded = true, plugin_device = old_dev,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = {
    kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "Massive Bass", device_path = nil,
    analysis = analyze("VST: Native Instruments Massive", "/P/Massive.vst", "VST"),
  }
  local candidate = analyze("VST3: Native Instruments Massive", "/P/Massive.vst3", "VST3")
  candidate.path = "/P/Massive.vst3"
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-with-parameters",
    "a compatible VST2 chunk is transplanted through the VST3 container")
  local converted = chunk_from_wrapper(new_dev.active_preset_data)
  check(converted ~= nil and up_vst3.parse(converted) ~= nil,
    "the replacement now holds a valid .vstpreset")
  check(up_vst3.component(converted) == old_chunk,
    "the old VST2 state becomes the VST3 component chunk")
  local parsed = up_vst3.parse(converted)
  check(parsed and parsed.class_id == CLASS_ID, "the replacement's class id is preserved")
  check(parsed and #parsed.chunks == 2, "other preset chunks are preserved")
end

section("up_swap rejects chunk conversion between different products")
do
  -- same_family() is deliberately loose enough for candidate discovery, but
  -- "Massive" and "Massive X" are different synths whose chunk layouts are not
  -- interchangeable. Chunk transfer must require the stricter product match.
  local old_chunk = "\1MASSIVE-VST2-STATE"
  local base_preset = up_vst3.build(1, CLASS_ID, {
    { id = "Comp", data = "\1MASSIVE-X-DEFAULT" },
  })
  local base_wrapper = wrapper_with_chunk(base_preset)
  local old_dev = {
    is_active = true, presets = {}, parameters = {},
    active_preset_data = wrapper_with_chunk(old_chunk),
  }
  local new_dev = {
    is_active = true, presets = {}, parameters = {},
    active_preset_data = base_wrapper,
  }
  local pp = {
    plugin_loaded = true, plugin_device = old_dev,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = {
    kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "Massive Bass", device_path = nil,
    analysis = analyze("VST: Native Instruments: Massive", "/P/Massive.vst", "VST"),
  }
  local candidate = analyze("VST3: Native Instruments: Massive X", "/P/MassiveX.vst3", "VST3")
  candidate.path = "/P/MassiveX.vst3"
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-default",
    "Massive -> Massive X does not claim a chunk transfer")
  check(new_dev.active_preset_data == base_wrapper,
    "the unrelated product's chunk is left untouched")
end

section("up_swap rejects chunk conversion across attached versions")
do
  local function version_case(old_name, new_name, expect_converted)
    local old_chunk = "\1KONTAKT-STATE"
    local base_preset = up_vst3.build(1, CLASS_ID, {
      { id = "Comp", data = "\1KONTAKT-DEFAULT" },
    })
    local base_wrapper = wrapper_with_chunk(base_preset)
    local old_dev = {
      is_active = true, presets = {}, parameters = {},
      active_preset_data = wrapper_with_chunk(old_chunk),
    }
    local new_dev = {
      is_active = true, presets = {}, parameters = {},
      active_preset_data = base_wrapper,
    }
    local pp = {
      plugin_loaded = true, plugin_device = old_dev,
      load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
    }
    local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
    local rec = {
      kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
      instrument_name = old_name, device_path = nil,
      analysis = analyze("VST: Native Instruments " .. old_name, "/P/Kontakt.vst", "VST"),
    }
    local candidate = analyze("VST3: Native Instruments " .. new_name,
      "/P/Kontakt.vst3", "VST3")
    candidate.path = "/P/Kontakt.vst3"
    local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
    if expect_converted then
      check(ok and res and res.status == "upgraded-with-parameters",
        old_name .. " -> " .. new_name .. " converts at the same version")
      check(up_vst3.component(chunk_from_wrapper(new_dev.active_preset_data)) == old_chunk,
        old_name .. " state is moved into the VST3 container")
    else
      check(ok and res and res.status == "upgraded-default",
        old_name .. " -> " .. new_name .. " does not convert")
      check(new_dev.active_preset_data == base_wrapper,
        old_name .. " -> " .. new_name .. " leaves the replacement untouched")
    end
  end
  version_case("Kontakt6", "Kontakt7", false)
  version_case("Kontakt 6", "Kontakt 7", false)
  version_case("Kontakt6", "Kontakt6", true)
end

section("up_swap injects a VST3 donor container directly")
do
  -- The bundled Reaktor donor is already a complete .vstpreset. A same-version
  -- VST2 -> VST3 swap must inject that container as-is, not nest the whole
  -- container inside the replacement's Comp chunk.
  local donor = up_vst3.build(1, CLASS_ID, {
    { id = "Cont", data = "" },
    { id = "Comp", data = "\1REAKTOR-DONOR" },
  })
  local real_chunk_for = up_donor.chunk_for
  up_donor.chunk_for = function() return donor end
  local base_preset = up_vst3.build(1, CLASS_ID, {
    { id = "Comp", data = "\1REAKTOR-DEFAULT" },
  })
  local old_raw = "\0\0file://localhost/Users/Shared/Razor/Razor.rkplr\0\0"
  local new_dev = {
    is_active = true, presets = {}, parameters = {},
    active_preset_data = wrapper_with_chunk(base_preset),
  }
  local pp = {
    plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = {
    kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "Dark Dreams 1", active_preset_name = "Razor", active_preset = 48,
    ensemble_preset = true, active_preset_data = old_raw, device_path = nil,
    analysis = analyze("VST: Native Instruments: Reaktor 6", "/P/Reaktor6.vst", "VST"),
  }
  local candidate = analyze("VST3: Native Instruments: Reaktor 6",
    "/P/Reaktor6.vst3", "VST3")
  candidate.path = "/P/Reaktor6.vst3"
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-with-parameters",
    "the same-version Reaktor donor is transplanted")
  check(chunk_from_wrapper(new_dev.active_preset_data) == donor,
    "the VST3 donor container is injected directly")
  up_donor.chunk_for = real_chunk_for
end

section("up_swap reserves exact parameter matches before normalized fallback")
do
  -- "Cut-off" must not overwrite the exact "Cutoff" match just because both
  -- normalize to the same key.
  local old_cutoff = parameter("Cutoff", 0.8, true)
  local old_cutoff_dash = parameter("Cut-off", 0.2, true)
  local new_cutoff = parameter("Cutoff", 0.1, true)
  local old_dev = {
    is_active = true, active_preset_data = "", presets = {},
    parameters = { old_cutoff, old_cutoff_dash },
  }
  local new_dev = {
    is_active = true, active_preset_data = "", presets = {},
    parameters = { new_cutoff },
  }
  local pp = {
    plugin_loaded = true, plugin_device = old_dev,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = {
    kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "Massive Bass", device_path = nil,
    analysis = analyze("VST: Native Instruments: Massive", "/P/Massive.vst", "VST"),
  }
  local candidate = analyze("AU: Native Instruments: Massive", "/P/Massive.au", "AU")
  candidate.path = "/P/Massive.au"
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-parameter-synth",
    "the colliding source names fall back to parameter overlay")
  check(new_cutoff.value == 0.8,
    "the exact Cutoff match wins over the normalized Cut-off match")
end

section("up_swap keeps rejected modes for recovered VST3 state")
do
  -- A missing VST3 instrument stores a raw .vstpreset. That must not be treated
  -- like an explicitly selected donor and override the version/product guard.
  local old_preset = up_vst3.build(1, CLASS_ID, {
    { id = "Comp", data = "\1KONTAKT-6-STATE" },
  })
  local base_preset = up_vst3.build(1, CLASS_ID, {
    { id = "Comp", data = "\1KONTAKT-7-DEFAULT" },
  })

  local function missing_case(candidate_name, candidate_protocol, candidate_path)
    local base_wrapper = wrapper_with_chunk(base_preset)
    local new_dev = {
      is_active = true, presets = {}, parameters = {},
      active_preset_data = base_wrapper,
    }
    local pp = {
      plugin_loaded = false, plugin_device = nil,
      load_plugin = function(self, _p) self.plugin_device = new_dev; return true end,
    }
    local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
    local rec = {
      kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
      instrument_name = "Kontakt6", active_preset_data = old_preset, device_path = nil,
      analysis = analyze("VST3: Native Instruments Kontakt 6", nil, "VST3"),
    }
    local candidate = analyze(candidate_name, candidate_path, candidate_protocol)
    candidate.path = candidate_path
    local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
    check(ok and res and res.status == "upgraded-default",
      "Kontakt 6 -> Kontakt 7 (" .. candidate_protocol .. ") does not claim a transfer")
    check(new_dev.active_preset_data == base_wrapper,
      "recovered Kontakt 6 state is not written into Kontakt 7 (" .. candidate_protocol .. ")")
  end

  missing_case("VST3: Native Instruments Kontakt 7", "VST3", "/P/Kontakt7.vst3")
  missing_case("VST: Native Instruments Kontakt 7", "VST", "/P/Kontakt7.vst")
end

section("up_swap accepts exact identity when product tokens are empty")
do
  -- "u-he ACE" is made entirely of words the candidate filter ignores, so the
  -- strict product check must fall back to the exact analyzed identity.
  local old_chunk = "\1ACE-STATE"
  local new_dev = {
    is_active = true, presets = {}, parameters = {},
    active_preset_data = wrapper_with_chunk("\1ACE-DEFAULT"),
  }
  local pp = {
    plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _p) self.plugin_device = new_dev; return true end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = {
    kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "ACE", active_preset_data = old_chunk, device_path = nil,
    analysis = analyze("VST3: u-he ACE", nil, "VST3"),
  }
  local candidate = analyze("VST3: u-he ACE", "/P/ACE.vst3", "VST3")
  candidate.path = "/P/ACE.vst3"
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-with-parameters",
    "a same-format exact identity still recovers its saved chunk")
  check(chunk_from_wrapper(new_dev.active_preset_data) == old_chunk,
    "the saved ACE chunk is written to the replacement")
end

section("up_swap tolerates parameter precision differences")
do
  -- The same setting can come back from VST3 with float rounding. That must not
  -- make a successful transplant look unrestored and trigger the overlay.
  local old_chunk = "\1MASSIVE-VST2-STATE"
  local base_preset = up_vst3.build(1, CLASS_ID, {
    { id = "Comp", data = "\1MASSIVE-DEFAULT" },
  })
  local old_param = parameter("Cutoff", 0.30000001192092896, true)
  local new_param = parameter("Cutoff", 0.9, true)
  local storage = { active_preset_data = wrapper_with_chunk(base_preset) }
  local new_dev = setmetatable(
    { is_active = true, presets = {}, parameters = { new_param } },
    {
      __index = function(_, key) return storage[key] end,
      __newindex = function(_, key, value)
        storage[key] = value
        if key == "active_preset_data" then new_param.value = 0.3 end
      end,
    })
  local old_dev = {
    is_active = true, presets = {}, parameters = { old_param },
    active_preset_data = wrapper_with_chunk(old_chunk),
  }
  local pp = {
    plugin_loaded = true, plugin_device = old_dev,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = {
    kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "Massive Bass", device_path = nil,
    analysis = analyze("VST: Native Instruments Massive", "/P/Massive.vst", "VST"),
  }
  local candidate = analyze("VST3: Native Instruments Massive", "/P/Massive.vst3", "VST3")
  candidate.path = "/P/Massive.vst3"
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-with-parameters",
    "float rounding does not reject a restored converted chunk")
  check(new_param.value == 0.3,
    "the restored parameter is not overwritten by the fallback overlay")
end

section("up_swap prefers the live preset over the instrument label")
do
  local function preset_case(bank, wanted_index)
    local new_dev = {
      is_active = true, active_preset_data = "", presets = bank, parameters = {} }
    local old_dev = {
      is_active = true, active_preset_data = "", presets = {}, parameters = {} }
    local pp = {
      plugin_loaded = true, plugin_device = old_dev,
      load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
    }
    local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
    local rec = {
      kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
      instrument_name = "VST: Massive (Bass)", active_preset_name = "Lead",
      analysis = analyze("VST: Native Instruments: Massive", "/P/Massive.vst", "VST"),
      device_path = nil,
    }
    local candidate = analyze("AU: Native Instruments: Massive", "/P/Massive.au", "AU")
    candidate.path = "/P/Massive.au"
    local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
    check(ok and res and res.status == "upgraded-name-matched-preset",
      "the replacement loads a preset by name")
    check(new_dev.active_preset == wanted_index,
      "the expected preset (" .. bank[wanted_index] .. ") is active")
  end

  -- The live preset must win even though the instrument label also exists.
  preset_case({ "Lead", "Bass" }, 1)
  -- The instrument label is still used when the live preset cannot be found.
  preset_case({ "Bass" }, 1)
end
