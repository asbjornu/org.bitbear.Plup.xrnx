local up_preset = {}

-- Pure-Lua base64 decoder (RFC 4648), used to read preset/ensemble names that
-- plugins embed inside their opaque state chunk (group 4 chars -> 3 bytes).
local _b64map = {}
do
  local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  for i = 1, #chars do _b64map[chars:sub(i, i)] = i - 1 end
end

local function _b64decode(encoded)
  encoded = encoded:gsub("[^A-Za-z0-9+/=]", "")
  local bytes = {}
  local i = 1
  while i <= #encoded do
    local a = _b64map[encoded:sub(i, i)] or 0; i = i + 1
    local b = _b64map[encoded:sub(i, i)] or 0; i = i + 1
    local c = encoded:sub(i, i); i = i + 1
    local d = encoded:sub(i, i); i = i + 1
    local has_third = (c ~= "" and c ~= "=") and _b64map[c] or nil
    local has_fourth = (d ~= "" and d ~= "=") and _b64map[d] or nil
    local n = a * 262144 + b * 4096 + (has_third or 0) * 64 + (has_fourth or 0)
    bytes[#bytes + 1] = string.char(math.floor(n / 65536) % 256)
    if has_third then bytes[#bytes + 1] = string.char(math.floor(n / 256) % 256) end
    if has_fourth then bytes[#bytes + 1] = string.char(n % 256) end
    if not has_third then break end
  end
  return table.concat(bytes)
end

-- Reaktor stores the loaded ensemble reference as UTF-16LE inside its state
-- chunk ("f\0i\0l\0e\0:\0/\0/\0Razor.rkplr"), so an ASCII `file://` pattern
-- never matches it. Find the UTF-16 marker and read the printable low byte of
-- each pair until the characters stop looking like a path, then return the URL
-- in plain ASCII form.
local function _utf16_file_url(blob)
  local marker = "f\0i\0l\0e\0:\0/\0/\0"
  local start = blob:find(marker, 1, true)
  if not start then return nil end
  local pos = start + #marker
  local out = {}
  while pos + 1 <= #blob do
    local lo, hi = blob:byte(pos), blob:byte(pos + 1)
    if hi ~= 0 or lo < 32 or lo > 126 then break end
    out[#out + 1] = string.char(lo)
    pos = pos + 2
  end
  if #out == 0 then return nil end
  return "file://" .. table.concat(out)
end

-- First ensemble/preset URL in a chunk, in plain ASCII or Reaktor's UTF-16LE.
local function _first_file_url(blob)
  local url = blob:match("file://[^%z%s\"'<>]+")
  if url then return url end
  return _utf16_file_url(blob)
end

-- Reaktor/Kontakt/etc. store the loaded ensemble as a "file://.../Name.ext"
-- string inside the preset blob; treat the last path component (minus the
-- extension) as the preset/ensemble name.
local function _scan_chunk_for_name(blob)
  local function base_of(url)
    -- The capture already stops before the final ".ext", so return it directly.
    -- A second strip would wrongly drop an interior dot (e.g. "My.Ensemble.rkplr"
    -- -> "My.Ensemble", not "My").
    local b = url:match("([^/\\]+)%.%w+$")
    if b and b ~= "" then return b end
    return nil
  end
  for url in blob:gmatch("file://[^%z%s\"'<>]+") do
    local n = base_of(url)
    if n and n ~= "" then return n end
  end
  local utf16 = _utf16_file_url(blob)
  if utf16 then
    local n = base_of(utf16)
    if n and n ~= "" then return n end
  end
  return nil
end

-- Recover a preset/ensemble name embedded in a plugin's opaque state chunk.
-- Renoise hands this back as the raw binary blob at runtime (so scan it
-- directly); some code paths pass the base64-encoded .xrns CDATA, so also try
-- after base64-decoding.
function up_preset._extract_chunk_name(data)
  if type(data) ~= "string" or data == "" then return nil end
  local n = _scan_chunk_for_name(data)
  if n then return n end
  -- Only attempt the (potentially expensive) full base64 decode when the data could
  -- actually be base64. Binary preset blobs contain NUL bytes and other non-base64
  -- characters and never carry a usable file:// URL, so skip the decode up front.
  if data:find("\0") or data:find("[^A-Za-z0-9+/=%s]") then
    return nil
  end
  local ok, dec = pcall(_b64decode, data)
  if ok and dec and dec ~= "" then
    n = _scan_chunk_for_name(dec)
    if n then return n end
  end
  return nil
end

-- Return the raw "file://.../Name.ext" ensemble/preset URL embedded in a plugin's
-- state chunk, if any (raw binary blob or base64-encoded .xrns CDATA). Its
-- presence identifies a *container* plugin (Reaktor/Kontakt) whose patch lives in
-- an external ensemble file, as opposed to a plugin with a flat factory bank.
function up_preset.find_ensemble_url(data)
  if type(data) ~= "string" or data == "" then return nil end
  local url = _first_file_url(data)
  if url then return url end
  if data:find("\0") or data:find("[^A-Za-z0-9+/=%s]") then return nil end
  local ok, dec = pcall(_b64decode, data)
  if ok and dec and dec ~= "" then
    return _first_file_url(dec)
  end
  return nil
end

-- The raw plugin binary bytes behind Renoise's `active_preset_data`. The value is
-- normally the <FilterDevicePreset> XML wrapper whose <ParameterChunk> CDATA is
-- the base64 of the binary, but the live API (and some callers) hand back the raw
-- chunk directly. Both are accepted, so callers can search the real state without
-- caring which form they hold.
function up_preset.chunk_bytes(data)
  if type(data) ~= "string" or data == "" then return "" end
  local cdata = data:match("<ParameterChunk[^>]*>%s*<!%[CDATA%[(.-)%]%]>")
  if cdata then
    local decoded = up_preset.decode_chunk(cdata)
    if decoded and decoded ~= "" then return decoded end
  end
  return data
end

-- Pure-Lua base64 encoder, used to put a recovered plugin binary back into the
-- <ParameterChunk><![CDATA[...]]></ParameterChunk> of Renoise's active_preset_data
-- XML wrapper.
local _b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function _b64encode(data)
  local out = {}
  for i = 1, #data, 3 do
    local a = data:byte(i)
    local b = data:byte(i + 1)
    local c = data:byte(i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    out[#out + 1] = _b64chars:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
    out[#out + 1] = _b64chars:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
    out[#out + 1] = b and _b64chars:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "="
    out[#out + 1] = c and _b64chars:sub(n % 64 + 1, n % 64 + 1) or "="
  end
  return table.concat(out)
end

-- Decode a plugin state chunk to the raw bytes Renoise assigns to
-- `active_preset_data`. Song.xml stores it base64-encoded in <ParameterChunk>
-- CDATA; the live API hands back the raw binary. Accepts either.
function up_preset.decode_chunk(data)
  if type(data) ~= "string" or data == "" then return nil end
  if data:find("\0") or data:find("[^A-Za-z0-9+/=%s]") then
    return data
  end
  local ok, dec = pcall(_b64decode, data)
  if ok and dec and dec ~= "" then return dec end
  return data
end

-- Base64-encode a raw plugin state chunk for injection into the
-- <ParameterChunk><![CDATA[...]]></ParameterChunk> of active_preset_data.
function up_preset.encode_chunk(data)
  if type(data) ~= "string" or data == "" then return nil end
  return _b64encode(data)
end

function up_preset.extract_name(device)
  if not device then
    return nil
  end
  local ok_ap, ap = pcall(function() return device.active_preset end)
  local ok_p, presets = pcall(function() return device.presets end)
  if ok_ap and ok_p and ap and ap > 0 and presets and presets[ap] then
    return presets[ap]
  end
  local ok_pd, pd = pcall(function() return device.active_preset_data end)
  if ok_pd and pd and pd ~= "" then
    local name = pd:match("<PresetName>([^<]*)</PresetName>")
    if name and name ~= "" then
      return name
    end
    name = pd:match("<Name>([^<]*)</Name>")
    if name and name ~= "" then
      return name
    end
    -- Only a *bare* `name` attribute (preceded by a non-word, non-underscore
    -- character, i.e. a real attribute boundary) is a candidate. Without this
    -- guard the pattern matched the `name="..."` tail of a `*name="..."`
    -- attribute such as `plugin_name="Serum"`, which would wrongly return the
    -- plugin's name as the preset name and shadow the real preset.
    name = pd:match('[^%w_]name="([^"]*)"')
    if name and name ~= "" then
      return name
    end
    -- Fallback: many plugin formats embed the loaded ensemble/preset as a
    -- "file://.../Name.ext" string in the opaque chunk (e.g. Reaktor's loaded
    -- ensemble), which Renoise exposes only inside active_preset_data.
    name = up_preset._extract_chunk_name(pd)
    if name and name ~= "" then
      return name
    end
  end
  return nil
end

-- Preset names that denote a plugin's factory-initial / default state rather
-- than a real user patch. Vendors label this inconsistently ("Init", "Default",
-- "Def It Setting", "Factory", ...) so the UI normalises them to a single
-- display token "init". This is display-only: extract_name keeps returning the
-- real name so preset transfer can still match it in the replacement plugin.
local _INIT_PATTERNS = {
  "%f[%w]def",
  "%f[%w]init",
  "%f[%w]factory",
}

function up_preset.is_init_preset(name)
  if type(name) ~= "string" or name == "" then
    return false
  end
  local low = name:lower()
  for _, p in ipairs(_INIT_PATTERNS) do
    if low:match(p) then
      return true
    end
  end
  return false
end

return up_preset
