-- MIDI loopback output. Renoise has no API to inject MIDI into a hosted plugin,
-- but it can send to a system MIDI port, and Renoise can receive that port back
-- and forward program/bank changes to a plugin instrument. This lets a container
-- plugin's snapshot *bank* be selected (which the plugin API cannot do).
--
-- On macOS the port is typically "IAC Driver Bus 1"; we auto-pick the first
-- available output whose name mentions IAC, and require the *same* port to be
-- enabled as a Renoise input (see ready()).

local up_midi = {}

up_midi.device_name = nil
up_midi.channel = 0 -- 0-based; Renoise channel 1 == MIDI channel 0

local function available_outputs()
  local ok, devices = pcall(function() return renoise.Midi.available_output_devices() end)
  if not ok or type(devices) ~= "table" then return {} end
  return devices
end

local function available_inputs()
  local ok, devices = pcall(function() return renoise.Midi.available_input_devices() end)
  if not ok or type(devices) ~= "table" then return {} end
  return devices
end

local function is_iac(name)
  return type(name) == "string" and name:lower():find("iac") ~= nil
end

function up_midi.find_device()
  for _, name in ipairs(available_outputs()) do
    if is_iac(name) then
      return name
    end
  end
  return nil
end

function up_midi.device()
  if up_midi.device_name then return up_midi.device_name end
  up_midi.device_name = up_midi.find_device()
  return up_midi.device_name
end

-- The IAC input port that Renoise has enabled, if any. This is where the bank
-- messages we send must come back in for Renoise to forward them to a plugin.
function up_midi.find_input_device()
  for _, name in ipairs(available_inputs()) do
    if is_iac(name) then
      return name
    end
  end
  return nil
end

-- The input port paired with our output bus. Only a real enabled input is
-- returned: falling back to the output name would claim a route Renoise cannot
-- actually deliver, so callers can detect an unavailable route (nil) instead.
function up_midi.input_device()
  return up_midi.find_input_device()
end

-- True when the loopback route works end to end: an IAC output to send Bank
-- Select on, and the *same* port enabled as a Renoise input so the messages come
-- back and reach the plugin. With several buses an unmatched pair would send on
-- one port while Renoise receives a different one, so the names must agree.
-- Both are checked live, so a bus created/enabled after the tool loaded is seen.
function up_midi.ready()
  local output = up_midi.find_device()
  if not output then return false end
  local input = up_midi.find_input_device()
  if not input then return false end
  return output:lower() == input:lower()
end

-- Alias kept for readability at the call sites that decide whether a plugin's
-- snapshot bank can be addressed at all.
function up_midi.has_loopback()
  return up_midi.ready()
end

function up_midi.set_device(name)
  up_midi.device_name = (type(name) == "string" and name ~= "") and name or nil
end

-- Send only Bank Select MSB/LSB on the loopback port, so the plugin switches its
-- program bank while the host still owns the program change. Returns true only
-- when both messages were actually sent: a disconnected port otherwise makes the
-- bank scan believe it moved the bank and burn reads on the wrong one.
function up_midi.select_bank(bank)
  local name = up_midi.device()
  if not name then return false end
  local ok, device = pcall(function() return renoise.Midi.create_output_device(name) end)
  if not ok or not device then return false end
  local channel = up_midi.channel or 0
  local msb = math.floor(bank / 128) % 128
  local lsb = bank % 128
  local sent_msb = pcall(function() device:send({ 0xB0 + channel, 0, msb }) end)   -- Bank Select MSB
  local sent_lsb = pcall(function() device:send({ 0xB0 + channel, 32, lsb }) end)  -- Bank Select LSB
  pcall(function() device:close() end)
  return sent_msb and sent_lsb
end

-- Send Bank Select MSB/LSB then Program Change on the loopback port. Returns
-- true only when all three messages were actually sent.
function up_midi.select_program(bank, program)
  local name = up_midi.device()
  if not name then return false end
  local ok, device = pcall(function() return renoise.Midi.create_output_device(name) end)
  if not ok or not device then return false end
  local channel = up_midi.channel or 0
  -- Standard MIDI bank select: bank = MSB * 128 + LSB. Reaktor's snapshot banks
  -- are 0..15 and it reads the LSB, so send MSB 0 and the bank in the LSB.
  local msb = math.floor(bank / 128) % 128
  local lsb = bank % 128
  local sent_msb = pcall(function() device:send({ 0xB0 + channel, 0, msb }) end)   -- Bank Select MSB
  local sent_lsb = pcall(function() device:send({ 0xB0 + channel, 32, lsb }) end)  -- Bank Select LSB
  local sent_program = pcall(function() device:send({ 0xC0 + channel, program % 128 }) end) -- Program Change
  pcall(function() device:close() end)
  return sent_msb and sent_lsb and sent_program
end

return up_midi
