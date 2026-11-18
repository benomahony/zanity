local pong = require("pong").pong

local M = {}

function M.ping(n)
  return pong(n - 1)
end

function M.countdown(n)
  return other.countdown(n)
end

return M
