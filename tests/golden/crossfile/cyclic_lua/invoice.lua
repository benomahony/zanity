local base = require("tariff").base
local surcharge = require("tariff").surcharge

local M = {}

function M.total(amount)
  return base(amount) + surcharge(amount)
end

return M
