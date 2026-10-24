local up_preset = require("up_preset")
local up_plugin_analysis = require("up_plugin_analysis")
local up_donor = require("up_donor")
local up_midi = require("up_midi")
local up_vst3 = require("up_vst3")

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

local function is_vst2(protocol)
  return protocol == "VST" or protocol == "VST2"
end

-- Token sets are compatible when one contains the other and the extra tokens
-- are only manufacturer/vendor words. is_manufacturer_token() deliberately
-- retains product qualifiers such as "one", "ace", "sampler" and "knifonium"
-- (unlike the loose matcher's is_product_token()), so distinct products like
-- "SynthMaster" vs "SynthMaster One" cannot collapse to the same identity. A
-- genuine vendor prefix on one side ("u-he ACE" vs "ACE") is still tolerated.
local function tokens_compatible(a, b)
  local shorter, longer = a, b
  if not up_plugin_analysis.token_subset(a, b) then
    shorter, longer = b, a
    if not up_plugin_analysis.token_subset(b, a) then return false end
  end
  for token in pairs(longer) do
    if not shorter[token] and not up_plugin_analysis.is_manufacturer_token(token) then
      return false
    end
  end
  return true
end

local function normalized_identity(analysis)
  local text = analysis and (analysis.base or analysis.product) or ""
  text = tostring(text):lower():gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
  return text
end

-- Strict same-product check used for chunk compatibility. Candidate discovery
-- and donor matching stay on the looser same_family()/token subset, but chunk
-- state cannot be assumed compatible between related products ("Massive" vs
-- "Massive X"), even though the matcher may offer the pair.
local function same_product(old_analysis, new_analysis)
  local old_text = old_analysis and (old_analysis.base or old_analysis.product) or ""
  local new_text = new_analysis and (new_analysis.base or new_analysis.product) or ""
  local old_tokens = up_plugin_analysis.token_set(old_text)
  local new_tokens = up_plugin_analysis.token_set(new_text)
  if next(old_tokens) and next(new_tokens) then
    return tokens_compatible(old_tokens, new_tokens)
  end
  local old_identity = normalized_identity(old_analysis)
  local new_identity = normalized_identity(new_analysis)
  return old_identity ~= "" and old_identity == new_identity
end

-- Every numeric component of an identity, in order. clean_display_name()
-- normalizes dots to spaces ("Pro-Q 2.0" -> "pro q 2 0"), and a version can be
-- attached to the product word or followed by a suffix ("Kontakt6 FX"), so
-- compare all the numbers rather than a single trailing one.
local function numeric_identity(analysis)
  local text = analysis and (analysis.base or analysis.product) or ""
  if type(text) ~= "string" then return "" end
  local parts = {}
  for number in text:gmatch("%d+") do
    parts[#parts + 1] = number
  end
  return table.concat(parts, ".")
end

-- Decide how the old state chunk can be written to the replacement. A matching
-- protocol is NOT sufficient: "Kick" and "Kick 2" are both VST but are distinct
-- products, and a version bump (e.g. Pro-Q 2 -> Pro-Q 3) changes the chunk
-- layout too. Writing an incompatible blob is accepted by the API and reads
-- back non-empty, so it would look like a successful transfer while silently
-- dropping the patch. Require the same product at the same version.
--
-- "direct" means the two plugins use the same protocol, so the chunk can be
-- injected as before. "vst3" / "vst2" are same-product upgrades across the
-- VST2 <-> VST3 boundary (e.g. Massive or Reaktor): the plugin state is the
-- engine's own serialized data, while VST3 additionally wraps it in a
-- .vstpreset container (see up_vst3). Those are converted rather than written
-- directly. Everything else falls through to the preset + name-matched
-- parameter overlay. (Container plugins keep their donor/MIDI path.)
local function chunk_transfer_mode(old_analysis, new_analysis, same_format)
  if not same_product(old_analysis, new_analysis) then return nil end
  if numeric_identity(old_analysis) ~= numeric_identity(new_analysis) then return nil end
  if same_format then return "direct" end
  local old_protocol = old_analysis and old_analysis.protocol
  local new_protocol = new_analysis and new_analysis.protocol
  if is_vst2(old_protocol) and new_protocol == "VST3" then return "vst3" end
  if old_protocol == "VST3" and is_vst2(new_protocol) then return "vst2" end
  return nil
end

-- A donor may already be stored in the replacement's format (the bundled
-- Reaktor donor is a complete .vstpreset). In that case inject it directly
-- instead of nesting the whole container inside the new plugin's Comp chunk.
local function adjust_chunk_mode(mode, data, target_protocol)
  if type(data) == "string" and up_vst3.parse(data) then
    if target_protocol == "VST3" then return "direct" end
    if is_vst2(target_protocol) then return "vst2" end
  end
  return mode
end

-- For a same-family container upgrade the old chunk is a different plugin format
-- and gets rejected, so substitute a known-good chunk from the configured donor
-- song (which already has the ensemble loaded in the replacement version). The
-- donor must be for the same ensemble, otherwise injecting it would replace the
-- instance's patch, so `ensemble` is required to match.
local function use_donor_chunk(old_data, family_match, reaktor, candidate, ensemble)
  if not (family_match and reaktor) then return old_data, false end
  local family = up_plugin_analysis.family_base(candidate.base or candidate.product or "")
  local donor = up_donor.chunk_for(family, ensemble)
  if donor then
    return donor, true
  end
  return old_data, false
end

-- True when the plugin is Native Instruments Reaktor. Only Reaktor needs the
-- donor/MIDI-bank machinery: it is the plugin whose whole patch (ensemble +
-- snapshot) lives in the opaque chunk and whose snapshot banks the API cannot
-- address. Other containers (e.g. Kontakt) are file-backed too, so they still get
-- the chunk transplant, but must not be pushed through the Reaktor-only path.
local function is_reaktor(analysis)
  if not analysis then return false end
  local family = up_plugin_analysis.family_base(analysis.base or analysis.product or "")
  return family:find("reaktor", 1, true) ~= nil
end

-- Capture the old plugin's exposed parameter values so we can re-apply them to
-- the replacement plugin as a best-effort "synthesized" preset when the native
-- preset chunk can't be transferred (e.g. across plugin formats). Only
-- automatable parameters are captured for track effects; instrument plugins
-- expose no meaningful `is_automatable` flag (Renoise documents it as invalid
-- for instrument devices), so all named instrument parameters are captured.
-- The quantum and display string are captured too: enumerated parameters (e.g.
-- Saturn's per-band distortion style) can change their option count between
-- major versions, and replaying the old normalized value would select a
-- different option.
local function snapshot_parameters(device, is_instrument)
  local captured = {}
  if not device then return captured, true end
  local ok, parameters = pcall(function() return device.parameters end)
  if not ok or not parameters then return captured, false end
  local total = 0
  local seen = {}
  local unique = true
  for _, parameter in ipairs(parameters) do
    total = total + 1
    local usable = true
    if not is_instrument then
      local ok_auto, is_automatable = pcall(function() return parameter.is_automatable end)
      usable = ok_auto and is_automatable
    end
    if usable then
      local ok_value, value = pcall(function() return parameter.value end)
      local ok_name, name = pcall(function() return parameter.name end)
      -- Skip parameters whose name can't be read: apply_parameter_values
      -- matches strictly by (non-empty) name, so nameless entries can never be
      -- re-applied and would only add noise/work.
      if ok_value and ok_name and type(name) == "string" and name ~= "" then
        if seen[name] then unique = false end
        seen[name] = true
        local ok_quantum, quantum = pcall(function() return parameter.value_quantum end)
        local ok_string, value_string = pcall(function() return parameter.value_string end)
        captured[#captured + 1] = {
          name = name,
          value = value,
          value_quantum = (ok_quantum and type(quantum) == "number") and quantum or nil,
          value_string = (ok_string and type(value_string) == "string") and value_string or nil,
        }
      end
    end
  end
  -- A bag transplant preserves parameters the name-based overlay cannot
  -- capture (non-automatable or nameless controls), so callers need to know
  -- whether the snapshot is complete. Duplicate names are treated as
  -- incomplete: the name-keyed mapping restores only the first of them, so a
  -- "complete" snapshot could otherwise silently drop the rest.
  return captured, total == #captured and unique
end

-- Parameter names are not guaranteed to survive a VST2 -> VST3 port verbatim:
-- vendors often change case, spacing or punctuation ("OSC1 Wt-position" ->
-- "OSC 1 WT Position"). Compare the exact name first, then a case-folded,
-- punctuation- and whitespace-free form. Ambiguous normalized matches are
-- ignored so two distinct controls can never be cross-wired.
local function normalize_parameter_name(name)
  local text = tostring(name or ""):lower()
  return (text:gsub("[^%w]", ""))
end

local function read_parameter_name(parameter)
  local ok_name, name = pcall(function() return parameter.name end)
  if ok_name and type(name) == "string" and name ~= "" then return name end
  return nil
end

local function parameter_writable(parameter, is_instrument)
  if is_instrument then return true end
  local ok_auto, is_automatable = pcall(function() return parameter.is_automatable end)
  return ok_auto and is_automatable
end

-- Build a one-to-one mapping from the old parameters to replacement parameters.
-- Exact names are reserved first and a target is never used twice. Normalized
-- matching is only a fallback: it is skipped when several source names collapse
-- to the same key or when several targets share it, so "Cutoff" and "Cut-off"
-- can never overwrite each other.
local function build_parameter_mapping(parameters, old_parameters, is_instrument)
  local exact = {}
  local normalized = {}
  for _, parameter in ipairs(parameters or {}) do
    local name = read_parameter_name(parameter)
    if name then
      if not exact[name] then exact[name] = parameter end
      local key = normalize_parameter_name(name)
      if key ~= "" then
        local bucket = normalized[key]
        if not bucket then
          bucket = {}
          normalized[key] = bucket
        end
        bucket[#bucket + 1] = parameter
      end
    end
  end

  local mapping = {}
  local used = {}
  for index, old_parameter in ipairs(old_parameters) do
    local target = exact[old_parameter.name]
    if target and not used[target] and parameter_writable(target, is_instrument) then
      mapping[index] = target
      used[target] = true
    end
  end

  local source_counts = {}
  local pending = {}
  for index, old_parameter in ipairs(old_parameters) do
    if not mapping[index] then
      local key = normalize_parameter_name(old_parameter.name)
      if key ~= "" then
        source_counts[key] = (source_counts[key] or 0) + 1
        pending[#pending + 1] = { index = index, key = key }
      end
    end
  end
  for _, entry in ipairs(pending) do
    if source_counts[entry.key] == 1 then
      local bucket = normalized[entry.key]
      if bucket and #bucket == 1 then
        local target = bucket[1]
        if not used[target] and parameter_writable(target, is_instrument) then
          mapping[entry.index] = target
          used[target] = true
        end
      end
    end
  end
  return mapping
end

-- True when every captured source parameter has a writable one-to-one target on
-- the replacement. A complete source snapshot can still omit replacement
-- controls (a renamed or non-automatable target), in which case the name-based
-- overlay would report success while dropping the unmatched saved values; the
-- compatible ParameterBag transplant preserves them instead.
local function replacement_mapping_complete(new_device, old_parameters, is_instrument)
  if not old_parameters or #old_parameters == 0 then return false end
  local ok_parameters, parameters = pcall(function() return new_device.parameters end)
  if not ok_parameters or not parameters then return false end
  local mapping = build_parameter_mapping(parameters, old_parameters, is_instrument)
  local mapped = 0
  for index = 1, #old_parameters do
    if mapping[index] then mapped = mapped + 1 end
  end
  return mapped == #old_parameters
end

-- Compare parameter values with a tolerance derived from the parameter's own
-- range/quantum. VST2 and VST3 builds can expose the same setting with slightly
-- different float precision (0.30000001192092896 vs 0.3), which must count as
-- equal for both baseline and restoration checks.
local function parameter_values_equal(left, right, parameter)
  if left == right then return true end
  if type(left) ~= "number" or type(right) ~= "number" then return false end
  local tolerance = 1e-6
  local ok_quantum, quantum = pcall(function() return parameter.value_quantum end)
  if ok_quantum and type(quantum) == "number" and quantum > 0 then
    tolerance = math.max(tolerance, quantum * 0.5)
  else
    local ok_min, minimum = pcall(function() return parameter.value_min end)
    local ok_max, maximum = pcall(function() return parameter.value_max end)
    if ok_min and ok_max and type(minimum) == "number" and type(maximum) == "number"
      and maximum > minimum then
      tolerance = math.max(tolerance, (maximum - minimum) * 1e-6)
    end
  end
  return math.abs(left - right) <= tolerance
end

local function trimmed_label(value)
  if type(value) ~= "string" then return nil end
  local label = value:match("^%s*(.-)%s*$")
  if label == "" then return nil end
  return label
end

local function labels_equal(left, right)
  local first = trimmed_label(left)
  local second = trimmed_label(right)
  return first ~= nil and second ~= nil and first:lower() == second:lower()
end

-- Heuristic for a textual enum/mode label such as "Warm Tape", "Off" or "2x".
-- A continuous parameter formats its value as a number followed by an attached
-- or whitespace-separated unit ("0.50", "-3.0dB", "0.413ms", "440 Hz",
-- "100.0%"); those keep their numeric transfer. A digit-bearing option label
-- ("2x", "16x", "Band 2") has no measurement unit, so it must trigger the label
-- lookup even when value_quantum is 0 (as some plugin bindings report for
-- enums). "x" is deliberately treated as an option multiplier, not a unit.
local function looks_like_enum_label(value)
  local label = trimmed_label(value)
  if not label or not label:find("%a") then return false end
  local unit = label:match("^[%-%+]?%d+%.?%d*%s*([%a%%]+)")
  if not unit then return true end
  return unit:lower() == "x"
end

-- At most 256 plugin reads/writes are performed while looking for a label.
-- Exhaustive step searches (a tiny reported quantum) and the no-quantum
-- sampling fallback both stay within this budget so one swap cannot stall
-- Renoise's script thread.
local MAX_LABEL_PROBES = 256

-- Decide whether an old parameter is an enumerated option that must be remapped
-- by display label. The textual heuristic above handles mode names ("Warm Tape")
-- and digit-bearing options ("2x", "Band 2"). Some option banks label choices
-- with bare integers ("1", "2", "4"), integer values with a unit ("24 dB/oct")
-- or musical-time fractions ("1/4", "1/8") that carry no textual mode name; the
-- captured quantum reveals them: a quantum that divides the normalized range
-- into a small, bounded number of steps is a discrete option bank, whereas a
-- continuous control's tiny quantum (thousands of steps) or a decimal-formatted
-- numeric label ("0.40", "0.413ms") is excluded.
local function is_enum_parameter(parameter)
  local label = trimmed_label(parameter.value_string)
  if not label then return false end
  if looks_like_enum_label(label) then return true end
  local quantum = parameter.value_quantum
  if type(quantum) ~= "number" or quantum <= 0 then return false end
  if (1 / quantum) + 1 > MAX_LABEL_PROBES then return false end
  -- Accept bare integers, integer-formatted unit labels and musical-time
  -- fractions, but not decimal values ("0.40", "0.413ms"), which are continuous
  -- controls.
  return label:match("^[%-%+]?%d+$") ~= nil
    or label:match("^[%-%+]?%d+%s*[%a]") ~= nil
    or label:match("^%d+/%d+$") ~= nil
end

-- True when a parameter's own quantum reveals a fine-grained continuous control
-- (more steps than the label-probe budget, e.g. quantum 1e-6). Used to decide
-- whether a numeric-only label ("40") can be trusted for display equality: a
-- fine-grained replacement makes the display match coincidental, so the saved
-- numeric value must be written. A zero/unknown quantum is not fine-grained:
-- `value_for_label`'s sampling fallback can still locate the option, so a
-- numeric-only enum label keeps using the label lookup.
local function parameter_is_fine_grained(parameter)
  local ok_quantum, quantum = pcall(function() return parameter.value_quantum end)
  return ok_quantum and type(quantum) == "number" and quantum > 0
    and (1 / quantum) + 1 > MAX_LABEL_PROBES
end

-- The replacement value whose display label matches `wanted`. Enumerated
-- plugin parameters expose their option name through value_string. Assigning
-- value_string is not supported by every host binding, so fall back to walking
-- the parameter's quantized steps and comparing the label at each one.
local function value_for_label(parameter, wanted)
  local ok_current, current = pcall(function() return parameter.value end)
  if not ok_current then return nil end
  local ok_direct = pcall(function() parameter.value_string = wanted end)
  if ok_direct then
    local ok_read, actual = pcall(function() return parameter.value_string end)
    if ok_read and labels_equal(actual, wanted) then
      local ok_value, value = pcall(function() return parameter.value end)
      if ok_value then return value end
    end
  end
  pcall(function() parameter.value = current end)
  local ok_min, minimum = pcall(function() return parameter.value_min end)
  local ok_max, maximum = pcall(function() return parameter.value_max end)
  local ok_quantum, quantum = pcall(function() return parameter.value_quantum end)
  if not (ok_min and ok_max) then return nil end
  if type(minimum) ~= "number" or type(maximum) ~= "number" then return nil end
  if not ok_quantum then quantum = nil end
  if type(quantum) == "number" and quantum > 0 then
    local steps = math.floor((maximum - minimum) / quantum + 0.5)
    if steps + 1 > MAX_LABEL_PROBES then return nil end
    for step = 0, steps do
      local value = minimum + step * quantum
      local ok_set = pcall(function() parameter.value = value end)
      if ok_set then
        local ok_read, actual = pcall(function() return parameter.value_string end)
        if ok_read and labels_equal(actual, wanted) then return value end
      end
    end
  else
    -- Some bindings report no quantum for an enumerated parameter. Sampling the
    -- range still finds the option because assigning a value snaps to the
    -- nearest one. Use the middle of the matching range so the saved value is
    -- not sitting on an option boundary.
    local samples = MAX_LABEL_PROBES - 1
    local first_match, last_match
    for step = 0, samples do
      local value = minimum + (maximum - minimum) * step / samples
      local ok_set = pcall(function() parameter.value = value end)
      if ok_set then
        local ok_read, actual = pcall(function() return parameter.value_string end)
        if ok_read and labels_equal(actual, wanted) then
          if not first_match then first_match = value end
          last_match = value
        elseif first_match then
          break
        end
      end
    end
    if first_match then
      return (first_match + last_match) / 2
    end
  end
  pcall(function() parameter.value = current end)
  return nil
end

-- Re-apply captured parameter values onto the new device, matched by name (with
-- a one-to-one normalized fallback). Only automatable parameters are written for
-- track effects; instrument parameters are written directly because Renoise's
-- `is_automatable` is not valid for instrument devices. Enumerated parameters
-- whose option set changed are remapped by their display label instead of by
-- the old normalized value. Returns the number of parameters that were
-- transferred.
local function apply_parameter_values(new_device, old_parameters, is_instrument)
  local ok_parameters, parameters = pcall(function() return new_device.parameters end)
  -- Return all three results even on failure: the caller treats a nil `mapped`
  -- as "some parameters mapped", which would suppress the raw bag fallback even
  -- though nothing could be read.
  if not ok_parameters or not parameters then return 0, false, 0 end
  local mapping = build_parameter_mapping(parameters, old_parameters, is_instrument)
  local applied = 0
  local mapped = 0
  local rejected = false
  for index, old_parameter in ipairs(old_parameters) do
    local target = mapping[index]
    if target then
      mapped = mapped + 1
      local label = trimmed_label(old_parameter.value_string)
      -- Only genuine option labels use display matching. Continuous controls
      -- can round to the same string ("0.41") while holding different values
      -- (0.413 vs 0.410), so they must go through the numeric path below.
      local try_label = is_enum_parameter(old_parameter)
      -- A numeric-only label ("40") may belong to a continuous control merely
      -- formatted as an integer. Only trust the enum classification when the
      -- replacement is not fine-grained: a finer-grained replacement makes the
      -- display match coincidental, so the saved numeric value must be written.
      -- A zero/unknown replacement quantum keeps the label lookup, because the
      -- sampling fallback can still find the option.
      if try_label and not looks_like_enum_label(label)
          and parameter_is_fine_grained(target) then
        try_label = false
      end
      local handled = false
      if try_label then
        local ok_new_string, new_value_string = pcall(function() return target.value_string end)
        if ok_new_string and labels_equal(label, new_value_string) then
          -- The replacement is already on the same option (the matched preset
          -- may have set it), so leave it alone.
          applied = applied + 1
          handled = true
        else
          local value = value_for_label(target, label)
          if value ~= nil then
            local ok_set = pcall(function() target.value = value end)
            if ok_set then applied = applied + 1 end
            handled = true
          else
            -- An enum option with no matching option must keep the base
            -- preset's option: writing the old normalized value would land on
            -- an unrelated entry. This includes numeric-only option banks,
            -- whose unmapped index must not be replayed.
            handled = true
            rejected = true
          end
        end
      end
      if not handled then
        local ok_value, current = pcall(function() return target.value end)
        if ok_value and parameter_values_equal(current, old_parameter.value, target) then
          -- Already in the desired state (common after a chunk transplant or a
          -- matching factory preset): no API call needed, but it counts.
          applied = applied + 1
        else
          local ok_set = pcall(function() target.value = old_parameter.value end)
          if ok_set then applied = applied + 1 end
        end
      end
    end
  end
  return applied, rejected, mapped
end

-- Snapshot the replacement's values before a converted chunk is written, keyed
-- by the same one-to-one old-parameter mapping. Comparing against this baseline
-- stops an already-equal default (e.g. Bypass = 0) from masquerading as proof
-- that the chunk was restored.
local function capture_parameter_baseline(new_device, old_parameters, is_instrument)
  local baseline = {}
  local ok_parameters, parameters = pcall(function() return new_device.parameters end)
  if not ok_parameters or not parameters then return baseline end
  local mapping = build_parameter_mapping(parameters, old_parameters, is_instrument)
  for index = 1, #old_parameters do
    local target = mapping[index]
    if target then
      local ok_value, value = pcall(function() return target.value end)
      if ok_value then baseline[index] = value end
    end
  end
  return baseline
end

-- Check whether a converted chunk actually restored the settings that were
-- different before it was written. Only parameters whose pre-transfer value
-- differed from the old value count, so unchanged defaults are not evidence;
-- when none of those changed settings survived, the conversion failed.
local function parameter_restoration(new_device, old_parameters, baseline, is_instrument)
  local ok_parameters, parameters = pcall(function() return new_device.parameters end)
  if not ok_parameters or not parameters then return 0, 0 end
  local mapping = build_parameter_mapping(parameters, old_parameters, is_instrument)
  local comparable, restored = 0, 0
  for index, old_parameter in ipairs(old_parameters) do
    local target = mapping[index]
    local before = baseline[index]
    if target and before ~= nil
      and not parameter_values_equal(before, old_parameter.value, target) then
      comparable = comparable + 1
      local ok_value, value = pcall(function() return target.value end)
      if ok_value and parameter_values_equal(value, old_parameter.value, target) then
        restored = restored + 1
      end
    end
  end
  return comparable, restored
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
-- or a numeric snapshot index (e.g. Razor's "038 Sad Star"), while the recovered
-- name is the bare base ("Razor" / "Sad Star"), so exact equality misses. Compare
-- exact first, then on the trimmed, index- and extension-stripped, case-folded
-- base name. Also ignore a trailing numeric suffix, because Renoise instrument
-- names carry one ("Dark Dreams 1") while the Reaktor snapshot does not.
local function preset_name_matches(wanted, candidate)
  if type(wanted) ~= "string" or type(candidate) ~= "string" then return false end
  if wanted == candidate then return true end
  local function base(name)
    local trimmed = name:match("^%s*(.-)%s*$")
    if trimmed == "" then return "" end
    trimmed = trimmed:gsub("^%s*%d+%s*[%.%-_%s]%s*", "")
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

-- Names that identify this instance's *patch* (as opposed to its ensemble), taken
-- from the Renoise instrument name. Reaktor snapshot names differ from the
-- Renoise label in small ways: a trailing index ("Sad Star 1"), dropped spaces
-- ("Deep Pulse Saw" vs "DeepPulse") or a shortened phrase ("Deep Pulse Saw" vs
-- the bank's "Deep Pulse"), so every contiguous word phrase of the label is
-- tested, in spaced and compacted form. Phrases shorter than MIN are skipped to
-- avoid matching unrelated text in the plugin state. Used to pick the snapshot
-- by name once a container's bank is loaded, which is necessary because a
-- container's snapshots repeat program numbers across banks.
local MIN_NAME_LENGTH = 6

local function patch_name_candidates(record)
  local names = {}
  local seen = {}
  local function add(name)
    if type(name) == "string" and name ~= "" and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  local function add_phrase(phrase)
    if #phrase:gsub("[^%w]", "") >= MIN_NAME_LENGTH then
      add(phrase)
      add(phrase:gsub("[^%w]", ""))
    end
  end
  local analysis = record.analysis
  local label = up_plugin_analysis.instrument_preset_label(record.instrument_name,
    analysis and analysis.protocol, analysis)
  if type(label) ~= "string" or label == "" then return names end
  label = label:gsub("%s+%d+$", "")
  local words = {}
  for word in label:gmatch("%S+") do words[#words + 1] = word end
  for first = 1, #words do
    local phrase = ""
    for last = first, #words do
      phrase = (last == first) and words[last] or (phrase .. " " .. words[last])
      add_phrase(phrase)
    end
  end
  -- Longest first, so a full-label match is preferred over a sub-phrase.
  table.sort(names, function(a, b)
    local la, lb = #(a:gsub("[^%w]", "")), #(b:gsub("[^%w]", ""))
    if la == lb then return a < b end
    return la > lb
  end)
  return names
end

-- A Reaktor state chunk embeds only the *active* snapshot's name, so finding a
-- patch name in the serialized state confirms that snapshot is selected. The
-- runtime value is Renoise's XML wrapper whose <ParameterChunk> CDATA is the
-- base64 of the binary chunk, so decode that before searching.
local function active_chunk_bytes(data)
  return up_preset.chunk_bytes(data)
end

-- True when a plugin state chunk belongs to a *container* plugin (Reaktor): its
-- ensemble reference lives inside the opaque decoded bytes, which the live API
-- hands back wrapped in the base64 <ParameterChunk> XML. Searching the wrapper
-- text for "file://" never matches, so decode first.
local function is_container_chunk(data)
  local bytes = active_chunk_bytes(data)
  return bytes ~= "" and up_preset.find_ensemble_url(bytes) ~= nil
end

-- The ensemble a container instance has loaded, used to pick a matching donor
-- state. The decoded chunk is authoritative: it holds the "file://.../Ensemble"
-- reference regardless of the active snapshot. Only when the chunk yields nothing
-- (e.g. no live device) fall back to the recovered name, which for a loaded
-- device would be the active *patch* rather than the ensemble.
local function instance_ensemble_name(record, old_data)
  local from_chunk = up_preset._extract_chunk_name(active_chunk_bytes(old_data))
  if from_chunk and from_chunk ~= "" then
    return from_chunk
  end
  if type(record.active_preset_name) == "string" and record.active_preset_name ~= "" then
    return record.active_preset_name
  end
  return nil
end

local function chunk_has_name(chunk, names)
  local bytes = active_chunk_bytes(chunk)
  if bytes == "" then return false end
  for _, name in ipairs(names or {}) do
    if type(name) == "string" and name ~= "" and bytes:find(name, 1, true) then
      return true
    end
  end
  return false
end

-- Route the MIDI loopback input to the instrument so Renoise forwards the
-- program/bank changes we send to its plugin. Best-effort.
local function route_loopback_to(instrument)
  if not instrument then return end
  local input = up_midi.input_device()
  if not input then return end
  pcall(function()
    instrument.midi_input_properties.device_name = input
    instrument.midi_input_properties.channel = (up_midi.channel or 0) + 1
  end)
end

-- Length of a name ignoring spaces/punctuation, used to prefer the longest match.
local function name_length(name)
  return #(name:gsub("[^%w]", ""))
end

-- Yield when a scheduler coroutine is driving us. Lua 5.4 reports the main
-- thread from coroutine.running() (with an is-main flag), so exclude it; outside
-- a coroutine this is a no-op and the synchronous tests stay unaffected.
local function yield_to_scheduler()
  local thread, is_main = coroutine.running()
  if thread and not is_main then coroutine.yield() end
end

-- Scan every bank and neighbouring program for a snapshot whose serialized state
-- contains one of `names`. Returns true on the first hit. Reaktor exposes no
-- bank-selection API, so this is a synchronous brute force whose per-attempt
-- chunk read is heavy; it yields between attempts so a single idle tick cannot
-- trip Renoise's script-busy watchdog. Aborts the scan if a Bank Select cannot be
-- sent: without it the host reads the previous bank and could report a false hit.
local function scan_banks_for_name(new_device, names, programs)
  if type(names) ~= "table" or #names == 0 then return false end
  for bank = 0, 15 do
    for _, program in ipairs(programs) do
      if program >= 0 and program <= 127 then
        -- Renoise consumes the program change for its own preset handling, so
        -- switch the plugin's bank with a raw Bank Select CC and let the host
        -- select the program within that bank.
        if not up_midi.select_bank(bank) then return false end
        pcall(function() new_device.active_preset = program end)
        yield_to_scheduler()
        for _ = 1, 2 do
          local ok, data = pcall(function() return new_device.active_preset_data end)
          if ok and chunk_has_name(data, names) then return true end
        end
      end
    end
  end
  return false
end

-- Select the patch by moving the plugin's bank with a raw Bank Select CC and
-- letting the host set the program, confirming the hit by the patch name in the
-- serialized state. Snapshots repeat program numbers across banks, so the bank
-- is discovered by trial. The full (longest) label is tried first so a real
-- snapshot wins over a shorter sub-phrase match such as "Make It". Requires the
-- full loopback route (output + matching enabled input): with only an output the
-- bank messages never reach the plugin, so the scan would read the wrong bank.
local function select_patch_via_midi(new_device, names, program_index)
  if type(names) ~= "table" or #names == 0 then return false end
  if not (program_index and program_index > 0) then return false end
  if not up_midi.has_loopback() then return false end
  local programs = { program_index, program_index + 1, program_index - 1,
    program_index + 2, program_index - 2 }
  local longest, max_length = {}, 0
  for _, name in ipairs(names) do
    local length = name_length(name)
    if length > max_length then
      max_length, longest = length, { name }
    elseif length == max_length then
      longest[#longest + 1] = name
    end
  end
  if scan_banks_for_name(new_device, longest, programs) then return true end
  return scan_banks_for_name(new_device, names, programs)
end

-- Renoise's active_preset_data is an XML wrapper
-- (<FilterDevicePreset><DeviceSlot ...>...<ParameterChunk><![CDATA[<binary>]]>...).
-- A live device's value can be assigned verbatim; a chunk recovered from Song.xml
-- is the raw plugin binary, so it must be base64-injected into the *new* device's
-- wrapper (keeping the new plugin identity) before Renoise will accept it.
local function is_xml_wrapper(data)
  return data:find("FilterDevicePreset", 1, true) ~= nil
    or data:find("^%s*<%?xml") ~= nil
end

local function set_active_preset_data(device, value)
  local ok_set = pcall(function() device.active_preset_data = value end)
  if not ok_set then return nil end
  local ok_get, got = pcall(function() return device.active_preset_data end)
  if ok_get and type(got) == "string" and got ~= "" then return got end
  return nil
end

local function inject_parameter_chunk(xml, encoded, old_active_preset)
  local chunk = "<ParameterChunk><![CDATA[" .. encoded .. "]]></ParameterChunk>"
  local rebuilt, count = xml:gsub("<ParameterChunk%s*/>", chunk, 1)
  if count == 0 then
    rebuilt, count = xml:gsub("<ParameterChunk%s*>.-</ParameterChunk>", chunk, 1)
  end
  if count == 0 then
    rebuilt, count = xml:gsub("(</DeviceSlot>)", chunk .. "%1", 1)
  end
  if count == 0 then return nil end
  -- The program number lives in the wrapper too (the reference Song.xml has
  -- <ActiveProgram>48</ActiveProgram>), so carry it over as well. active_preset
  -- is Renoise's 1-based API index while <ActiveProgram> is 0-based (-1 for
  -- none), so convert back before serialising.
  if old_active_preset and old_active_preset > 0 then
    local program = tostring(old_active_preset - 1)
    local with_program, program_count = rebuilt:gsub("<ActiveProgram>%s*%-?%d+%s*</ActiveProgram>",
      "<ActiveProgram>" .. program .. "</ActiveProgram>", 1)
    if program_count == 0 then
      with_program = rebuilt:gsub("(</DeviceSlot>)",
        "<ActiveProgram>" .. program .. "</ActiveProgram>%1", 1)
    end
    rebuilt = with_program
  end
  return rebuilt
end

-- Inject a raw plugin chunk into the replacement. When the replacement has no
-- XML wrapper yet (tests, or a device that exposes the raw chunk) assign it
-- directly.
local function transplant_raw_chunk(new_device, raw_chunk, old_active_preset)
  local encoded = up_preset.encode_chunk(raw_chunk)
  if not encoded then return false end
  local ok_xml, xml = pcall(function() return new_device.active_preset_data end)
  if not ok_xml or type(xml) ~= "string" then return false end
  if xml == "" then
    return set_active_preset_data(new_device, raw_chunk) ~= nil
  end
  if not is_xml_wrapper(xml) then
    return set_active_preset_data(new_device, raw_chunk) ~= nil
  end
  local rebuilt = inject_parameter_chunk(xml, encoded, old_active_preset)
  if not rebuilt then return false end
  local got = set_active_preset_data(new_device, rebuilt)
  return got ~= nil and got ~= xml
end

-- VST2 stores the plugin's raw serialized state; VST3 wraps the same engine
-- state inside a .vstpreset container. Convert between the two so a
-- same-product, same-version upgrade (e.g. Massive VST -> VST3) can carry the
-- patch and all non-parameter state, not just the name-matched parameters.
local function transplant_vst3(wrapper_or_preset, old_data, old_active_preset)
  local raw_chunk = active_chunk_bytes(old_data)
  if raw_chunk == "" or (raw_chunk == old_data and is_xml_wrapper(old_data)) then
    return false
  end
  local ok_xml, xml = pcall(function() return wrapper_or_preset.active_preset_data end)
  if not ok_xml or type(xml) ~= "string" then return false end
  local base = active_chunk_bytes(xml)
  local converted
  if up_vst3.parse(base) then
    converted = up_vst3.replace_component(base, raw_chunk)
  end
  if not converted then
    -- No usable container to patch (tests or an empty preset): build one from
    -- the replacement's own class id, which Renoise keeps in the wrapper.
    local class_id = xml:match("<PluginIdentifier>%s*([%x]+)%s*</PluginIdentifier>")
    converted = up_vst3.build(1, class_id, { { id = "Comp", data = raw_chunk } })
  end
  if not converted then return false end
  if not is_xml_wrapper(xml) then
    return set_active_preset_data(wrapper_or_preset, converted) ~= nil
  end
  local encoded = up_preset.encode_chunk(converted)
  if not encoded then return false end
  local rebuilt = inject_parameter_chunk(xml, encoded, old_active_preset)
  if not rebuilt then return false end
  local got = set_active_preset_data(wrapper_or_preset, rebuilt)
  return got ~= nil and got ~= xml
end

-- VST3 -> VST2: pull the engine state out of the .vstpreset container and write
-- it as the raw chunk the VST2 build expects.
local function transplant_vst2(new_device, old_data, old_active_preset)
  local preset = active_chunk_bytes(old_data)
  local component = up_vst3.component(preset)
  if not component then return false end
  return transplant_raw_chunk(new_device, component, old_active_preset)
end

local function transplant_chunk(new_device, old_data, old_active_preset, mode)
  if type(old_data) ~= "string" or old_data == "" then return false end
  if mode == "vst3" then
    return transplant_vst3(new_device, old_data, old_active_preset)
  end
  if mode == "vst2" then
    return transplant_vst2(new_device, old_data, old_active_preset)
  end
  if is_xml_wrapper(old_data) then
    return set_active_preset_data(new_device, old_data) ~= nil
  end
  return transplant_raw_chunk(new_device, old_data, old_active_preset)
end

-- Try to move the old plugin's state onto the newly inserted device.
-- Returns ("parameters"|"name"|"params") on success, or (nil, reason) on
-- failure. A parameter-chunk transplant only works for the same plugin at the
-- same version; a VST2 <-> VST3 upgrade of the same product at the same version
-- is converted through the .vstpreset container (see chunk_transfer_mode).
-- Everything else -- a different product/version (e.g. Kick -> Kick 2, both
-- VST) or an unrelated format -- loads a same-named factory preset as a base
-- (so unmapped parameters keep a sensible default), then overlays the old
-- plugin's captured parameter values (matched by name) on top -- which is what
-- actually carries the user's tweaks such as Mix. If no parameters map, we keep
-- the loaded preset; otherwise we return the synthesized result.
local function transfer_state(new_device, old_data, preset_names, chunk_mode, same_format,
    old_parameters, parameters_complete, old_active_preset, container, patch_names, reaktor,
    is_instrument, fallback_preset_names)
  -- A Renoise ParameterBag is only the plugin's exposed parameters, so nothing
  -- opaque is lost by transferring it by name. Prefer a same-named preset plus
  -- the parameter overlay in that case: replaying the bag by index carries
  -- normalized enum values across major versions, where they can select a
  -- different option (e.g. Saturn 1 "Warm Tape" -> Saturn 2 "Old Tape").
  local parameter_bag = up_preset.is_parameter_bag(old_data)
  -- A plugin with no complete set of live parameters to overlay -- a missing
  -- instrument, or a track device with non-automatable controls -- has only the
  -- recovered bag. Keep the compatible direct transplant in that case instead
  -- of selecting a preset and dropping the omitted settings.
  local has_live_parameters = old_parameters and #old_parameters > 0
  -- A ParameterBag is only safe to replay when the replacement is the same
  -- plugin at the same version and format, which is exactly a "direct" chunk
  -- transfer. A converted (cross-format) transfer would wrap host parameter data
  -- as native plugin state, so those always use the preset + overlay route.
  local direct_transfer = chunk_mode == "direct"
  -- A complete source snapshot is not enough for a direct transfer: the
  -- replacement may still be missing a writable target for some captured
  -- control (a renamed or non-automatable parameter). In that case the overlay
  -- would report success while dropping those saved values, so keep the
  -- compatible bag transplant whenever the mapping is incomplete.
  local overlay_complete = has_live_parameters and parameters_complete
  if overlay_complete and direct_transfer then
    overlay_complete = replacement_mapping_complete(new_device, old_parameters, is_instrument)
  end
  local prefer_name = parameter_bag and not container and not reaktor
    and (overlay_complete or not direct_transfer)

  -- Compatible chunks transplant directly or through a VST3 container. Reaktor
  -- keeps all its state (ensemble + snapshot) in the chunk, exposes no usable
  -- program bank otherwise, and reads its own previous-major chunk, so also
  -- attempt a cross-format transplant for it and let the plugin's own backward
  -- compatibility decide; verify the device took the data. Other containers
  -- (e.g. Kontakt) are not cross-format portable, so they only transplant when
  -- the format already matches.
  local converted = chunk_mode and chunk_mode ~= "direct"
  local baseline = nil
  if converted and old_parameters and #old_parameters > 0 then
    baseline = capture_parameter_baseline(new_device, old_parameters, is_instrument)
  end
  local transplanted = false
  if not prefer_name and old_data and old_data ~= "" and (chunk_mode or reaktor) then
    transplanted = transplant_chunk(new_device, old_data, old_active_preset,
      chunk_mode or "direct")
    -- A converted chunk that the plugin silently ignores reads back as a valid
    -- container, so confirm the settings that actually differed were restored.
    -- Unchanged defaults are excluded from the comparison by the baseline.
    if transplanted and converted and baseline then
      local comparable, restored = parameter_restoration(new_device, old_parameters,
        baseline, is_instrument)
      if comparable > 0 and restored == 0 then
        transplanted = false
      end
    end
  end

  -- Establish a base state from a same-named factory preset (if one exists in
  -- the new plugin). This gives unmapped parameters a sensible starting point.
  -- Skip it when the full state was transplanted -- that already carries the patch.
  local preset_loaded = false
  if not transplanted then
    preset_loaded = load_matching_preset(new_device, preset_names)
    if not preset_loaded and fallback_preset_names then
      preset_loaded = load_matching_preset(new_device, fallback_preset_names)
    end
  end

  -- Container plugins (Reaktor and friends) keep the patch as a snapshot in a
  -- bank supplied by the loaded ensemble, and snapshot program numbers repeat
  -- across banks, so the recorded number alone is ambiguous ("038 Palladion" in
  -- bank 4 vs "038 Sad Star" in bank 5). Prefer selecting by patch name now that
  -- the bank is loaded; fall back to the recorded program number. This is
  -- Reaktor-only: it is the plugin family whose banks are MIDI-addressable.
  if reaktor and container and old_active_preset and old_active_preset > 0 then
    if select_patch_via_midi(new_device, patch_names, old_active_preset) then
      preset_loaded = true
    elseif load_matching_preset(new_device, patch_names) then
      preset_loaded = true
    else
      local ok_set = pcall(function() new_device.active_preset = old_active_preset end)
      local ok_get, got = pcall(function() return new_device.active_preset end)
      if ok_set and ok_get and got == old_active_preset then
        preset_loaded = true
      end
    end
  end

  -- Overlay the old plugin's saved parameter values on top of the base. This is
  -- what actually carries the user's tweaks (e.g. Mix) across formats. Skip it
  -- when the full state was transplanted, which would otherwise clobber the patch.
  local label_rejected = false
  local mapped = 0
  if not transplanted and old_parameters and #old_parameters > 0 then
    local applied
    applied, label_rejected, mapped = apply_parameter_values(new_device, old_parameters, is_instrument)
    if applied > 0 then
      return "params", tostring(applied)
    end
  end

  if transplanted then
    return "parameters"
  end
  if preset_loaded then
    return "name"
  end

  -- A same-format ParameterBag that could not be mapped by name (no matching
  -- preset and no writable parameters) is still better replayed than left at
  -- default state, even though enum values may shift. Cross-format bags must
  -- never be replayed by index: their parameter layouts are not compatible.
  -- Do not replay when any parameter mapped: the overlay already made a
  -- deliberate choice (e.g. it kept the replacement's option after rejecting an
  -- unavailable enum label), and replaying indices would undo it.
  if prefer_name and same_format and not label_rejected and mapped == 0
      and old_data and old_data ~= "" then
    if transplant_chunk(new_device, old_data, old_active_preset, "direct") then
      return "parameters"
    end
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
  local old_parameters, parameters_complete = snapshot_parameters(old_device, false)
  local old_preset_name = up_preset.extract_name(old_device)
  local preset_names = preset_name_candidates(record.active_preset_name, old_preset_name)
  local old_active = nil
  local ok_active, is_active = pcall(function() return old_device.is_active end)
  if ok_active then old_active = is_active end
  local was_broken = record.broken
  local old_protocol = record.analysis and record.analysis.protocol
  local same_format = (old_protocol and old_protocol == candidate.protocol)
  -- The program number is only meaningful for a same-family container plugin whose
  -- patch lives in an external ensemble (Reaktor): a decoded "file://" reference in
  -- the old chunk, or one recovered from the song for a missing plugin. A loaded
  -- Reaktor device exposes the wrapper XML, so the chunk must be decoded first.
  local container = is_container_chunk(old_data) or record.ensemble_preset
  -- Track plugins are audio effects and receive no MIDI, so the Reaktor
  -- bank-select route cannot reach them: keep the generic chunk transplant but
  -- never claim MIDI-based snapshot selection or inject an ensemble donor.
  local reaktor = false
  local old_active_preset = nil
  local chunk_mode = chunk_transfer_mode(record.analysis, candidate, same_format)
  local patch_names = patch_name_candidates(record)

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
  local method, err = transfer_state(new_device, old_data, preset_names, chunk_mode,
    same_format, old_parameters, parameters_complete, old_active_preset, container,
    patch_names, reaktor, false)
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
  local parameters_complete = true
  local old_preset_name = nil
  local old_active = nil
  local captured_automation = {}
  if record.plugin_loaded and plugin_properties.plugin_device then
    local ok_preset_data, preset_data = pcall(function() return plugin_properties.plugin_device.active_preset_data end)
    if ok_preset_data then
      old_data = preset_data
    end
    old_parameters, parameters_complete = snapshot_parameters(plugin_properties.plugin_device, true)
    old_preset_name = up_preset.extract_name(plugin_properties.plugin_device)
    local ok_active, is_active = pcall(function() return plugin_properties.plugin_device.is_active end)
    if ok_active then old_active = is_active end
    captured_automation = capture_automation_data(plugin_properties.plugin_device, song)
  end
  -- A missing plugin has no live chunk, but Song.xml still holds its opaque state
  -- (recovered into record.active_preset_data). Use it as the transplant source so
  -- a backward-compatible replacement (Reaktor 5 -> 6) can take the pinned state.
  if (not old_data or old_data == "") and record.active_preset_data then
    old_data = record.active_preset_data
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
  -- replacement selects the right synth before its patch. The instrument label
  -- is kept separate as a fallback: Renoise records the selected preset in the
  -- instrument name ("VST: Massive (Acid Raw)"), but a live preset already
  -- recovered from the plugin must not be overwritten by a user-renamed
  -- instrument label.
  local instrument_label = up_plugin_analysis.instrument_preset_label(
    record.instrument_name, record.analysis and record.analysis.protocol, record.analysis)
  local preset_names = preset_name_candidates(record.active_preset_name, old_preset_name)
  local was_broken = record.broken
  local old_protocol = record.analysis and record.analysis.protocol
  local same_format = (old_protocol and old_protocol == candidate.protocol)
  -- The program number is only meaningful for a same-family container plugin whose
  -- patch lives in an external ensemble (Reaktor): a decoded "file://" reference in
  -- the old chunk, or one recovered from the song for a missing plugin. A loaded
  -- Reaktor device exposes the wrapper XML, so the chunk must be decoded first.
  local family_match = same_family(record.analysis, candidate)
  local container = is_container_chunk(old_data) or record.ensemble_preset
  -- Reaktor is the only family whose snapshot banks need (and can use) the MIDI
  -- loopback and the ensemble donor. Require BOTH sides to be Reaktor and the
  -- same family, so a cross-family swap (e.g. Kontakt -> Reaktor) cannot inject
  -- the Reaktor donor into an unrelated plugin.
  local reaktor = family_match and is_reaktor(record.analysis) and is_reaktor(candidate)
  local ensemble = instance_ensemble_name(record, old_data)
  -- For an ordinary plugin, try the instrument label only if the stronger live
  -- preset candidates did not resolve. Reaktor keeps its ensemble-then-patch
  -- sequence below, so it must not receive this fallback.
  local fallback_preset_names = nil
  if not (reaktor and container) then
    fallback_preset_names = preset_name_candidates(instrument_label)
  end
  local chunk_mode = chunk_transfer_mode(record.analysis, candidate, same_format)
  local donor_used
  old_data, donor_used = use_donor_chunk(old_data, family_match, reaktor, candidate, ensemble)
  -- Only an explicit donor substitution may change the mode: ordinary recovered
  -- state (e.g. a missing VST3's raw .vstpreset) must keep the compatibility
  -- rejection from chunk_transfer_mode.
  if donor_used then
    chunk_mode = adjust_chunk_mode(chunk_mode, old_data, candidate.protocol)
  end
  local old_active_preset = (family_match and container) and record.active_preset or nil
  local patch_names = patch_name_candidates(record)

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
  if reaktor and container then route_loopback_to(instrument) end
  local method, err = transfer_state(new_device, old_data, preset_names, chunk_mode,
    same_format, old_parameters, parameters_complete, old_active_preset, container,
    patch_names, reaktor, true, fallback_preset_names)
  -- transfer_state may load a factory preset, which can reactivate the device;
  -- restore the saved bypass state after the transfer (as the track path does).
  if old_active ~= nil then
    pcall(function() new_device.is_active = old_active end)
  end
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
