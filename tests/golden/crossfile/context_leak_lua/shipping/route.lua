local api = require("billing.api")

local M = {}

function M.route(cost)
  return api.post(cost)
end

return M
