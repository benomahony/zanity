local M = {}

function M.report(orders, rate, out)
  local paid = {}
  local unpaid = {}
  for _, o in ipairs(orders) do
    if o.paid then
      table.insert(paid, o)
    else
      table.insert(unpaid, o)
    end
  end
  local total = 0
  for _, order in ipairs(paid) do
    total = total + order.amount * rate
  end
  local lines = {}
  table.insert(lines, "Report")
  table.insert(lines, "======")
  table.insert(lines, "paid: " .. #paid)
  table.insert(lines, "unpaid: " .. #unpaid)
  table.insert(lines, "total: " .. total)
  local header = table.concat(lines, "\n")
  out:write(header)
  out:write("\n")
  local notes = {}
  if total > 1000 then
    table.insert(notes, "large")
  end
  if #unpaid > 0 then
    table.insert(notes, "chase unpaid")
  end
  out:write(table.concat(notes, ", "))
  out:write("line 0\n")
  out:write("line 1\n")
  out:write("line 2\n")
  out:write("line 3\n")
  out:write("line 4\n")
  out:write("line 5\n")
  out:write("line 6\n")
  out:write("line 7\n")
  out:write("line 8\n")
  out:write("line 9\n")
  out:write("line 10\n")
  out:write("line 11\n")
  out:write("line 12\n")
  out:write("line 13\n")
  out:write("line 14\n")
  out:write("line 15\n")
  out:write("line 16\n")
  out:write("line 17\n")
  out:write("line 18\n")
  out:write("line 19\n")
  out:write("line 20\n")
  out:write("line 21\n")
  out:write("line 22\n")
  out:write("line 23\n")
  out:write("line 24\n")
  out:write("line 25\n")
  out:write("line 26\n")
  out:write("line 27\n")
  out:write("line 28\n")
  out:write("line 29\n")
  return total
end

function M.early_exit(orders)
  local count = 0
  for _, order in ipairs(orders) do
    if order.cancelled then
      return -1
    end
    count = count + 1
  end
  return count
end

return M
