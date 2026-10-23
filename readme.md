# Plup

![Lint][lint-badge]
![Tests][tests-badge]
[![codecov][codecov-badge]][codecov]
![License][license-badge]
![Renoise API][renoise-api-badge]
![Lua][lua-badge]

Plup (short for **Pl**ugin **up**dater) is a [Renoise][] tool that scans
the current song for **outdated or broken plugin devices** (track FX chains
and instrument plugins), finds the best installed candidate, and upgrades
them while trying to preserve the previous preset/state.

## What it does

1. **Inventory (read-only).** Walks every track device (skipping the mixer
   device at index 1) and every instrument plugin. For each plugin it
   records its location, `device_path`/`name`, whether the API can still
   read its fields (this directly answers the "are broken devices visible?"
   question), and the parsed family (vendor + base name, version
   preserved). For instruments whose plugin fails to load (so the live API
   exposes no path or name) the original identity is recovered from the
   song's `Song.xml` (see *Missing / broken plugins* below), so they can
   still be matched.
2. **Candidate matching.** Builds a lookup from Renoise's own resolved
   installed-plugin lists (`track.available_device_infos` and
   `instrument.plugin_properties.available_plugin_infos`). Groups by family
   (the version is kept, so Pro-Q 2 ≠ Pro-Q 3) and ranks by **CLAP > VST3 >
   VST > AU** and by version. Cross-format / cross-branding upgrades are
   allowed (e.g. an AU `FabFilter FF Pro-MB` can be replaced by a VST3
   `FabFilter Pro-MB`) as long as the base name and vendor match.
3. **Swap + state transfer (per device, pcall-guarded).** For each chosen
   device it inserts the new plugin at the same position, then transfers
   the old state: (a) if the replacement is the same product at the same
   version, transplant the old `active_preset_data` directly; across the
   VST2 ↔ VST3 boundary the engine state is moved into/out of the VST3
   `.vstpreset` container instead (so a Massive VST → VST3 upgrade keeps
   its patch); (b) otherwise — a different protocol, or a product/version
   change such as `Kick` → `Kick 2` even when both are VST — load a
   same-named factory preset as a base and overlay the old plugin's
   captured parameter values (matched by name); (c) if no transfer method
   succeeds, keep the new plugin at default state — strictly better than a
   missing plugin. The device enabled/bypass flag is preserved.
      - **Instrument parameters transfer too.** Renoise documents
        `is_automatable` as invalid for instrument devices, so instrument
        parameters are captured and re-applied directly rather than being
        filtered by it. Names are matched exactly first, then ignoring
        case, spacing and punctuation, which tolerates the renames a
        VST2 → VST3 port often introduces.
      - **Automation is preserved.** Plugin automation (track-device and
        instrument) is carried across the replacement, matched by parameter
        name: track devices rebind their live automation objects onto the new
        device, and instrument plugins rebuild it from the captured point data.
        All of this is best-effort and fully `pcall`-guarded, so a failure
        never aborts the upgrade.
  - **Reaktor ensembles use a bundled donor + a MIDI loopback.** Reaktor keeps
    its whole patch (ensemble + snapshot) inside the opaque state chunk and
    exposes no usable program bank until that state is loaded, and Reaktor 6
    rejects Reaktor 5's chunk. A known-good Reaktor 6 Razor state is therefore
    bundled into the tool (`lib/up_donor_data.lua`, base64) and injected into
    each upgraded Reaktor instance, but only when the instance is actually
    loaded with the Razor ensemble; an instance holding another ensemble keeps
    its own state instead of being silently rewritten to Razor. That loads the
    ensemble, but Renoise's plugin API can only address the plugin's **first**
    snapshot bank, so the per-instance snapshot is selected over a MIDI loopback
    (see *Reaktor 6 MIDI setup* below): Plup sends Bank Select CCs to move
    Reaktor's bank and lets Renoise choose the program, confirming the hit by the
    snapshot name embedded in the serialized state. A Reaktor upgrade therefore
    needs the loopback: when no loopback port is available the dialog stops
    before swapping anything and offers the one-time setup below, rather than
    silently leaving each instance on a first-bank snapshot. Upgrades that
    involve no Reaktor instance run without the loopback.
  - **Reaktor 6 MIDI setup (one-time).** Bank Select is unreachable from the
    plugin API, so Plup needs a MIDI loopback port:
    1. macOS: open **Audio MIDI Setup → Window → Show MIDI Studio**,
       double-click **IAC Driver** and tick **Device is online** (this creates
       `IAC Driver (Bus 1)`; any loopback port whose name contains `IAC` works).
    2. Renoise: **Edit → Preferences → MIDI**, enable that bus in the **Inputs**
       list.
    3. Run the upgrade. Plup points each upgraded Reaktor instrument's MIDI
       input at the loopback port automatically; nothing else needs wiring.
4. **Per-row UI + live refresh.** Shows a grid with the current plugin, a
   "Replace with" dropdown of candidates (auto-selecting the best upgrade),
   and a result column. The dialog watches the song and re-scans (reusing
   the cached candidate pool) when devices/tracks/instruments change,
   preserving your previous dropdown choices. **It never saves the song** —
   you inspect/undo, and Renoise's own undo stack covers the device swaps.

## Using it

- Open a song, then pick **Tools → Plup** (or the global key
  binding you can assign in the Keyboard preferences). The dialog opens and
  immediately scans, building the candidate list in the background
  ("gathering replacements" — the slow part, run concurrently with the song
  scan so rows appear at once).
- Each row shows the current plugin and a **Replace with** dropdown. By
  default the best candidate is pre-selected; set a row to **"Keep
  current"** to leave that device alone. The current device's active preset
  name is shown when available (for missing plugins it is recovered from
  `Song.xml`).
- Press **Upgrade** to swap the selected devices. While running the button
  becomes **Stop** (the swaps already performed are kept). Nothing is
  written to disk unless you save the song yourself.
- The status line reports progress, and a final summary counts results per
  status (e.g. `upgraded-with-parameters`, `upgraded-name-matched-preset`,
  `upgraded-parameter-synth`, `upgraded-default`, `up-to-date`,
  `skipped-transfer-rejected`, `skipped-no-candidate-broken`).

## Missing / broken plugins

- **Broken *instrument* plugins:** when a plugin fails to load,
   `plugin_device` is `nil`, so the live API exposes no path or name. The
   tool reads the song's own `.xrns` archive (a zip containing `Song.xml`,
   which records every plugin's identity, including missing ones) to recover
    the original display name, then matches and upgrades it. `Song.xml` is
    parsed by the pure-Lua tree parser in `lib/up_xml.lua`, a thin builder over
    the vendored [SLAXML][] engine (`lib/slaxml.lua`, MIT-licensed and committed
    directly into `lib/` because the LuaRocks rockspec is broken).
    `up_songxml.parse_instruments` walks it with `find_all(root,"Instrument")`,
    so `<InstrumentGroup>` nesting and attribute-bearing tags are handled
    structurally, never by fragile string matching. The preset name is recovered
    from the song's `ParameterChunk` (base64 CDATA in `Song.xml`) or the
    instrument name, so the replacement can load that preset from the installed
    plugin's own bank; if no preset matches, it loads at default state.
    Renoise also renames an instrument to `VST: Massive (Acid Raw)` when a
    preset is selected, so that parenthetical label is treated as the preset
    name for healthy and missing plugins alike. It can only be *selected* in a
    replacement that exposes a real program bank (Massive itself does not).
- **Broken *track* devices:** detected when `active_preset_data` raises an
  error; these are listed as broken and matched normally from their
  `device_path`/`name`.
- **Missing-plugin name matching** is best-effort and version-flexible: it
  normalizes names (stripping protocol/category tags, architecture markers,
  and unifying separators) and uses a token-subset comparison, so e.g.
  `Kick - Nicky Romero` can map to `Kick 2`.

## Limitations / things to verify in Renoise

- **Preset-name recovery** parses the old `active_preset_data` XML (live
  plugins) or the song's `ParameterChunk` CDATA in `Song.xml` (missing
  plugins) for a name; this is best-effort and plugin-dependent. Renoise also
  renames an instrument to `VST: Massive (Acid Raw)` when a preset is selected,
  so that parenthetical label is treated as the preset name for healthy and
  missing plugins alike. It can only be *selected* in a replacement that
  exposes a real program bank (Massive itself does not). When a preset name is
  found it is loaded from the replacement's own bank, but if nothing matches,
  state is generally not otherwise transferred for missing plugins.
- **State transplant** is only attempted for the same product and version;
  a same-format but incompatible chunk (e.g. `Kick` → `Kick 2`) is never
  written, so shared parameters still carry over via the overlay above.
  A VST2 ↔ VST3 upgrade of the same product wraps the engine state in the
  replacement's `.vstpreset` container; when the plugin silently ignores
  it (no captured parameter value survives) Plup falls back to the
  preset/parameter overlay instead of reporting an exact transfer.
  Verification accepts a direct transplant unless it raises an error or
  yields an empty state; some plugins re-encode preset data, so always
  sanity-check upgraded devices by ear.
- **Cross-format upgrades** carry state via captured parameter values
  matched by name; parameters the new plugin doesn't expose (or that aren't
  automatable for track effects) are dropped. Instrument parameters are
  always captured because Renoise's `is_automatable` flag is not valid for
  instrument devices.

## Testing

The pure logic that can be verified without a live Renoise session has a
dependency-free Lua test suite (`tests/run.lua`) and a CI workflow
(`.github/workflows/test.yml`) that installs Lua 5.1 (matching Renoise's
LuaJIT), compile-checks every source file, and runs the suite:

    lua5.1 tests/run.lua

- The suite installs a **strict metatable on `_G`**: reading an *undeclared
  global* (e.g. a bare `utf8`) errors out. Always `require` libraries rather
  than referencing them as bare globals, and run `luacheck lib/*.lua tests/run.lua`
  (LibDeflate is vendored and excluded) to keep the lint clean.

It covers plugin-name analysis, candidate matching (exact and
version/name-flexible — including `Kick - Nicky Romero` → `Kick 2`,
`Reaktor5` → `Reaktor6`, and `FabFilter FF Pro MB` → `FabFilter Pro-MB`),
preset-name extraction, `Song.xml` recovery (against a zipped fixture), and
the inventory scan wired to a mocked song. Swap/state-transfer behavior
that needs the Renoise runtime is still verified manually per the checklist
below.

## Installation

This folder *is* the tool bundle (named after the tool id,
`org.bitbear.Plup.xrnx`).

- **Easy:** drag the `org.bitbear.Plup.xrnx` folder into Renoise's
  Tools directory, then restart Renoise (or use *Renoise → Help → Show
  Preferences → Plugins* to locate the folder). Renoise auto-detects tool
  folders.
- **As a package:** zip the folder's contents into
  `org.bitbear.Plup.xrnx` (the `.xrnx` extension *is* a zip) and
  install it from Renoise's *Tools → Install* browser, or double-click it.

After install you'll find **Tools → Plup** in the main menu (and
a global key binding you can assign in the Keyboard preferences).

## Testing checklist (needs a live Renoise session)

- On a scratch song, include one plugin known to reject cross-version state
  (e.g. FabFilter Saturn 1 → 2) and one that accepts it, and confirm the
  pcall-guarded fallback chain behaves (direct transplant, then
  preset+param overlay, then default-state upgrade).
- Test against a **copy** of a real project (never the original) to confirm
  broken track devices are visible and repairable, that up-to-date devices
  are reported as `skipped-up-to-date`, and that a missing instrument is
  recovered from `Song.xml` and upgraded.

[lint-badge]: https://github.com/asbjornu/org.bitbear.Plup.xrnx/actions/workflows/lint.yml/badge.svg
[codecov-badge]: https://codecov.io/gh/asbjornu/org.bitbear.Plup.xrnx/branch/main/graph/badge.svg
[codecov]: https://codecov.io/gh/asbjornu/org.bitbear.Plup.xrnx
[license-badge]: https://img.shields.io/github/license/asbjornu/org.bitbear.Plup.xrnx
[lua-badge]: https://img.shields.io/badge/Lua-5.1%20%2F%20LuaJIT-blue
[renoise-api-badge]: https://img.shields.io/badge/Renoise%20API-6-blue
[renoise]: https://www.renoise.com/
[SLAXML]: https://github.com/Phrogz/SLAXML
[tests-badge]: https://github.com/asbjornu/org.bitbear.Plup.xrnx/actions/workflows/test.yml/badge.svg
