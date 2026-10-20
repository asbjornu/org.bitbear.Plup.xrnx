-- Tests for up_midi: the MIDI loopback used to select a container's snapshot
-- bank by sending Bank Select + Program Change.

section("up_midi.ready reflects loopback availability")
do
  local real_midi = renoise.Midi
  local previous = up_midi.device_name
  up_midi.set_device(nil)
  renoise.Midi = nil
  check(up_midi.ready() == false, "no loopback port -> not ready")
  check(up_midi.has_loopback() == false, "has_loopback mirrors ready (unavailable)")
  -- An output alone is not enough: Renoise must also receive the port as an
  -- input for the bank messages to reach the plugin.
  renoise.Midi = { available_output_devices = function() return { "IAC Driver Bus 1" } end,
    available_input_devices = function() return {} end }
  check(up_midi.ready() == false, "output without a matching input -> not ready")
  -- Mismatched IAC buses are not a working route: we send on one port and Renoise
  -- receives another, so the bank messages never reach the plugin.
  renoise.Midi = {
    available_output_devices = function() return { "IAC Driver Bus 1" } end,
    available_input_devices = function() return { "IAC Driver Bus 2" } end,
  }
  check(up_midi.ready() == false, "unpaired IAC buses -> not ready")
  renoise.Midi = {
    available_output_devices = function() return { "IAC Driver Bus 1" } end,
    available_input_devices = function() return { "IAC Driver Bus 1" } end,
  }
  check(up_midi.ready() == true, "an IAC loopback port (in + out) -> ready")
  check(up_midi.has_loopback() == true, "has_loopback mirrors ready (available)")
  up_midi.set_device(previous)
  renoise.Midi = real_midi
end

section("up_midi.select_program sends bank select and program change")
do
  local sent = {}
  local real_midi = renoise.Midi
  renoise.Midi = {
    available_output_devices = function() return { "IAC Driver Bus 1" } end,
    create_output_device = function(_name)
      return {
        send = function(_, message) sent[#sent + 1] = message end,
        close = function() end,
      }
    end,
  }
  local previous = up_midi.device_name
  up_midi.set_device(nil)
  local ok = up_midi.select_program(5, 38)
  check(ok, "select_program reports success with a loopback device")
  check(#sent == 3, "bank MSB, bank LSB and program change are sent")
  check(sent[1] and sent[1][1] == 0xB0 and sent[1][2] == 0 and sent[1][3] == 0,
    "bank select MSB is 0 for the low banks Reaktor uses")
  check(sent[2] and sent[2][1] == 0xB0 and sent[2][2] == 32 and sent[2][3] == 5,
    "bank select LSB carries the bank number")
  check(sent[3] and sent[3][1] == 0xC0 and sent[3][2] == 38,
    "program change carries the program number")
  up_midi.set_device(previous)
  renoise.Midi = real_midi
end

section("up_midi.select_bank sends only bank select")
do
  local sent = {}
  local real_midi = renoise.Midi
  renoise.Midi = {
    available_output_devices = function() return { "IAC Driver Bus 1" } end,
    create_output_device = function(_name)
      return { send = function(_, message) sent[#sent + 1] = message end, close = function() end }
    end,
  }
  local previous = up_midi.device_name
  up_midi.set_device(nil)
  local ok = up_midi.select_bank(5)
  check(ok, "select_bank reports success with a loopback device")
  check(#sent == 2, "only the two bank select messages are sent")
  check(sent[1] and sent[1][1] == 0xB0 and sent[1][2] == 0 and sent[1][3] == 0,
    "bank select MSB is 0")
  check(sent[2] and sent[2][1] == 0xB0 and sent[2][2] == 32 and sent[2][3] == 5,
    "bank select LSB carries the bank number")
  up_midi.set_device(previous)
  renoise.Midi = real_midi
end

section("up_swap matches a snapshot whose name drops the spaces")
do
  -- Reaktor snapshot "DeepPulse" vs Renoise instrument "Deep Pulse Saw".
  local real_device, real_bank = up_midi.device, up_midi.select_bank
  local real_ready = up_midi.has_loopback
  local real_chunk_for = up_donor.chunk_for
  up_donor.chunk_for = function() return nil end
  local state = { bank = -1, program = -1 }
  up_midi.device = function() return "loopback" end
  up_midi.has_loopback = function() return true end
  up_midi.select_bank = function(bank) state.bank = bank; return true end
  local function wrapper(chunk)
    return '<?xml version="1.0"?><FilterDevicePreset><DeviceSlot><ParameterChunk><![CDATA['
      .. up_preset.encode_chunk(chunk) .. ']]></ParameterChunk></DeviceSlot></FilterDevicePreset>'
  end
  local new_dev = setmetatable({ parameters = {} }, {
    __index = function(_, key)
      if key == "active_preset_data" then
        return (state.bank == 2 and state.program == 14)
          and wrapper("DeepPulse") or wrapper("Work the Mod Wheel Bass")
      end
      return nil
    end,
    __newindex = function(_, key, value)
      if key == "active_preset" then state.program = value
      else rawset(_, key, value) end
    end,
  })
  local pp = { plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _p) self.plugin_device = new_dev; return true end }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "Deep Pulse Saw", active_preset_name = "Razor", active_preset = 14,
    ensemble_preset = true,
    analysis = analyze("VST: Native Instruments: Reaktor5", nil, "VST"), device_path = nil }
  local candidate = analyze("VST3: Native Instruments: Reaktor 6", "/P/Reaktor6.vst3", "VST3")
  candidate.path = "/P/Reaktor6.vst3"
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res ~= nil, "swap_instrument completes")
  check(state.bank == 2 and state.program == 14,
    "the compacted snapshot name resolves the correct bank and program")
  up_midi.device, up_midi.select_bank = real_device, real_bank
  up_midi.has_loopback = real_ready
  up_donor.chunk_for = real_chunk_for
end

section("up_swap discovers the snapshot bank via the MIDI loopback")
do
  local real_device, real_bank = up_midi.device, up_midi.select_bank
  local real_ready = up_midi.has_loopback
  local real_chunk_for = up_donor.chunk_for
  up_donor.chunk_for = function() return nil end -- no transplant, keep the mock dynamic
  local state = { bank = -1, program = -1 }
  up_midi.device = function() return "loopback" end
  up_midi.has_loopback = function() return true end
  up_midi.select_bank = function(bank)
    state.bank = bank
    return true
  end
  -- active_preset_data is the XML wrapper with a base64 <ParameterChunk>, and the
  -- snapshot name lives inside that binary chunk, so the bank is confirmed by
  -- decoding the chunk and finding the patch name.
  local function wrapper(chunk)
    return '<?xml version="1.0"?><FilterDevicePreset><DeviceSlot><ParameterChunk><![CDATA['
      .. up_preset.encode_chunk(chunk) .. ']]></ParameterChunk></DeviceSlot></FilterDevicePreset>'
  end
  local new_dev = setmetatable({ parameters = {} }, {
    __index = function(_, key)
      if key == "active_preset_data" then
        return (state.bank == 5 and state.program == 38) and wrapper("Sad Star") or wrapper("Victory")
      end
      return nil
    end,
    __newindex = function(_, key, value)
      if key == "active_preset" then state.program = value
      else rawset(_, key, value) end
    end,
  })
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
  check(ok and res ~= nil, "swap_instrument completes with a MIDI loopback")
  check(state.bank == 5 and state.program == 38,
    "the bank carrying the patch name is selected")
  up_midi.device, up_midi.select_bank = real_device, real_bank
  up_midi.has_loopback = real_ready
  up_donor.chunk_for = real_chunk_for
end

section("up_swap yields to the scheduler while scanning banks")
do
  -- The bank/program scan is a synchronous brute force whose per-attempt chunk
  -- read is heavy, so it must yield between attempts when the upgrade runs inside
  -- the scheduler coroutine -- otherwise it can monopolize one idle tick and trip
  -- Renoise's script-busy watchdog.
  local real_device, real_bank = up_midi.device, up_midi.select_bank
  local real_ready = up_midi.has_loopback
  local real_chunk_for = up_donor.chunk_for
  up_donor.chunk_for = function() return nil end
  local state = { bank = -1, program = -1 }
  up_midi.device = function() return "loopback" end
  up_midi.has_loopback = function() return true end
  up_midi.select_bank = function(bank) state.bank = bank; return true end
  local function wrapper(chunk)
    return '<?xml version="1.0"?><FilterDevicePreset><DeviceSlot><ParameterChunk><![CDATA['
      .. up_preset.encode_chunk(chunk) .. ']]></ParameterChunk></DeviceSlot></FilterDevicePreset>'
  end
  local new_dev = setmetatable({ parameters = {} }, {
    __index = function(_, key)
      if key == "active_preset_data" then
        return (state.bank == 12 and state.program == 38) and wrapper("Sad Star") or wrapper("Victory")
      end
      return nil
    end,
    __newindex = function(_, key, value)
      if key == "active_preset" then state.program = value
      else rawset(_, key, value) end
    end,
  })
  local pp = { plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _p) self.plugin_device = new_dev; return true end }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "Sad Star", active_preset_name = "Razor", active_preset = 38,
    ensemble_preset = true,
    analysis = analyze("VST: Native Instruments: Reaktor5", nil, "VST"), device_path = nil }
  local candidate = analyze("VST3: Native Instruments: Reaktor 6", "/P/Reaktor6.vst3", "VST3")
  candidate.path = "/P/Reaktor6.vst3"
  -- Drive the swap from a coroutine; count the yields the scan performs.
  local yields = 0
  local thread = coroutine.create(function()
    return up_swap.swap_instrument(song, rec, candidate)
  end)
  local res
  while coroutine.status(thread) == "suspended" do
    local ok, value = coroutine.resume(thread)
    check(ok, "the scan coroutine resumes without error")
    if not ok then break end
    if coroutine.status(thread) == "suspended" then yields = yields + 1 end
    res = value
  end
  check(yields >= 1, "the bank scan yields to the scheduler at least once")
  check(res and state.bank == 12 and state.program == 38,
    "the scan still finds the bank after yielding")
  up_midi.device, up_midi.select_bank = real_device, real_bank
  up_midi.has_loopback = real_ready
  up_donor.chunk_for = real_chunk_for
end

section("up_midi.select_bank reports failure when the send fails")
do
  -- A pcall that swallows a failed send would make the bank scan believe it
  -- moved the bank; the send result must propagate.
  local real_midi = renoise.Midi
  renoise.Midi = {
    available_output_devices = function() return { "IAC Driver Bus 1" } end,
    create_output_device = function(_name)
      return { send = function() error("device disconnected") end, close = function() end }
    end,
  }
  local previous = up_midi.device_name
  up_midi.set_device(nil)
  check(up_midi.select_bank(5) == false, "a failed bank-select send reports false")
  check(up_midi.select_program(5, 1) == false, "a failed program-change send reports false")
  up_midi.set_device(previous)
  renoise.Midi = real_midi
end

section("up_midi.input_device returns nil without an enabled input")
do
  local real_midi = renoise.Midi
  local previous = up_midi.device_name
  up_midi.set_device("IAC Driver Bus 1")
  -- An output exists but Renoise has no matching input: the route is unusable, so
  -- input_device must not fall back to the output name.
  renoise.Midi = { available_output_devices = function() return { "IAC Driver Bus 1" } end,
    available_input_devices = function() return {} end }
  check(up_midi.input_device() == nil, "no enabled input -> nil (no output fallback)")
  up_midi.set_device(previous)
  renoise.Midi = real_midi
end

section("up_swap aborts the bank scan when bank select fails")
do
  -- If the Bank Select cannot be sent the host stays on the previous bank, so the
  -- scan must stop rather than read (and possibly report) the wrong bank.
  local real_device, real_bank = up_midi.device, up_midi.select_bank
  local real_ready = up_midi.has_loopback
  local real_chunk_for = up_donor.chunk_for
  up_donor.chunk_for = function() return nil end
  up_midi.device = function() return "loopback" end
  up_midi.has_loopback = function() return true end
  local bank_calls, read_calls = 0, 0
  up_midi.select_bank = function() bank_calls = bank_calls + 1; return false end
  local new_dev = setmetatable({ parameters = {} }, {
    __index = function(_, key)
      if key == "active_preset_data" then read_calls = read_calls + 1; return "<ParameterChunk/>" end
      return nil
    end,
    __newindex = function(_, key, value) rawset(_, key, value) end,
  })
  local pp = { plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _p) self.plugin_device = new_dev; return true end }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "Sad Star", active_preset_name = "Razor", active_preset = 38,
    ensemble_preset = true,
    analysis = analyze("VST: Native Instruments: Reaktor5", nil, "VST"), device_path = nil }
  local candidate = analyze("VST3: Native Instruments: Reaktor 6", "/P/Reaktor6.vst3", "VST3")
  candidate.path = "/P/Reaktor6.vst3"
  local ok = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok, "the swap completes despite the failed bank select")
  check(read_calls == 0,
    "no chunk is read after the bank select fails (the scan aborted)")
  check(bank_calls <= 2, "each scan pass attempts at most one bank select")
  up_midi.device, up_midi.select_bank = real_device, real_bank
  up_midi.has_loopback = real_ready
  up_donor.chunk_for = real_chunk_for
end

