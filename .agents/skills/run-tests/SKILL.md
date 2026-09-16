---
name: run-tests
description: Run the Renoise Plup Lua test suite and keep it green
---
Run `lua tests/run.lua` (Homebrew `lua` at `/usr/local/bin`; do `export PATH=/usr/local/bin:$PATH` first).

- All tests must print `ALL TESTS PASSED`.
- `luacheck . --exclude-files '.luarocks' --exclude-files 'lib/LibDeflate.lua' --exclude-files 'lib/slaxml.lua'` must report 0 warnings (the CI command; it also lints `tests/spec/*.lua`).
- A spec that reads or stubs a global must declare it in `.luacheckrc` under `files["tests/**"]` (`read_globals` if only read; `globals` if its fields are assigned), or CI fails.
- The harness sets a **strict metatable on `_G`**: any *undeclared global read* errors. Capture libs via `require`; never reference bare globals like `utf8`.
