-- Tests for up_matching: candidate matching (exact, family, loose token,
-- shared-token), the multi-stage find_candidates fallback chain, and the two
-- candidate-pool builders (instrument + track) with their edge cases.

-- 4. up_matching --------------------------------------------------------------
section("up_matching.candidate_matches (exact)")
do
  local old = up_plugin_analysis.analyze_plugin(nil, "VST3: FabFilter Pro-MB")
  local same = analyze("VST3: FabFilter Pro-MB", "/P/ProMB.vst3", "VST3")
  local diffver = analyze("VST3: FabFilter Pro-Q 3", "/P/ProQ3.vst3", "VST3")
  check(up_matching.candidate_matches(same, old), "exact match same product+version")
  check(not up_matching.candidate_matches(diffver, old), "exact rejects different product")
end

section("up_matching.candidate_matches_loose")
do
  local old = up_plugin_analysis.analyze_plugin(nil, "VST: Sonic Academy: Kick - Nicky Romero")
  local kick2 = analyze("VST: Sonic Academy: Kick 2", "/P/Kick2.vst", "VST")
  check(up_matching.candidate_matches_loose(kick2, old), "Kick - Nicky Romero -> Kick 2")

  local oldr = up_plugin_analysis.analyze_plugin(nil, "AU: Native Instruments: Reaktor5")
  local r6 = analyze("Reaktor6", "/P/Reaktor6.app", "AU")
  check(up_matching.candidate_matches_loose(r6, oldr), "Reaktor5 -> Reaktor6 (vendor asymmetry)")

  local pq = analyze("VST3: FabFilter Pro-Q 3", "/P/ProQ3.vst3", "VST3")
  check(not up_matching.candidate_matches_loose(pq, oldr), "Reaktor vs Pro-Q: no false match")
end

section("up_matching.find_candidates (exact preferred, loose fallback)")
do
  local poolMB = { analyze("VST3: FabFilter Pro-MB", "/P/ProMB.vst3", "VST3") }
  check(#candidates_for("VST3: FabFilter Pro-MB", poolMB, false) == 1, "exact match used when present")

  local poolReak = { analyze("Reaktor6", "/P/Reaktor6.app", "AU") }
  check(#candidates_for("AU: Native Instruments: Reaktor5", poolReak, true) == 1,
    "missing Reaktor5 -> Reaktor6 (loose, broken)")

  local poolKick = { analyze("VST: Sonic Academy: Kick 2", "/P/Kick2.vst", "VST") }
  check(#candidates_for("VST: Sonic Academy: Kick - Nicky Romero", poolKick, true) == 1,
    "missing Kick-NR -> Kick 2 (loose, broken)")

  -- healthy cross-format / branding: previously not possible
  local poolProMB = { analyze("VST3: FabFilter Pro-MB", "/P/ProMB.vst3", "VST3") }
  check(#candidates_for("AU: FabFilter FF Pro MB", poolProMB, false) == 1,
    "healthy AU 'FF Pro MB' -> VST3 'Pro-MB' (loose fallback)")

  local poolQ = { analyze("VST3: FabFilter Pro-Q 3", "/P/ProQ3.vst3", "VST3") }
  check(#candidates_for("AU: FabFilter FF Pro MB", poolQ, false) == 0,
    "FF Pro MB -> Pro-Q 3: no cross-product match")

  -- cross-version upgrade: when both the old and new release are installed the
  -- tool must offer the newer version (not just mirror the old one back).
  local poolProL = {
    analyze("VST: FabFilter Pro-L", "/P/ProL1.vst", "VST"),
    analyze("VST: FabFilter Pro-L 2", "/P/ProL2.vst", "VST"),
  }
  local proL = candidates_for("VST: FabFilter Pro-L", poolProL, false)
  check(#proL == 2, "Pro-L -> [Pro-L, Pro-L 2] both offered")
  check(proL[1].name:find("Pro%-L 2") ~= nil, "Pro-L auto-upgrades to Pro-L 2 (newest first)")

  local poolKickBoth = {
    analyze("VST: Sonic Academy: Kick", "/P/Kick1.vst", "VST"),
    analyze("VST: Sonic Academy: Kick 2", "/P/Kick2.vst", "VST"),
  }
  local kick = candidates_for("VST: Sonic Academy: Kick", poolKickBoth, false)
  check(#kick == 2, "Kick -> [Kick, Kick 2] both offered")
  check(kick[1].name:find("Kick 2") ~= nil, "Kick auto-upgrades to Kick 2 (newest first)")

  -- only the new release installed (old one missing) still matches.
  local newProL = { analyze("VST: FabFilter Pro-L 2", "/P/ProL2.vst", "VST") }
  check(#candidates_for("VST: FabFilter Pro-L", newProL, false) == 1,
    "Pro-L -> Pro-L 2 when only the new release is installed")
  local newKick = { analyze("VST: Sonic Academy: Kick 2", "/P/Kick2.vst", "VST") }
  check(#candidates_for("VST: Sonic Academy: Kick", newKick, false) == 1,
    "Kick -> Kick 2 when only the new release is installed")

  -- fallback when only the live instrument name is known (no .xrns recovery, no
  -- plugin_properties name): the name "Kick - Nicky Romero" shares the significant
  -- product token "kick" with "Kick 2".
  check(#candidates_for("VST: Kick - Nicky Romero ()", newKick, false) == 1,
    "Kick - Nicky Romero (name only) -> Kick 2 via shared token")
  -- same-product upgrade still matches on the shared product token.
  local reaktor = { analyze("VST: Reaktor6", "/P/Reaktor6.vst", "VST") }
  check(#candidates_for("VST: Reaktor5 (Make It Bright)", reaktor, false) == 1,
    "Reaktor5 (name only) -> Reaktor6 via shared product token")
  -- but a DIFFERENT product must not match (no shared product token).
  local pq = { analyze("VST3: FabFilter Pro-Q 3", "/P/ProQ3.vst3", "VST3") }
  check(#candidates_for("VST: Reaktor5 (Make It Bright)", pq, false) == 0,
    "Reaktor5 (name only) does NOT match Pro-Q 3 (different product)")
end

section("up_matching.find_candidates never offers downgrades")
do
  local older_kontakt = analyze("VST3: Native Instruments: Kontakt 7",
    "/P/Kontakt7.vst3", "VST3")
  check(#candidates_for("VST3: Native Instruments: Kontakt 8", { older_kontakt }, false) == 0,
    "Kontakt 8 is not downgraded to an installed Kontakt 7")

  local same_kontakt = analyze("VST3: Native Instruments: Kontakt 8",
    "/P/Kontakt8.vst3", "VST3")
  local kontakt = candidates_for("VST3: Native Instruments: Kontakt 8",
    { older_kontakt, same_kontakt }, false)
  check(#kontakt == 1 and kontakt[1].version == 8,
    "only the same/newer Kontakt version is offered")

  -- The version may be glued to the product word in some plugin lists.
  check(#candidates_for("VST3: Kontakt8",
    { analyze("VST3: Kontakt7", "/P/Kontakt7.vst3", "VST3") }, false) == 0,
    "glued Kontakt8 is not downgraded to Kontakt7")
  check(#candidates_for("VST3: Kontakt 8.1 FX",
    { analyze("VST3: Kontakt 7 FX", "/P/Kontakt7FX.vst3", "VST3") }, false) == 0,
    "dotted Kontakt 8.1 FX is not downgraded to Kontakt 7 FX")
  check(#candidates_for("VST3: iZotope Ozone 11 Equalizer",
    { analyze("VST3: iZotope Ozone 10 Equalizer", "/P/Ozone10.vst3", "VST3") }, false) == 0,
    "Ozone 11 Equalizer is not downgraded to Ozone 10 Equalizer")
  local ozone_au = analyze("AU: iZotope Ozone 11 Equalizer", "/P/Ozone11.au", "AU")
  local ozone_clap = analyze("CLAP: iZotope Ozone 12 Equalizer", "/P/Ozone12.clap", "CLAP")
  local ozone = candidates_for("VST3: iZotope Ozone 11 Equalizer",
    { ozone_au, ozone_clap }, false)
  check(#ozone == 1 and ozone[1].protocol == "CLAP",
    "a rejected same-version Ozone AU match does not hide the newer CLAP release")

  -- Different explicit vendors must not be merged just because the product
  -- family and release numbers match.
  local vendor_a = analyze("VST: Vendor A: Compressor 3", "/P/CompA.vst", "VST")
  local vendor_b = analyze("CLAP: Vendor B: Compressor 3", "/P/CompB.clap", "CLAP")
  local compressors = candidates_for("VST: Vendor A: Compressor 2",
    { vendor_a, vendor_b }, false)
  check(#compressors == 1 and compressors[1].name:find("Vendor A") ~= nil,
    "a different explicit vendor is not offered as a replacement")
  local unprefixed = analyze("VST: Compressor 3", "/P/Comp.vst", "VST")
  check(#candidates_for("VST: Vendor A: Compressor 2", { unprefixed }, false) == 1,
    "a candidate without a vendor prefix remains matchable")

  -- A rejected older dotted release must not hide a valid newer one.
  local proq30 = analyze("VST3: FabFilter Pro-Q 3.0",
    "/P/ProQ30.vst3", "VST3")
  local proq40 = analyze("VST3: FabFilter Pro-Q 4.0",
    "/P/ProQ40.vst3", "VST3")
  local proq = candidates_for("VST3: FabFilter Pro-Q 3.1",
    { proq30, proq40 }, false)
  check(#proq == 1 and proq[1].name:find("Pro%-Q 4%.0") ~= nil,
    "an older dotted release does not hide a newer dotted release")

  -- A downgrade-only family match must not fall through to looser matching and
  -- surface a different product that merely shares a token.
  local older_plain = analyze("VST3: Kontakt 7", "/P/Kontakt7.vst3", "VST3")
  local kontakt_library = analyze("VST3: Kontakt 8 Library",
    "/P/Kontakt8Library.vst3", "VST3")
  check(#candidates_for("VST3: Kontakt 8",
    { older_plain, kontakt_library }, false) == 0,
    "a downgrade-only family match does not fall through to a loose match")

  -- A numeric vendor prefix must not look like a newer version.
  local phoscyon1 = analyze("VST3: D16 Group: Phoscyon 1",
    "/P/Phoscyon1.vst3", "VST3")
  check(#candidates_for("VST: Phoscyon 2", { phoscyon1 }, false) == 0,
    "numeric vendor prefix does not mask an older Phoscyon release")
  local phoscyon3 = analyze("VST3: D16 Group: Phoscyon 3",
    "/P/Phoscyon3.vst3", "VST3")
  local phoscyon = candidates_for("VST: Phoscyon 2", { phoscyon1, phoscyon3 }, false)
  check(#phoscyon == 1 and phoscyon[1].version == 3,
    "the newer Phoscyon release is still offered")

  -- An older release carrying the vendor prefix must not hide a newer release
  -- whose display name omits it.
  local reaktor4 = analyze("AU: Native Instruments: Reaktor4",
    "/P/Reaktor4.au", "AU")
  local reaktor6 = analyze("VST3: Reaktor6", "/P/Reaktor6.vst3", "VST3")
  local reaktor = candidates_for("AU: Native Instruments: Reaktor5",
    { reaktor4, reaktor6 }, false)
  check(#reaktor == 1 and reaktor[1].name:find("Reaktor6") ~= nil,
    "an older vendor-prefixed release does not hide a newer unprefixed one")

  -- An unknown protocol is not a confirmed downgrade: keep the candidate
  -- offered (the UI separately refuses to auto-select it).
  local unknown = analyze("Sonic Academy: Kick 2", "/P/Kick2", nil)
  check(unknown.protocol == nil, "fixture has no recoverable protocol")
  check(not up_matching.is_downgrade(unknown,
    analyze("VST: Sonic Academy: Kick", "/P/Kick.vst", "VST")),
    "an unknown protocol is not a confirmed downgrade")
  check(#candidates_for("VST: Sonic Academy: Kick", { unknown }, false) == 1,
    "an unknown-protocol candidate remains offered")

  -- An older version is a downgrade even when the protocol is higher.
  local old_vst3 = analyze("VST3: FabFilter Pro-Q 3", "/P/ProQ3.vst3", "VST3")
  local older_clap = analyze("CLAP: FabFilter Pro-Q 2", "/P/ProQ2.clap", "CLAP")
  check(up_matching.is_downgrade(older_clap, old_vst3),
    "an older version is a downgrade even on a higher protocol")

  -- A lower protocol is a downgrade at the same version.
  local au_same = analyze("AU: FabFilter Pro-Q 3", "/P/ProQ3.au", "AU")
  check(up_matching.is_downgrade(au_same, old_vst3),
    "a lower protocol is a downgrade at the same version")
  check(#candidates_for("VST3: FabFilter Pro-Q 3", { au_same }, false) == 0,
    "VST3 is not downgraded to AU")

  -- A higher protocol at the same version is still a real upgrade.
  local clap_same = analyze("CLAP: FabFilter Pro-Q 3", "/P/ProQ3.clap", "CLAP")
  local upgrades = up_matching.find_candidates({ au_same, clap_same }, old_vst3)
  check(#upgrades == 1 and upgrades[1].protocol == "CLAP",
    "a higher protocol at the same version is offered")
end

section("up_matching.build_instrument_pool (VST3 opaque paths)")
do
  local vst3_kick = { path = "{A1B2C3D4-0000-0000-0000-000000000000}", name = "Sonic Academy: Kick 2" }
  local vst_pl = { path = "/P/ProL2.vst", name = "FabFilter Pro-L 2" }
  local mock_song = {
    instruments = {
      { plugin_properties = { available_plugin_infos = { vst3_kick, vst_pl } } },
    },
  }
  local pool = up_matching.build_instrument_pool(mock_song, nil, nil)
  local names = {}
  for _, a in ipairs(pool) do names[a.name] = true end
  check(names["Sonic Academy: Kick 2"], "VST3 instrument with opaque path is kept in pool")
  check(names["FabFilter Pro-L 2"], "VST instrument with real path is kept in pool")
  local cands = up_matching.find_candidates(pool,
    { analysis = analyze("VST: Sonic Academy: Kick", "/P/Kick.vst", "VST") })
  check(#cands == 1 and cands[1].name:find("Kick 2") ~= nil
      and cands[1].protocol == "VST3",
    "old VST Kick -> opaque-handle VST3 Kick 2 candidate found in instrument pool")
end

section("up_matching.build_instrument_pool keeps Native Instruments plugins")
do
  local reaktor6_au = { path = "aumuRk6----", name = "Native Instruments: Reaktor 6" }
  local reaktor6_vst3 = { path = "{B2C3D4E5-0000-0000-0000-000000000000}", name = "Reaktor 6" }
  local mock_song = {
    instruments = {
      { plugin_properties = { available_plugin_infos = { reaktor6_au, reaktor6_vst3 } } },
    },
  }
  local pool = up_matching.build_instrument_pool(mock_song, nil, nil)
  local names = {}
  for _, a in ipairs(pool) do names[a.name] = true end
  check(names["Native Instruments: Reaktor 6"], "AU 'Native Instruments: Reaktor 6' kept in pool")
  check(names["Reaktor 6"], "VST3 'Reaktor 6' kept in pool")
   local cands = up_matching.find_candidates(pool,
     { analysis = up_plugin_analysis.analyze_plugin(nil, "AU: Native Instruments: Reaktor5") })
   check(#cands >= 1 and cands[1].name:find("Reaktor 6") ~= nil,
     "Reaktor 5 -> Reaktor 6 offered as upgrade")
end

section("up_matching.build_instrument_pool skips entries without a path")
do
  local good = { path = "/P/ProQ3.vst3", name = "FabFilter Pro-Q 3" }
  local nil_path = { path = nil, name = "Ghost Plugin" }
  local empty_path = { path = "", name = "Also Ghost" }
  local mock_song = {
    instruments = {
      { plugin_properties = { available_plugin_infos = { good, nil_path, empty_path } } },
    },
  }
  local pool = up_matching.build_instrument_pool(mock_song, nil, nil)
  check(#pool == 1, "only the entry with a real path is pooled (nil/empty dropped)")
  check(pool[1] and pool[1].path == "/P/ProQ3.vst3",
    "pooled entry keeps its valid path as the load handle")
end

section("up_matching.build_track_pool (strings + DeviceInfos)")
do
  -- A track exposing both available_devices (loadable paths) and
  -- available_device_infos (names). The pool must zip them and analyze each.
  local info = {
    { device_path = "/P/Kick2.vst", name = "Kick 2" },
    { device_path = "aumuRk6----", name = "Reaktor 6" },
    -- name provided as a getter function exercises the function branch of track_name_of.
    { device_path = "/P/ProQ3.vst3", name = function() return "FabFilter Pro-Q 3" end },
  }
  local mock_song = {
    tracks = { { available_devices = { "/P/Kick2.vst", "aumuRk6----", "/P/ProQ3.vst3" },
                available_device_infos = info } },
    instruments = {},
  }
  local pool = up_matching.build_track_pool(mock_song, nil, nil)
  local names = {}
  for _, a in ipairs(pool) do names[a.name] = true end
  check(names["Kick 2"] and names["Reaktor 6"] and names["FabFilter Pro-Q 3"],
    "track pool zips paths with DeviceInfo names (incl. getter)")
  -- The second track is never inspected because infos was found on the first.
  local mock_song2 = {
    tracks = {
      { available_devices = { "/P/Kick2.vst" },
        available_device_infos = { { device_path = "/P/Kick2.vst", name = "Kick 2" } } },
      { available_devices = { "Native/Gainer" },
        available_device_infos = { { device_path = "Native/Gainer", name = "Gainer" } } },
    },
    instruments = {},
  }
  local pool2 = up_matching.build_track_pool(mock_song2, nil, nil)
  check(#pool2 == 1, "only the first track's plugins are pooled (native device skipped, single scan)")
end

section("up_matching.build_track_pool falls back to instrument pool on empty")
do
  -- When no track devices exist, build_track_pool accepts the instrument pool as
  -- a fallback so track plugins named via instruments still surface.
  local inst_pool = { up_plugin_analysis.analyze_plugin("/P/Reaktor6.vst", "Reaktor 6") }
  inst_pool[1].path = "/P/Reaktor6.vst"
  local mock_song = { tracks = { { available_devices = {} } }, instruments = {} }
  local pool = up_matching.build_track_pool(mock_song, nil, nil, inst_pool)
  local names = {}
  for _, a in ipairs(pool) do names[a.name or a.product] = true end
  check(names["reaktor 6"], "fallback instrument pool feeds the track pool")
end

section("up_matching.build_instrument_pool falls back name to path")
do
  -- When info.name is empty, the pool should use info.path as the display name.
  local no_name = { path = "/P/Mystery.vst", name = "" }
  local mock_song = { instruments = { { plugin_properties = { available_plugin_infos = { no_name } } } } }
  local pool = up_matching.build_instrument_pool(mock_song, nil, nil)
  check(#pool == 1 and pool[1].name == "/P/Mystery.vst",
    "instrument with empty name uses its path as the name")
end

section("up_matching.safeget tolerates a throwing getter")
do
  -- track_name_of must not blow up if a DeviceInfo getter raises. The probe order
  -- is name, device_name, display_name, plugin_name, ... so the info below throws
  -- on display_name *before* the readable plugin_name is reached: without
  -- safeget's pcall the whole scan errors out instead of returning "Good".
  local info = setmetatable({}, { __index = function(_, k)
    if k == "display_name" then error("nope") end
    if k == "plugin_name" then return "Good" end
    return nil
  end })
  check(not pcall(function() return info.display_name end),
    "the mocked DeviceInfo really throws on display_name")
  local got = up_matching.build_track_pool(
    { tracks = { { available_devices = { "/P/X.vst" },
                   available_device_infos = { info } } },
      instruments = {} }, nil, nil)
  check(got and #got == 1 and got[1].name == "Good", "track_name_of ignores a throwing display_name getter")
end

section("up_matching.candidate_matches rejects the already-current plugin")
do
  local old = up_plugin_analysis.analyze_plugin("/P/Kick2.vst", "Kick 2")
  local same = up_plugin_analysis.analyze_plugin("/P/Kick2.vst", "Kick 2")
  same.path = "/P/Kick2.vst"
  check(not up_matching.candidate_matches(same, old), "same path as old.raw is rejected")
  local other = up_plugin_analysis.analyze_plugin("/P/Kick2b.vst", "Kick 2")
  other.path = "/P/Kick2b.vst"
  check(up_matching.candidate_matches(other, old), "different path with same base matches")
end

section("up_matching.vendor_ok treats empty vendor as unknown")
do
  check(up_matching.vendor_ok({ vendor = "" }, { vendor = "fabfilter" }),
    "empty old vendor -> unknown -> ok")
  check(up_matching.vendor_ok({ vendor = "fabfilter" }, { vendor = "" }),
    "empty candidate vendor -> unknown -> ok")
  check(not up_matching.vendor_ok({ vendor = "fabfilter" }, { vendor = "native" }),
    "mismatched known vendors -> not ok")
end

section("up_matching.find_candidate picks the highest-ranked exact match")
do
  local old = up_plugin_analysis.analyze_plugin("/P/Kick2.vst", "Kick 2")
  local pool = {
    up_plugin_analysis.analyze_plugin("/P/Kick2.vst", "Kick 2"),
    up_plugin_analysis.analyze_plugin("/P/Kick2b.vst", "Kick 2"),
  }
  pool[1].path, pool[2].path = "/P/Kick2.vst", "/P/Kick2b.vst"
  local best = up_matching.find_candidate(pool, old)
  check(best ~= nil, "an exact candidate is found")
end

section("up_matching.find_candidates exercises all three fallback tiers")
do
  -- family match, then loose, then shared-token, in order.
  local old = up_plugin_analysis.analyze_plugin(nil, "Reaktor5")
  local reaktor6 = up_plugin_analysis.analyze_plugin("aumuRk6----", "Reaktor 6")
  reaktor6.path = "aumuRk6----"
  local fam = up_matching.find_candidates({ reaktor6 }, old)
  check(#fam == 1, "family tier matches Reaktor5 -> Reaktor6")
  -- With no family match, the loose tier must fire.
  local old2 = up_plugin_analysis.analyze_plugin(nil, "Kick - Nicky Romero")
  local kick2 = up_plugin_analysis.analyze_plugin("/P/Kick2.vst", "Kick 2")
  kick2.path = "/P/Kick2.vst"
  local loose = up_matching.find_candidates({ kick2 }, old2)
  check(#loose == 1, "loose tier matches Kick - Nicky Romero -> Kick 2")
end

section("coverage: matching fallbacks + find_candidates")
do
  -- These exercise the newer candidate-matching code paths (family, loose token,
  -- shared-token, and the multi-stage find_candidates fallback chain).
  local old = analyze("AU: Native Instruments: Reaktor5", "Reaktor5.au", "AU")
  local c = up_matching.find_candidates({
    analyze("AU: Native Instruments: Reaktor6", "Reaktor6.au", "AU"),
    analyze("VST: Lennardigital Sylenth1", "/P/Sylenth1.vst", "VST"),
  }, old)
  check(c and #c >= 1 and c[1].base:find("reaktor"), "find_candidates offers Reaktor6 for missing Reaktor5")

  local oldf = analyze("VST3: FabFilter Pro-L", "/P/ProL.vst3", "VST3")
  local cf = analyze("VST3: FabFilter Pro-L 2", "/P/ProL2.vst3", "VST3")
  check(up_matching.candidate_matches_family(cf, oldf), "family matches Pro-L -> Pro-L 2")

  local oldk = analyze("VST: Kick - Nicky Romero ()", "/P/Kick.vst", "VST")
  local ck = analyze("VST: Kick 2", "/P/Kick2.vst", "VST")
  check(up_matching.candidate_matches_loose(ck, oldk), "loose matches Kick -> Kick 2 (artist suffix)")
  check(up_matching.candidate_matches_shared(ck, oldk), "shared token matches Kick -> Kick 2 by name")

  local exact = analyze("VST3: FabFilter Pro-MB", "/P/ProMB.vst3", "VST3")
  local diff = analyze("VST3: FabFilter Pro-Q 3", "/P/ProQ3.vst3", "VST3")
  check(not up_matching.candidate_matches(diff, exact), "exact match rejects different product")
  check(up_matching.vendor_ok({ vendor = "fabfilter" }, { vendor = "fabfilter" }), "vendor_ok true when vendors match")
  check(not up_matching.vendor_ok({ vendor = "fabfilter" }, { vendor = "native" }),
    "vendor_ok false when vendors differ")
end

section("coverage: up_matching.build_instrument_pool (paths, dups, fallback)")
do
  -- Entries with a real path are pooled; an empty path is skipped; an entry with
  -- only a name (no path) falls back to the path being the name; duplicate paths
  -- are de-duplicated via the seen table.
  local song = {
    instruments = {
      { plugin_properties = { available_plugin_infos = {
          { path = "/P/Reaktor6.vst", name = "Reaktor 6" },
          { path = "/P/Reaktor6.vst", name = "Reaktor 6" },  -- duplicate path (de-duped)
          { path = "", name = "EmptyPath" },                  -- empty path skipped
          { path = "/P/X.vst", name = "" },                  -- blank name -> path fallback
          { name = "NoPath Plugin" },                        -- no path -> skipped
      } } },
    },
  }
  local pool = up_matching.build_instrument_pool(song)
  local byname = {}
  for _, a in ipairs(pool) do byname[a.name] = true end
  check(#pool == 2, "build_instrument_pool pools unique path entries (dedup + skip empty)")
  check(byname["Reaktor 6"] and byname["/P/X.vst"], "name and path-fallback entries pooled")

  -- With no discoverable devices, the fallback pool is consulted.
  local song2 = { tracks = { {} } }
  local fb = { analyze("VST3: FabFilter Pro-Q 3", "/P/Q.vst3", "VST3") }
  local pool2 = up_matching.build_track_pool(song2, nil, nil, fb)
  check(#pool2 == 1 and pool2[1].base:find("pro q"), "build_track_pool uses the fallback pool")
end

section("coverage: up_matching.build_track_pool")
do
  local song = { tracks = {
    { available_devices = { "/P/Q.vst3" },
      available_device_infos = { { name = "FabFilter Pro-Q 3" } } },
  } }
  local pool = up_matching.build_track_pool(song)
  check(#pool == 1 and pool[1].base:find("pro q"), "build_track_pool zips devices + infos")
end

section("coverage: up_matching candidate_matches_family / _shared direct")
do
  local old = analyze("VST3: FabFilter Pro-L", "/P/ProL.vst3", "VST3")
  local same = analyze("VST3: FabFilter Pro-L 2", "/P/ProL2.vst3", "VST3")
  local diff = analyze("AU: Native Instruments: Reaktor5", "Reaktor5.au", "AU")
  check(not up_matching.candidate_matches_family(same, nil), "family: nil old -> false")
  check(not up_matching.candidate_matches_family(same, same),
    "family: identical path is not an upgrade candidate")
  check(up_matching.candidate_matches_family(same, old), "family: Pro-L -> Pro-L 2 matches")
  check(not up_matching.candidate_matches_family(diff, old), "family: Reaktor5 != Pro-L")

  -- Shared-token last resort: family differs, loose token match fails, but a
  -- significant product token is shared (only reached via find_candidates).
  local sh_old = analyze("VST: Reaktor 5 Extra", "/P/R5.vst", "VST")
  local sh_cand = analyze("VST: Reaktor 6 Other", "/P/R6.vst", "VST")
  check(not up_matching.candidate_matches_family(sh_cand, sh_old), "family: Reaktor 5 Extra != Reaktor 6 Other")
  check(not up_matching.candidate_matches_loose(sh_cand, sh_old), "loose: no subset between the two")
  check(up_matching.candidate_matches_shared(sh_cand, sh_old), "shared: shared 'reaktor' product token matches")

  check(not up_matching.candidate_matches_shared(same, nil), "shared: nil old -> false")
  check(not up_matching.candidate_matches_shared(same, same), "shared: identical path -> false")
  local empt = analyze("???", "/P/X.vst", "VST")
  check(not up_matching.candidate_matches_shared(empt, empt), "shared: empty token sets -> false")
end

section("coverage: up_matching.find_candidates fallback chain")
do
  -- Family match wins when available.
  local oldf = analyze("VST3: FabFilter Pro-L", "/P/ProL.vst3", "VST3")
  local fam = up_matching.find_candidates({ analyze("VST3: FabFilter Pro-L 2", "/P/ProL2.vst3", "VST3") }, oldf)
  check(#fam == 1 and fam[1].base:find("pro l 2"), "find_candidates prefers family match")

  -- Loose token match when no family match (Kick - Nicky Romero -> Kick 2).
  local oldk = analyze("VST: Kick - Nicky Romero ()", "/P/Kick.vst", "VST")
  local loose = up_matching.find_candidates({ analyze("VST: Kick 2", "/P/Kick2.vst", "VST") }, oldk)
  check(#loose == 1 and loose[1].base == "kick 2", "find_candidates falls back to loose token match")

  -- Shared-token last resort (Reaktor 5 Extra -> Reaktor 6 Other).
  local olds = analyze("VST: Reaktor 5 Extra", "/P/R5.vst", "VST")
  local shared = up_matching.find_candidates({ analyze("VST: Reaktor 6 Other", "/P/R6.vst", "VST") }, olds)
  check(#shared == 1 and shared[1].base:find("reaktor 6 other"),
    "find_candidates falls back to shared product token")

  -- No candidate matches -> empty list.
  local none = up_matching.find_candidates({ analyze("VST: Serum", "/P/Serum.vst", "VST") }, oldf)
  check(#none == 0, "find_candidates returns empty when nothing matches")

  -- An explicit vendor mismatch must not be rescued by the loose or shared
  -- tiers: only the unrelated vendor's product is installed.
  local oldv = analyze("VST: Vendor A: Compressor 2", "/P/AComp.vst", "VST")
  local sharedv = up_matching.find_candidates({
    analyze("CLAP: Vendor B: Compressor 3", "/P/BComp.clap", "CLAP"),
  }, oldv)
  check(#sharedv == 0, "mismatched vendor: shared-token tier rejected")
  local loosev = up_matching.find_candidates({
    analyze("VST: Vendor A Audio: Compressor 3", "/P/AAComp.vst", "VST"),
  }, oldv)
  check(#loosev == 0, "overlapping vendor tokens: loose tier rejected")
end
