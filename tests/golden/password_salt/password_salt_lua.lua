local aes = require("resty.aes")

local M = {}

function M.fixed(key)
  return aes:new(key, "constant")
end

function M.random(key, salt)
  return aes:new(key, salt)
end

return M
