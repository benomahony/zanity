local unused = require("unused") -- luacheck: ignore

local function parse(text)
  ---@diagnostic disable-next-line: param-type-mismatch
  local value = tonumber(text, 10)
  return value -- selene: allow(shadowing)
end

local function honest()
  -- The comment below names luacheck without turning any check off.
  return parse(arg[1])
end

return honest
