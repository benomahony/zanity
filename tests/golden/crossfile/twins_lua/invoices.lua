local M = {}

function M.sum_invoices(invoices, tax)
  local result = 0
  for _, invoice in ipairs(invoices) do
    if invoice.settled then
      result = result + invoice.value * tax
    end
  end
  return round(result, 2)
end

function M.different(items)
  local count = #items
  print(count, items[1].name)
  return items
end

return M
