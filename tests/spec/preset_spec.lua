-- Tests for up_preset: preset/ensemble name extraction from the plugin's opaque
-- state chunk (base64 + raw blob + XML tags), init-preset normalisation, and the
-- binary-blob guard before base64 decoding.

-- 3. up_preset ----------------------------------------------------------------
section("up_preset.extract_name")
do
  local dev = { active_preset = 3, presets = { "A", "B", "C" },
    active_preset_data = "<PresetName>IgnoreMe</PresetName>" }
  check(up_preset.extract_name(dev) == "C", "returns presets[index] when active_preset set")

  local dev2 = { active_preset_data = "<PresetName>MyPatch</PresetName>" }
  check(up_preset.extract_name(dev2) == "MyPatch", "falls back to <PresetName> in chunk")

  check(up_preset.extract_name(nil) == nil, "nil device -> nil")

  -- Reaktor/Kontakt embed the loaded ensemble as a "file://.../Name.ext" string
  -- inside the opaque preset blob. Renoise returns it as the raw binary at
  -- runtime, and as base64-encoded CDATA in some code paths. The last path
  -- component minus its extension is the preset/ensemble name.
  local raw = "\000\000file://localhost/Users/Shared/Razor/Razor.rkplr\000\000"
  check(up_preset.extract_name({ active_preset_data = raw }) == "Razor",
    "extracts ensemble name from raw blob (file:// URL)")
  local razor_b64 = "AABmaWxlOi8vbG9jYWxob3N0L1VzZXJzL1NoYXJlZC9SYXpvci9SYXpvci5ya3Bscg" ..
    "AA"
  check(up_preset.extract_name({ active_preset_data = razor_b64 }) == "Razor",
    "extracts ensemble name from base64 chunk (file:// URL)")
  local legato_b64 = "AUtvbnRha3QAZmlsZTovLy9TYW1wbGVzL09yY2hlc3RyYS9MZWdhdG8ubmtp" ..
    "AA=="
  check(up_preset.extract_name({ active_preset_data = legato_b64 }) == "Legato",
    "extracts ensemble name from Kontakt-style base64 chunk")

  -- Secondary fallback branches inside active_preset_data.
  check(up_preset.extract_name({ active_preset_data = "<Name>EmbeddedPatch</Name>" }) == "EmbeddedPatch",
    "falls back to <Name> in chunk")
  check(up_preset.extract_name({ active_preset_data = '<device name="InlineName"></device>' }) == "InlineName",
    "falls back to name=\"...\" attribute in chunk")

  -- A `name=\"...\"` attribute must only match a real `name` attribute, not the
  -- tail of e.g. `plugin_name=\"...\"`: otherwise the plugin name would shadow the
  -- actual preset name.
   check(up_preset.extract_name({ active_preset_data = '<device plugin_name="Serum" name="Init"></device>' }) == "Init",
     "name=\"...\" attribute is not confused with plugin_name")
end

section("up_preset.is_init_preset")
check(up_preset.is_init_preset("Def It Setting") == true, "FabFilter default -> init")
check(up_preset.is_init_preset("Init") == true, "Serum Init -> init")
check(up_preset.is_init_preset("Default") == true, "Default -> init")
check(up_preset.is_init_preset("Factory") == true, "Factory -> init")
check(up_preset.is_init_preset("My Patch") == false, "real patch is not init")
check(up_preset.is_init_preset("Divination") == false, "init-substring word is not init")
check(up_preset.is_init_preset(nil) == false, "nil -> false")
check(up_preset.is_init_preset("") == false, "empty -> false")

section("up_preset._extract_chunk_name skips binary blobs before decoding")
do
  -- A binary active_preset_data blob (NUL bytes / non-base64 chars) can never carry a
  -- usable file:// URL, so the cheap heuristic must reject it without the expensive
  -- full base64 decode.
  check(up_preset._extract_chunk_name("\000\000\001\002binaryblob\255") == nil,
    "binary blob with NUL bytes is rejected before decoding")
  -- Valid base64 still decodes and yields the embedded ensemble name.
  local razor_b64 = "AABmaWxlOi8vbG9jYWxob3N0L1VzZXJzL1NoYXJlZC9SYXpvci9SYXpvci5ya3Bscg" .. "AA"
  check(up_preset._extract_chunk_name(razor_b64) == "Razor",
    "valid base64 chunk still yields the ensemble name")
  -- A filename with interior dots must keep every dot but the final extension.
  check(up_preset._extract_chunk_name("file:///Shared/My.Ensemble.rkplr") == "My.Ensemble",
    "interior dots are preserved (only the last extension is stripped)")
  check(up_preset._extract_chunk_name("file:///Shared/NoExtension") == nil,
    "a file:// URL without an extension yields no name")
end

section("up_preset reads Reaktor's UTF-16LE ensemble reference")
do
  -- A real Reaktor state chunk stores the ensemble path UTF-16LE, so the ASCII
  -- "file://" pattern never matches it. The chunk below is a small stand-in for
  -- the bundled donor's head.
  local function utf16(s)
    local out = {}
    for i = 1, #s do out[#out + 1] = s:sub(i, i) .. "\0" end
    return table.concat(out)
  end
  local blob = "\1\2\3\4" .. utf16("file://Razor.rkplr") .. "\0\0\5\6"
  check(up_preset.find_ensemble_url(blob) == "file://Razor.rkplr",
    "find_ensemble_url decodes the UTF-16LE file:// URL")
  check(up_preset._extract_chunk_name(blob) == "Razor",
    "_extract_chunk_name returns the UTF-16LE ensemble name")
  -- A UTF-16 URL without an extension yields no name.
  local no_ext = "\1" .. utf16("file://NoExtension") .. "\0\0"
  check(up_preset._extract_chunk_name(no_ext) == nil,
    "UTF-16 file:// URL without an extension yields no name")
end

section("coverage: up_preset.extract_name edge cases")
do
  -- active_preset index out of range yields no active_preset_name.
  check(up_preset.extract_name({ active_preset = 99, presets = { "Only" } }) == nil,
    "out-of-range active_preset -> nil")
  -- A chunk with only a plugin_name (no name) attribute yields no preset.
  check(up_preset.extract_name({ active_preset_data = '<device plugin_name="Serum"></device>' }) == nil,
    "chunk with plugin_name only -> nil")
  -- An empty chunk yields nil.
  check(up_preset.extract_name({ active_preset_data = "" }) == nil, "empty chunk -> nil")
  -- A raw binary blob with no file:// URL is rejected before decoding.
  check(up_preset.extract_name({ active_preset_data = "\000\000\001\002blob\255" }) == nil,
    "binary blob without file:// URL -> nil")
end

section("up_preset.chunk_bytes unwraps the XML wrapper")
do
  local raw = "\0\1\2\3file-state"
  local wrapper = '<?xml version="1.0"?><FilterDevicePreset><DeviceSlot><ParameterChunk><![CDATA['
    .. up_preset.encode_chunk(raw) .. ']]></ParameterChunk></DeviceSlot></FilterDevicePreset>'
  check(up_preset.chunk_bytes(wrapper) == raw,
    "the base64 <ParameterChunk> CDATA is decoded to the raw bytes")
  check(up_preset.chunk_bytes(raw) == raw,
    "a raw chunk (no wrapper) is returned unchanged")
  check(up_preset.chunk_bytes("") == "", "an empty value yields empty bytes")
end
