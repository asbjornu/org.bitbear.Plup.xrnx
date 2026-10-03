-- Tests for up_donor: borrowing a Reaktor 6 state chunk from a saved donor song
-- and injecting it during a same-family container upgrade.

section("up_donor.chunk_for extracts a Reaktor 6 chunk from a donor song")
do
  local donor_raw = "\0\0file://localhost/Users/Shared/Razor/Razor.rkplr\0\0"
  local donor_xml = '<?xml version="1.0"?><Song><Instrument>'
    .. '<Name>VST3: Reaktor 6 (Saladin)</Name>'
    .. '<PluginGenerator><PluginDevice><PluginType>VST3</PluginType>'
    .. '<PluginIdentifier>5653544E695236</PluginIdentifier>'
    .. '<PluginDisplayName>VST3: Native Instruments: Reaktor 6</PluginDisplayName>'
    .. '<ActiveProgram>48</ActiveProgram>'
    .. '<ParameterChunk><![CDATA[' .. up_preset.encode_chunk(donor_raw) .. ']]></ParameterChunk>'
    .. '</PluginDevice></PluginGenerator></Instrument></Song>'
  local real_extract = up_zip.extract
  up_zip.extract = function(_path, _entry) return donor_xml end
  up_donor.reset()
  up_donor.set_path("/tmp/donor.xrns")
  local data, program = up_donor.chunk_for("native instruments: reaktor", "Razor")
  check(data == donor_raw, "the donor Reaktor 6 chunk is decoded for injection")
  check(program == 48, "the donor's active program is returned")
  local missing = up_donor.chunk_for("fabfilter: pro-q", "Razor")
  check(missing == nil, "a different family finds no donor chunk")
  local wrong_ensemble = up_donor.chunk_for("native instruments: reaktor", "Prism")
  check(wrong_ensemble == nil, "a donor for another ensemble is not offered")
  local unknown_ensemble = up_donor.chunk_for("native instruments: reaktor")
  check(unknown_ensemble == nil,
    "the bundled donor is not offered when the instance's ensemble is unknown")
  up_zip.extract = real_extract
  up_donor.set_path(nil)
end

section("up_swap.swap_instrument prefers the snapshot name over an ambiguous number")
do
  -- Razor repeats program numbers across snapshot banks ("038 Palladion" in bank
  -- 4 vs "038 Sad Star" in bank 5), so the recorded number is ambiguous; the patch
  -- name must win.
  local real_chunk_for = up_donor.chunk_for
  up_donor.chunk_for = function() return nil end
  local new_dev = { is_active = true, active_preset_data = "",
    presets = { "038 Palladion", "003 Cinematic Pad", "038 Sad Star" }, parameters = {} }
  local pp = { plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _p) self.plugin_device = new_dev; return true end }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "Sad Star", active_preset_name = "Razor", active_preset = 38,
    ensemble_preset = true,
    analysis = analyze("VST: Native Instruments: Reaktor5", nil, "VST"), device_path = nil }
  local candidate = analyze("VST3: Native Instruments: Reaktor 6", "/P/Reaktor6.vst3", "VST3")
  candidate.path = "/P/Reaktor6.vst3"
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-name-matched-preset",
    "the snapshot is selected by name")
  check(new_dev.active_preset == 3, "the Sad Star entry (index 3) wins over program 38")
  up_donor.chunk_for = real_chunk_for
end

section("up_swap injects the donor chunk for a same-family container upgrade")
do
  -- A Reaktor 5 instance upgraded to Reaktor 6: the old chunk is rejected by
  -- Reaktor 6, so the donor song's Reaktor 6 chunk must be injected instead.
  local donor_raw = "\0\0file://localhost/Users/Shared/Razor/Razor.rkplr\0\0"
  local donor_b64 = up_preset.encode_chunk(donor_raw)
  local donor_xml = '<?xml version="1.0"?><Song><Instrument>'
    .. '<Name>VST3: Reaktor 6 (Saladin)</Name>'
    .. '<PluginGenerator><PluginDevice><PluginType>VST3</PluginType>'
    .. '<PluginDisplayName>VST3: Native Instruments: Reaktor 6</PluginDisplayName>'
    .. '<ActiveProgram>48</ActiveProgram>'
    .. '<ParameterChunk><![CDATA[' .. donor_b64 .. ']]></ParameterChunk>'
    .. '</PluginDevice></PluginGenerator></Instrument></Song>'
  local real_extract = up_zip.extract
  up_zip.extract = function(_path, _entry) return donor_xml end
  up_donor.reset()
  up_donor.set_path("/tmp/donor.xrns")

  local wrapper = '<?xml version="1.0" encoding="UTF-8"?><FilterDevicePreset doc_version="14">'
    .. '<DeviceSlot type="AudioPluginDevice"><PluginType>VST3</PluginType>'
    .. '<ParameterChunk><![CDATA[]]></ParameterChunk></DeviceSlot></FilterDevicePreset>'
  local new_dev = { is_active = true, active_preset_data = wrapper, presets = {}, parameters = {} }
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
  check(ok and res and res.status == "upgraded-with-parameters",
    "the donor chunk is injected and counts as a transfer")
  check(new_dev.active_preset_data:find(donor_b64, 1, true) ~= nil,
    "the donor's Reaktor 6 chunk is injected into the wrapper")
  check(new_dev.active_preset_data:find("<ActiveProgram>47</ActiveProgram>", 1, true) ~= nil,
    "the recorded program number is carried into the wrapper (0-based)")

  up_zip.extract = real_extract
  up_donor.set_path(nil)
end
