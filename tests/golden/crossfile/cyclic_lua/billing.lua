local orders = require("orders")

local M = {}

function M.charge(amount)
  return amount
end

function M.refund(amount)
  return -amount
end

function M.rebill(order)
  orders.place(order)
end

return M
