local function ship(orders)
  for _, order in ipairs(orders) do
    order:ship()
  end
end

local function totals(orders)
  local out = 0
  for _, order in ipairs(orders) do
    out = out + order.customer.balance
  end
  return out
end

return { ship = ship, totals = totals }
