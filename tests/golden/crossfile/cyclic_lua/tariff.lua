local total = require("invoice").total

local M = {}

function M.base(amount)
  return amount
end

function M.surcharge(amount)
  return amount // 10
end

function M.quote(amount)
  return total(amount)
end

return M
