-- Tests for up_plugin_analysis (plugin name analysis): protocol detection, native-path
-- discrimination, tokenisation, display-name normalisation, and the preset-label
-- extraction used for recovered plugins.

-- 2. up_plugin_analysis ----------------------------------------------------------------
section("up_plugin_analysis.analyze_plugin")
do
  local a = up_plugin_analysis.analyze_plugin(nil, "AU: Native Instruments: Reaktor5")
  check(a.protocol == "AU", "protocol detected from display name (AU)")
  check(a.base:find("reaktor5") ~= nil, "base keeps version (reaktor5)")
  check(up_plugin_analysis.family_base("native instruments: reaktor 6") == "native instruments: reaktor",
    "family_base strips trailing version")

  local a2 = up_plugin_analysis.analyze_plugin(nil, "VST: Sonic Academy: Kick - Nicky Romero")
  check(a2.base:find("kick") ~= nil and a2.base:find("nicky") ~= nil,
    "base includes artist suffix tokens")

  -- VST3 instruments can be exposed as opaque GUID handles, which carry no
  -- readable protocol token. Recover VST3 from the handle shape.
  local vst3 = up_plugin_analysis.analyze_plugin(
    "{A1B2C3D4-0000-0000-0000-000000000000}", "Audio Damage: Rough Rider 3")
  check(vst3.protocol == "VST3",
    "opaque GUID handle takes precedence over substring protocol inference")
  local vendor_a = up_plugin_analysis.analyze_plugin(nil, "VST: Vendor A: Compressor 2")
  check(vendor_a.vendor == "vendor a", "explicit vendor prefix is preserved")
end

section("up_plugin_analysis family_key / version_components")
do
  check(up_plugin_analysis.family_key("native instruments: reaktor 5") == "reaktor",
    "family_key strips the vendor prefix")
  check(up_plugin_analysis.family_key("reaktor 6") == "reaktor",
    "family_key keeps vendor-less names addressable")
  check(up_plugin_analysis.family_key("d16 group: phoscyon 2") == "phoscyon",
    "family_key handles numeric vendor prefixes")
  check(up_plugin_analysis.family_key("fabfilter pro q 3 1") == "pro q",
    "family_key strips the complete dotted version run")
  check(up_plugin_analysis.family_key("ozone 11 equalizer") == "ozone equalizer",
    "family_key strips a release number before a qualifier")
  check(up_plugin_analysis.family_key("ozone 12 equalizer") == "ozone equalizer",
    "qualified releases share one family key")

  local function joined(text)
    return table.concat(up_plugin_analysis.version_components(text), ".")
  end
  check(joined("d16 group: phoscyon 1") == "1",
    "version_components ignores a numeric vendor prefix")
  check(joined("phoscyon 2") == "2", "version_components reads a spaced version")
  check(joined("kontakt8") == "8", "version_components reads an attached version")
  check(joined("kontakt6 fx") == "6",
    "version_components reads an attached version before a suffix")
  check(joined("kontakt 8 1 fx") == "8.1",
    "version_components keeps every component of a dotted version before FX")
  check(joined("ozone 11 equalizer") == "11",
    "version_components reads a release number before a product qualifier")
  check(joined("kontakt 8 library") == "8",
    "version_components reads a release number before a library qualifier")
  check(joined("pro q 2 0") == "2", "version_components reads dotted versions and trims zeroes")
  check(joined("8dio adagio 2") == "2",
    "version_components ignores a leading numeric vendor")
end

section("up_plugin_analysis.is_native_path (native namespace, not vendor)")
do
  -- Renoise's built-in devices live under "Native/" (e.g. Audio/Effects/Native/Gainer).
  check(up_plugin_analysis.is_native_path("Audio/Effects/Native/Gainer"), "built-in native device path is native")
  check(up_plugin_analysis.is_native_path("Audio/Instruments/Native/Multi-Sampler"), "native instrument path is native")
  -- The vendor "Native Instruments" must NOT be mistaken for a built-in device,
  -- otherwise every plugin from that vendor (Reaktor, Kontakt, ...) is dropped
  -- from the candidate pool and can never be offered as an upgrade.
  check(not up_plugin_analysis.is_native_path("Native Instruments: Reaktor 6"),
    "vendor 'Native Instruments' is NOT native")
  check(not up_plugin_analysis.is_native_path("/Library/Audio/Plug-Ins/VST/Native Instruments/Reaktor 6.vst"),
    "filesystem path under 'Native Instruments' is NOT native")
  check(not up_plugin_analysis.is_native_path("VST: Native Instruments: Kontakt 7"),
    "display name with 'Native Instruments' is NOT native")
end

section("up_plugin_analysis.token_set / token_subset")
do
  local t1 = up_plugin_analysis.token_set("Sonic Academy: Kick - Nicky Romero")
  check(t1.kick and t1.nicky and t1.romero, "token_set splits significant words (e.g. Kick - Nicky - Romero)")
  local t2 = up_plugin_analysis.token_set("FabFilter Pro-Q 3")
  check(t2["q"], "single-char token 'q' is preserved (Pro-Q)")
  check(up_plugin_analysis.token_subset(up_plugin_analysis.token_set("fabfilter pro mb"),
                             up_plugin_analysis.token_set("fabfilter pro mb")),
    "token_subset: equal sets")
  check(not up_plugin_analysis.token_subset(up_plugin_analysis.token_set("fabfilter pro q"),
                                 up_plugin_analysis.token_set("fabfilter pro mb")),
    "token_subset: Pro-Q not subset of Pro-MB")
end

section("up_plugin_analysis.strip_redundant_prefix")
do
  local a = up_plugin_analysis.analyze_plugin(nil, "AU: Native Instruments: Reaktor5")
  local extra = up_plugin_analysis.strip_redundant_prefix("Reaktor5 Make It Bright", "AU", a)
  check(extra == "Make It Bright", "strips plugin-name tokens, keeps patch name")
end

section("up_plugin_analysis.format_plugin")
do
  check(up_plugin_analysis.format_plugin("VST: Lennardigital Sylenth1", "VST") == "VST: Lennardigital Sylenth1",
    "format_plugin re-emits protocol + name")
end

section("coverage: up_plugin_analysis.instrument_preset_label variants")
do
  local reaktor_a = up_plugin_analysis.analyze_plugin(nil, "VST: Native Instruments: Reaktor5")
  local label = function(name, protocol, analysis)
    return up_plugin_analysis.instrument_preset_label(name, protocol, analysis)
  end
  check(label("VST: Reaktor5 (Make It Bright)", "VST", reaktor_a) == "Make It Bright",
    "label recovered from parenthetical preset")
  check(label("Cinematic Pad 1", "AU", nil) == "Cinematic Pad 1",
    "label is a bare user patch name")
  check(label("Dark Dreams 1", "AU", reaktor_a) == "Dark Dreams 1",
    "label is the user patch when unrelated to the plugin name")
  check(label("VST: Reaktor5", "VST", reaktor_a) == "",
    "empty label when the name is only the plugin itself")

  -- Hyphenated product words (e.g. "Pro-Q") must be recognized as the plugin's own
  -- identity, not leaked as a user preset label.
  local proq = up_plugin_analysis.analyze_plugin(nil, "VST3: FabFilter Pro-Q")
  check(label("VST3: FabFilter Pro-Q", "VST3", proq) == "",
    "hyphenated product name (Pro-Q) is the plugin, not a preset")
  check(label("VST3: FabFilter Pro-Q (My Patch)", "VST3", proq) == "My Patch",
    "preset after a hyphenated plugin name is still carried over")
end
