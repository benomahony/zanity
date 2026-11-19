#!/usr/bin/env lua
-- Requires the --fix output of tests/fix/assertions.lua, the module arg[1] names in the working
-- directory, and calls it so that each assertion holds, then so that each fails, printing "ok"
-- only when every call behaves.
package.path = "./?.lua;" .. package.path
local f = require(arg[1]).f
local held, why = pcall(f, 4, {}, 1)
assert(held, "assertions that hold raised: " .. tostring(why))
for _, case in ipairs({ { 3, {}, 1, "expected n % 2 == 0, got n=3" }, { 4, { true }, 1, "expected t[i % 2] == nil, got t=table" } }) do
  local ok, err = pcall(f, case[1], case[2], case[3])
  assert(not ok, "an assertion that fails passed: " .. case[4])
  assert(string.find(err, case[4], 1, true), "expected the message '" .. case[4] .. "', got '" .. tostring(err) .. "'")
end
print("ok")
