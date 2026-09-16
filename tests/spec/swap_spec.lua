-- Tests for up_swap: the actual plugin replacement (track device + instrument
-- plugin), preset/parameter/automation transfer, and the up-to-date / rejected
-- / error branches.

section("up_swap.swap_instrument handles missing (unloaded) plugin")
do
  -- A missing plugin has no live device, so captured_auto would be nil; this must
  -- not crash on pairs(nil) in restore_automation_data.
  local new_dev = { is_active = true, active_preset_data = "", presets = {}, parameters = {} }
  local pp = {
    plugin_loaded = false,
    plugin_device = nil,
    load_plugin = function(self)
      self.plugin_device = new_dev
      return true
    end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = {
    kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "VST: Kick - Nicky Romero ()", analysis = { protocol = "VST" }, device_path = nil,
  }
  local candidate = { path = "/P/Kick2.vst" }
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  if not ok then print("SWAP ERROR:", tostring(res)) end
  check(ok, "swap_instrument does not crash on a missing plugin")
  check(ok and res and res.status ~= nil, "swap_instrument returns a status for a missing plugin")
end

section("up_swap.swap_instrument skips an already-current plugin")
do
  -- When the auto-selected candidate is the plugin already loaded at an instrument,
  -- reloading it via load_plugin is wasted work and, for heavy synths, can exceed
  -- Renoise's script-time budget and trip the "script busy" watchdog. The swap
  -- must be skipped (status up-to-date) instead of reloading the same plugin.
  local captured_count = 0
  local new_dev = { is_active = true, active_preset_data = "", presets = {}, parameters = {} }
  local pp = {
    plugin_loaded = true,
    plugin_device = new_dev,
    load_plugin = function(self, _path)
      captured_count = captured_count + 1
      self.plugin_device = new_dev
      return true
    end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = {
    kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "LD SidMon", analysis = { protocol = "VST" }, device_path = "/P/Sylenth1.vst",
  }
  local candidate = { path = "/P/Sylenth1.vst" }
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok, "swap_instrument handles an already-current plugin")
  check(ok and res and res.status == "up-to-date", "already-current plugin is skipped (no reload)")
  check(captured_count == 0, "load_plugin was NOT called for an already-current plugin")
end

section("up_swap.swap_instrument uses parenthetical label as preset for broken plugins")
do
  -- For a missing/recovered plugin named "VST: Reaktor5 (Make It Bright)", the
  -- parenthetical is the real preset; it must be extracted (not the full identity)
  -- so it can match a factory preset on the replacement plugin.
  local new_dev = {
    is_active = true, active_preset_data = "", presets = { "Make It Bright", "Other" }, parameters = {} }
  local pp = {
    plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "VST: Reaktor5 (Make It Bright)", analysis = { protocol = "VST" }, device_path = nil }
  local candidate = { path = "/P/Reaktor6.vst", protocol = "VST" }
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-name-matched-preset",
    "broken plugin's parenthetical preset name matches a factory preset")
end

section("up_swap.swap_instrument ignores an empty () in a broken instrument name")
do
  -- Renoise appends an empty "()" to some broken instrument names. The empty
  -- parenthetical must NOT be kept as a (truthy) preset name; the full name
  -- should fall through as the preset instead.
  local new_dev = {
    is_active = true, active_preset_data = "", presets = { "My Song ()", "Other" }, parameters = {} }
  local pp = {
    plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "My Song ()", analysis = { protocol = "VST" }, device_path = nil }
  local candidate = { path = "/P/Reaktor6.vst", protocol = "VST" }
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-name-matched-preset",
    "empty parenthetical does not shadow the real preset name")
end

section("up_swap.swap_instrument selects the recovered Reaktor ensemble")
do
  -- A missing Reaktor exposes no live preset, but its loaded ensemble ("Razor")
  -- is recovered from Song.xml into active_preset_name. The replacement must
  -- select that ensemble (not only try the instrument-name patch), otherwise the
  -- new Reaktor6 instance opens without Razor loaded. Reaktor's bank labels the
  -- entry with its file extension ("Razor.rkplr"), so the match must ignore it.
  local new_dev = {
    is_active = true, active_preset_data = "", presets = { "Razor.rkplr", "Other.rkplr" }, parameters = {} }
  local pp = {
    plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "Dark Dreams 1", active_preset_name = "Razor",
    analysis = { protocol = "AU" }, device_path = nil }
  local candidate = { path = "/P/Reaktor6.au", protocol = "AU" }
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok, "swap_instrument handles a recovered Reaktor ensemble")
  check(ok and res and res.status == "upgraded-name-matched-preset",
    "recovered ensemble name matches an extension-bearing program")
  check(new_dev.active_preset == 1, "replacement selects the recovered Razor.rkplr ensemble")
end

section("up_swap.swap_instrument selects the ensemble then its patch")
do
  -- Reaktor's program bank changes once an ensemble is selected: loading "Razor"
  -- exposes that ensemble's snapshots, so the user's patch ("Dark Dreams 1") can
  -- be resolved too. The preset list must be re-read after each load so both the
  -- ensemble and the old preset end up selected. Bank entries carry file
  -- extensions, while the recovered/instrument names do not.
  local state = { active_preset = 0, selected = {} }
  local new_dev = setmetatable({ is_active = true, active_preset_data = "", parameters = {} }, {
    __index = function(_, key)
      if key == "active_preset" then return state.active_preset end
      if key == "presets" then
        if state.active_preset == 0 then return { "Razor.rkplr", "Other Ensemble.rkplr" } end
        return { "Bright Dreams.nrkt", "Dark Dreams 1.nrkt" }
      end
      return nil
    end,
    __newindex = function(_, key, value)
      if key == "active_preset" then
        state.active_preset = value
        state.selected[#state.selected + 1] = value
      else
        rawset(_, key, value)
      end
    end,
  })
  local pp = {
    plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _path) self.plugin_device = new_dev; return true end,
  }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "Dark Dreams 1", active_preset_name = "Razor",
    analysis = { protocol = "AU" }, device_path = nil }
  local candidate = { path = "/P/Reaktor6.au", protocol = "AU" }
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-name-matched-preset",
    "replacement loads the ensemble and then the patch")
  check(state.selected[1] == 1, "the Razor ensemble is selected first")
  check(state.selected[2] == 2, "the old patch within Razor is selected next")
  check(new_dev.presets[state.active_preset] == "Dark Dreams 1.nrkt",
    "the active program is the old patch")
end

section("up_swap.swap_instrument resolves the patch when the bank loads in stages")
do
  -- A healthy Reaktor reports its active preset name ("Dark Dreams") and, from the
  -- chunk, the ensemble name ("Razor"). The candidate order can put the patch first
  -- even though the ensemble must be selected before the patch exists in the bank;
  -- a second pass must therefore re-resolve the patch.
  local snapshots = {}
  for i = 1, 60 do snapshots[i] = "Snap " .. i end
  snapshots[48] = "Dark Dreams"
  local state = { active_preset = 0 }
  local new_dev = setmetatable({ is_active = true, active_preset_data = "", parameters = {} }, {
    __index = function(_, key)
      if key == "active_preset" then return state.active_preset end
      if key == "presets" then
        if state.active_preset == 0 then return { "Razor.rkplr" } end
        return snapshots
      end
      return nil
    end,
    __newindex = function(_, key, value)
      if key == "active_preset" then state.active_preset = value
      else rawset(_, key, value) end
    end,
  })
  local pp = { plugin_loaded = true,
    plugin_device = { device_path = "/P/Reaktor5.au", name = "AU: Native Instruments: Reaktor5",
      active_preset = 0, presets = {},
      active_preset_data = "\0file://localhost/Users/Shared/Razor/Razor.rkplr\0", parameters = {} },
    load_plugin = function(self, _p) self.plugin_device = new_dev; return true end }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "Dark Dreams 1", active_preset_name = "Dark Dreams",
    analysis = analyze("AU: Native Instruments: Reaktor5", nil, "AU"), device_path = "/P/Reaktor5.au" }
  local candidate = analyze("VST3: Native Instruments: Reaktor 6", "/P/Reaktor6.vst3", "VST3")
  candidate.path = "/P/Reaktor6.vst3"
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-name-matched-preset",
    "the patch is found after the ensemble populates the bank")
  check(state.active_preset == 48, "the Dark Dreams snapshot is active")
end

section("up_swap.swap_instrument restores the active program number")
do
  -- Reaktor 5 and 6 share the program bank: program 48 is the same snapshot. When
  -- the snapshot's name can't be matched (it lives only in the old opaque chunk)
  -- the recorded program number is restored instead, after the ensemble is loaded.
  local snapshots = {}
  for i = 1, 60 do snapshots[i] = "Snap " .. i end
  local state = { active_preset = 0 }
  local new_dev = setmetatable({ is_active = true, active_preset_data = "", parameters = {} }, {
    __index = function(_, key)
      if key == "active_preset" then return state.active_preset end
      if key == "presets" then
        if state.active_preset == 0 then return { "Razor.rkplr" } end
        return snapshots
      end
      return nil
    end,
    __newindex = function(_, key, value)
      if key == "active_preset" then state.active_preset = value
      else rawset(_, key, value) end
    end,
  })
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
  check(ok and res and res.status == "upgraded-name-matched-preset",
    "the ensemble is loaded and the program number restored")
  check(state.active_preset == 48, "the recorded program number (48) is restored")
end

section("up_swap.swap_instrument does not carry a program number to a flat bank")
do
  -- A normal plugin (no ensemble file) has a flat factory bank, so the old
  -- program number may mean a different preset in the new version. The name match
  -- must win and the number must not be applied.
  local new_dev = { is_active = true, active_preset_data = "", presets = { "Some Preset" }, parameters = {} }
  local pp = { plugin_loaded = true,
    plugin_device = { device_path = "/P/ProQ2.vst3", name = "VST3: FabFilter Pro-Q 2",
      active_preset = 5, presets = { "Some Preset" }, active_preset_data = "", parameters = {} },
    load_plugin = function(self, _p) self.plugin_device = new_dev; return true end }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
    instrument_name = "ProQ", active_preset_name = "Some Preset", active_preset = 5,
    analysis = analyze("VST3: FabFilter Pro-Q 2", "/P/ProQ2.vst3", "VST3"), device_path = "/P/ProQ2.vst3" }
  local candidate = analyze("VST3: FabFilter Pro-Q 3", "/P/ProQ3.vst3", "VST3")
  candidate.path = "/P/ProQ3.vst3"
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-name-matched-preset",
    "the flat-bank preset is matched by name")
  check(new_dev.active_preset == 1, "the name match is kept, not the old program number")
end

section("up_swap.swap_instrument matches a bank name that lacks the index suffix")
do
  -- Renoise instrument names carry a numeric suffix ("Dark Dreams 1") while the
  -- Reaktor snapshot does not ("Dark Dreams"); the lookup must ignore the suffix.
  local new_dev = { is_active = true, active_preset_data = "", presets = { "Dark Dreams" }, parameters = {} }
  local pp = { plugin_loaded = false, plugin_device = nil,
    load_plugin = function(self, _p) self.plugin_device = new_dev; return true end }
  local song = { instruments = { { plugin_properties = pp } }, automation = function() return nil end }
  local rec = { kind = "instrument", instrument_index = 1, broken = true, plugin_loaded = false,
    instrument_name = "Dark Dreams 1", analysis = { protocol = "AU" }, device_path = nil }
  local candidate = { path = "/P/Reaktor6.au", protocol = "VST3" }
  local ok, res = pcall(function() return up_swap.swap_instrument(song, rec, candidate) end)
  check(ok and res and res.status == "upgraded-name-matched-preset",
    "the suffix-less snapshot name is matched")
  check(new_dev.active_preset == 1, "the Dark Dreams snapshot is selected")
end

section("coverage: up_swap.swap_track_device upgrades a track plugin")
do
  local track = {
    devices = { [1] = {}, [2] = { is_active = true, active_preset_data = "", parameters = {} } },
    insert_device_at = function(self, _path, idx)
      local dev = { is_active = true, active_preset_data = "", presets = {}, parameters = {} }
      table.insert(self.devices, idx, dev); return dev
    end,
    delete_device_at = function(self, idx) table.remove(self.devices, idx) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/Sylenth1.vst", device_name = "VST: Lennardigital Sylenth1",
    analysis = analyze("VST: Lennardigital Sylenth1", "/P/Sylenth1.vst", "VST") }
  local candidate = { name = "Sylenth1", protocol = "VST", path = "/P/Sylenth1-VST3.vst" }
  local ok, res = pcall(function() return up_swap.swap_track_device(song, rec, candidate) end)
  check(ok and res and res.status ~= nil, "swap_track_device upgrades the track plugin")
end

section("coverage: up_swap.swap_track_device up-to-date + rejected")
do
  local track = {
    devices = { [1] = {}, [2] = { is_active = true, active_preset_data = "", parameters = {} } },
    insert_device_at = function(self, _path, idx)
      local dev = { is_active = true, active_preset_data = "", presets = {}, parameters = {} }
      table.insert(self.devices, idx, dev); return dev
    end,
    delete_device_at = function(self, idx) table.remove(self.devices, idx) end,
  }
  local song = { tracks = { track }, instruments = {},
    automation = function() return { is_automated = false } end }

  -- Candidate is the plugin already loaded at this device: skip (up-to-date).
  local rec = { kind = "track", track_index = 1, device_index = 2, is_plugin = true,
    device_path = "/P/Sylenth1.vst", device_name = "VST: Lennardigital Sylenth1",
    analysis = analyze("VST: Lennardigital Sylenth1", "/P/Sylenth1.vst", "VST") }
  local same = up_swap.swap_track_device(song, rec, { name = "Sylenth1", protocol = "VST",
    path = "/P/Sylenth1.vst" })
  check(same and same.status == "up-to-date", "swap_track_device skips an already-current plugin")

  -- insert_device_at failing yields a transfer-rejected status (no crash).
  local track2 = {
    devices = { [1] = {}, [2] = { is_active = true, active_preset_data = "", parameters = {} } },
    insert_device_at = function() return nil end,
    delete_device_at = function() end,
  }
  local song2 = { tracks = { track2 }, instruments = {},
    automation = function() return { is_automated = false } end }
  local rejected = up_swap.swap_track_device(song2, rec, { name = "Sylenth1", protocol = "VST",
    path = "/P/Sylenth1-VST3.vst" })
  check(rejected and rejected.status == "skipped-transfer-rejected",
    "swap_track_device reports rejected when insert fails")
end

section("coverage: up_swap.swap_instrument transfer-state branches")
do
  local mkrec = function(proto)
    return { kind = "instrument", instrument_index = 1, broken = false, plugin_loaded = true,
      instrument_name = "Old", device_path = "/P/MB.vst3", device_name = "VST3: Pro-MB",
      analysis = analyze("VST3: Pro-MB", "/P/MB.vst3", proto or "VST3") }
  end

  -- Same-format preset chunk transfer ("parameters").
  local new_dev_p = { is_active = true, active_preset_data = "", presets = {}, parameters = {} }
  local pp_p = { plugin_loaded = true,
    plugin_device = { device_path = "/P/MB.vst3", name = "VST3: Pro-MB",
      active_preset_data = "<PresetName>Old</PresetName>", parameters = {} },
    load_plugin = function(self, _p) self.plugin_device = new_dev_p; return true end }
  local song_p = { instruments = { { plugin_properties = pp_p } }, tracks = {},
    automation = function() return { is_automated = false } end }
  local okp, rp = pcall(function() return up_swap.swap_instrument(song_p, mkrec("VST3"),
    { name = "Pro-MB 2", protocol = "VST3", path = "/P/MB2.vst3" }) end)
  check(okp and rp, "swap_instrument transfers same-format preset chunk")
  check(okp and rp and rp.status == "upgraded-with-parameters", "same-format chunk transfer -> parameters")

  -- Factory-preset base name match ("name").
  local new_dev_n = { is_active = true, active_preset_data = "", presets = { "Old" }, parameters = {} }
  local pp_n = { plugin_loaded = true,
    plugin_device = { device_path = "/P/MB.vst3", name = "VST3: Pro-MB",
      active_preset = 1, presets = { "Old" }, active_preset_data = "" },
    load_plugin = function(self, _p) self.plugin_device = new_dev_n; return true end }
  local song_n = { instruments = { { plugin_properties = pp_n } }, tracks = {},
    automation = function() return { is_automated = false } end }
  local okn, rn = pcall(function() return up_swap.swap_instrument(song_n, mkrec("VST3"),
    { name = "Pro-MB 2", protocol = "VST3", path = "/P/MB2.vst3" }) end)
  check(okn and rn and rn.status == "upgraded-name-matched-preset", "factory-preset base name match -> name")

  -- Parameter overlay ("params").
  local new_dev_x = { is_active = true, active_preset_data = "", presets = {},
    parameters = { { name = "Mix", is_automatable = true } } }
  local pp_x = { plugin_loaded = true,
    plugin_device = { device_path = "/P/MB.vst3", name = "VST3: Pro-MB",
      active_preset_data = "", parameters = { { name = "Mix", value = 0.5, is_automatable = true } } },
    load_plugin = function(self, _p) self.plugin_device = new_dev_x; return true end }
  local song_x = { instruments = { { plugin_properties = pp_x } }, tracks = {},
    automation = function() return { is_automated = false } end }
  local okx, rx = pcall(function() return up_swap.swap_instrument(song_x, mkrec("AU"),
    { name = "Pro-MB 2", protocol = "AU", path = "/P/MB2.au" }) end)
  check(okx and rx and rx.status == "upgraded-parameter-synth", "cross-format parameter overlay -> params")

  -- load_plugin failing yields a transfer-rejected status (no crash).
  local pp_bad = { plugin_loaded = true,
    plugin_device = { device_path = "/P/MB.vst3", name = "VST3: Pro-MB", active_preset_data = "" },
    load_plugin = function() return nil end }
  local song_bad = { instruments = { { plugin_properties = pp_bad } }, tracks = {},
    automation = function() return { is_automated = false } end }
  local okb, rb = pcall(function() return up_swap.swap_instrument(song_bad, mkrec("VST3"),
    { name = "Pro-MB 2", protocol = "VST3", path = "/P/MB2.vst3" }) end)
  check(okb and rb and rb.status == "skipped-transfer-rejected", "swap_instrument reports rejected when load fails")
end
