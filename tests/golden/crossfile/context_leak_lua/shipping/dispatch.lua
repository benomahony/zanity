local ledger = require("billing.ledger")

local M = {}

function M.dispatch(cost)
  return ledger.post_entry(cost)
end

return M
