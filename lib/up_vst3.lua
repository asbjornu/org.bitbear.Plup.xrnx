-- Pure-Lua reader/writer for the VST3 preset container (".vstpreset").
--
-- Renoise stores a VST3 plugin's active preset as this container inside the
-- <ParameterChunk> of active_preset_data, while VST2 stores the plugin's raw
-- chunk instead. Being able to swap the component ("Comp") state lets a
-- same-product, same-version upgrade move state between the VST2 and VST3
-- builds of a plugin whose serialized state is the same.
--
-- File layout (little-endian):
--   0  "VST3"
--   4  version (int32)
--   8  ASCII class id (32 bytes)
--   40 offset to the chunk list (int64)
--   .. data area (the chunks)
--   .. "List", entry count (int32), then per chunk:
--        id (4 bytes), offset (int64), size (int64)
local up_vst3 = {}

local function read_u32(data, position)
  local a, b, c, d = data:byte(position, position + 3)
  if not d then return nil end
  return a + b * 256 + c * 65536 + d * 16777216
end

local function read_i64(data, position)
  local low = read_u32(data, position)
  local high = read_u32(data, position + 4)
  if not low or not high then return nil end
  return high * 4294967296 + low
end

local function write_u32(value)
  local low = value % 4294967296
  return string.char(
    low % 256,
    math.floor(low / 256) % 256,
    math.floor(low / 65536) % 256,
    math.floor(low / 16777216) % 256)
end

local function write_i64(value)
  local low = value % 4294967296
  local high = math.floor(value / 4294967296)
  return write_u32(low) .. write_u32(high)
end

-- Parse a .vstpreset into its header fields and chunks. Returns nil when the
-- data is not a valid container, so callers can fall back safely.
function up_vst3.parse(data)
  if type(data) ~= "string" or #data < 48 or data:sub(1, 4) ~= "VST3" then
    return nil
  end
  local version = read_u32(data, 5)
  local list_offset = read_i64(data, 41)
  if not version or not list_offset then return nil end
  if list_offset < 48 or list_offset + 8 > #data then return nil end
  local list_position = list_offset + 1
  if data:sub(list_position, list_position + 3) ~= "List" then return nil end
  local count = read_u32(data, list_position + 4)
  if not count then return nil end
  local chunks = {}
  local cursor = list_position + 8
  for index = 1, count do
    if cursor + 19 > #data then return nil end
    local id = data:sub(cursor, cursor + 3)
    local offset = read_i64(data, cursor + 4)
    local size = read_i64(data, cursor + 12)
    if not offset or not size then return nil end
    if offset < 48 or offset + size > #data then return nil end
    chunks[index] = {
      id = id,
      offset = offset,
      size = size,
      data = data:sub(offset + 1, offset + size),
    }
    cursor = cursor + 20
  end
  return {
    version = version,
    class_id = data:sub(9, 40),
    chunks = chunks,
  }
end

-- Build a .vstpreset from a version, a 32-byte ASCII class id and chunk
-- descriptors ({ id, data }). Returns nil for an invalid class id or chunk id.
function up_vst3.build(version, class_id, chunks)
  class_id = class_id or ""
  if #class_id ~= 32 then return nil end
  local data_parts = {}
  local entries = {}
  local offset = 48
  for _, chunk in ipairs(chunks or {}) do
    local id = tostring(chunk.id or "")
    if #id ~= 4 then return nil end
    local body = chunk.data or ""
    entries[#entries + 1] = { id = id, offset = offset, size = #body }
    data_parts[#data_parts + 1] = body
    offset = offset + #body
  end
  local list = { "List", write_u32(#entries) }
  for _, entry in ipairs(entries) do
    list[#list + 1] = entry.id .. write_i64(entry.offset) .. write_i64(entry.size)
  end
  return "VST3" .. write_u32(version or 1) .. class_id .. write_i64(offset)
    .. table.concat(data_parts) .. table.concat(list)
end

-- Return the plugin's component state ("Comp" chunk) from a .vstpreset.
function up_vst3.component(data)
  local parsed = up_vst3.parse(data)
  if not parsed then return nil end
  for _, chunk in ipairs(parsed.chunks) do
    if chunk.id == "Comp" then return chunk.data end
  end
  return nil
end

-- Replace the plugin's component state in a .vstpreset, preserving the class
-- id and every other chunk (Controller, Info, ...). Adds a Comp chunk when the
-- container has none yet.
function up_vst3.replace_component(data, component)
  if type(component) ~= "string" then return nil end
  local parsed = up_vst3.parse(data)
  if not parsed then return nil end
  local chunks = {}
  local found = false
  for _, chunk in ipairs(parsed.chunks) do
    local body = chunk.data
    if chunk.id == "Comp" then
      body = component
      found = true
    end
    chunks[#chunks + 1] = { id = chunk.id, data = body }
  end
  if not found then
    table.insert(chunks, 1, { id = "Comp", data = component })
  end
  return up_vst3.build(parsed.version, parsed.class_id, chunks)
end

return up_vst3
