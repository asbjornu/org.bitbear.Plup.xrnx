package = "plup-dev"
version = "0.0.1-1"
source = {
   url = "https://github.com/asbjornu/org.bitbear.Plup.xrnx",
}
description = {
   summary = "Dev dependencies for the Plup Renoise tool",
   license = "MIT",
}
dependencies = {
   "luacov 0.17.0-1",
   "luacov-reporter-lcov 0.2-0",
   -- The runtime XML parser (SLAXML) is vendored into lib/slaxml.lua rather than
   -- pulled from LuaRocks: the slaxml rockspec points at a git tag that no longer
   -- exists upstream, so `luarocks install slaxml` fails. Being pure Lua, the
   -- vendored copy loads fine in Renoise's sandbox and in the test harness.}
build = {
   type = "none",
}
