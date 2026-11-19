local M = {}

function M.price_report(items, rate)
  local total = 0
  for _, item in ipairs(items) do
    total = total + item:get("price", 0) * rate
    if item:get("price", 0) > 100 then
      print("expensive", item:get("price", 0))
    end
  end
  return total
end

function M.drain(stack)
  local first = table.remove(stack)
  local second = table.remove(stack)
  local third = table.remove(stack)
  return first, second, third
end

function M.parse(reader)
  local first = reader.bytes[reader.at]
  reader.at = reader.at + 1
  local second = reader.bytes[reader.at]
  reader.at = reader.at + 1
  local third = reader.bytes[reader.at]
  return first, second, third
end

return M
