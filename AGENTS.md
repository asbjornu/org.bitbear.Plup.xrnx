# AGENTS.md — org.bitbear.Plup

Renoise Lua tool that inventories outdated/broken plugins and upgrades
them.

## Environment

- Lua 5.4/5.5 (Renoise embedded). **Pure-Lua only — no external or C
  modules.** Vendor pure-Lua if a dependency is needed (xml2lua/LuaExpat
  won't load in the sandbox).
- Run the suite with `lua tests/run.lua` (Homebrew `lua` at
  `/usr/local/bin`; `export PATH=/usr/local/bin:$PATH`). CI uses `lua5.1`.
- The test harness installs a **strict metatable on `_G`**: reading an
  *undeclared global* errors. Always `require` libs; never read bare
  globals like `utf8` — capture via `pcall(require,"utf8")`.
- Lua patterns here have **no `|` alternation**; use character classes
  (`[%s>]`).

## Workflow

- **Do all work in a separate development worktree, never in the Renoise
  install directory.** Create a worktree on a new branch from the branch you
  are changing (e.g. `git worktree add ../org.bitbear.Plup.fix -b
  fix/<name> renoise/3.5.4`), make the edits, run the suite and lint, and
  commit there.
- **`renoise/3.5.4` is the deployment mirror** checked out at the Renoise
  install path
  (`/Users/bitbear/Library/Preferences/Renoise/V3.5.4/Scripts/Tools/org.bitbear.Plup.xrnx`).
  Treat it like a separate remote: synchronize it only after the development
  worktree is green, by fast-forwarding it to the worktree's commit (e.g.
  `git -C <install-path> merge --ff-only <sha>`) or pushing to it. Never
  create, amend or edit commits in the install worktree itself.
- **Before any edit or commit, verify the location.** Run
  `git branch --show-current` and confirm it is the development branch (not
  `main` and not `renoise/3.5.4`), and run `git rev-parse --show-toplevel`
  and confirm it is the development worktree — it must **not** equal the
  Renoise install path above.
- The `main` checkout under `/Users/bitbear/Dev/...` is the canonical repo
  mirror only — never edit files or create commits directly on `main`.
  Update it only by fast-forwarding or merging the development branch.
- Never change existing branches to point to a worktree. If you need a
  worktree, create a new branch.
- `main` should always point to the canonical repository location, not the
  installation path of the tool or any other worktree directory.
- Commit before considering the task done.
- Group commits logically by feature or fix.
- If the a fix applies to code added previously in the same branch,
  squash the fix into the original commit.
- Add tests for all new features to ensure correctness and high coverage.
- Commit messages: terse, no "the user" references. Keep the header at
  maximum 50 characters, repeat it in the body if truncation is necessary.
  Wrap the body at 72 characters.
- Commit with signature (`git commit -S`). `gpg` is installed with Homebrew.
- When addressing PR review comments, reply on each thread and then resolve
  the thread and hide/minimize the addressed comment (GitHub
  `resolveReviewThread` and `minimizeComment`). Leave threads you did not
  address open for a human.
- Keep `luacheck` clean with the **same command as CI**, which lints every
  file (not just `lib/*.lua tests/run.lua`): `luacheck . --exclude-files
  '.luarocks' --exclude-files 'lib/LibDeflate.lua' --exclude-files
  'lib/slaxml.lua'`.
- When a spec reads or monkey-patches a global, declare it in `.luacheckrc`
  under `files["tests/**"]`: modules that are only read go in
  `read_globals`; modules whose fields a spec assigns (`up_zip`,
  `up_song_xml`, `up_donor`, `up_midi`) plus `renoise` go in `globals`
  (read-write), or CI fails with "setting read-only field".

## PR fixer

`.github/workflows/pr-fix-orchestrator.yml` dispatches `pr-fix` when a new
Copilot review lands on a same-repo PR by `PR_FIX_AUTHOR`. Failed runs are
reported on the PR they were dispatched for. The agent fixes the findings,
replies on the threads, and resolves and hides the ones it fixed.

`pr-fix-squash.yml` is stateless: on `synchronize` it folds every `fixup!`
commit in `merge-base..HEAD` with
`git rebase -i --autosquash --rebase-merges` and pushes with
`--force-with-lease`. With no `fixup!` present it is a no-op. A
fixer-managed branch may need a reset after the squash re-SHAs commits.

## Layout

- `main.lua` entry → loads `up_ui`; `lib/up_*.lua` are modules;
  `tests/run.lua` is the headless suite (mocked Renoise).
- Flow: `up_inventory` scans the song → `up_matching` finds candidates →
  `up_swap` swaps + transfers state → `up_core` orchestrates → `up_ui`
  dialog.
- `up_songxml` + `up_xml` parse `Song.xml` (the `.xrns` is a zip, read by
  `up_zip`). `up_preset` decodes preset/ensemble names from opaque chunk
  data (with a base64 "looks-like-binary" guard). `up_util` holds
  name/token analysis.

## XML parsing

- `lib/up_xml.lua` is a thin **pure-Lua tree builder over the vendored SLAXML
  engine** (`lib/slaxml.lua`, MIT, committed directly into `lib/` because the
  LuaRocks rockspec is broken). `up_songxml.parse_instruments` uses
  `find_all(root,"Instrument")` so `<InstrumentGroup>` nesting and
  attribute-bearing tags are handled structurally.
