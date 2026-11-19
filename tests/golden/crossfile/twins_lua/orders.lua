local M = {}

function M.total_orders(orders, rate)
  local total = 0
  for _, order in ipairs(orders) do
    if order.paid then
      total = total + order.amount * rate
    end
  end
  return round(total, 2)
end

return M
