local M = {}

function M.ship(order)
  local city = order.customer.address.city
  local name = order.customer.name
  return city, name
end

function M:total()
  self.order.customer.address:notify()
  return self.order.lines.count
end

return M
