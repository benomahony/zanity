local ledger = require("billing.ledger")

local M = {}

function M.post(amount)
  return ledger.post_entry(amount)
end

return M
