local billing = require("billing")

local M = {}

function M.place(order)
  billing.charge(order.total)
end

function M.cancel(order)
  billing.refund(order.total)
end

return M
