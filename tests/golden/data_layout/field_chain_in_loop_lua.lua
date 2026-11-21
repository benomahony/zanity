local function totals(rows)
  local out = 0
  for _, row in ipairs(rows) do
    out = out + row.customer.balance
  end
  return out
end

local function direct(rows)
  local out = 0
  for _, row in ipairs(rows) do
    out = out + row.balance
  end
  return out
end

return { totals = totals, direct = direct }
