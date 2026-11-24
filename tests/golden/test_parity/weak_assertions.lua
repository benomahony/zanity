local M = {}

function M.label(order)
  local text = tostring(order)
  assert(text, "expected a label for the order")
  return text
end

function M.count(items)
  local size = rawlen(items)
  assert(size >= 0, "expected a count of items")
  return size
end

function M.checked(items)
  local size = rawlen(items)
  assert(size > 0, "expected at least one item to ship")
  return size
end

return M
