local M = {}

function M.f(a, b, items)
  assert(a > b, "expected a > b")
  assert(a > 0, "a must be positive")
  assert(#items > 0, string.format("items is empty; pass at least one path, got %d", #items))
  assert(b, "assertion failed")
  if not items then
    error("invalid input")
  end
  if a < 0 then
    error("ERR_NEGATIVE")
  end
  if b == nil then
    error("")
  end
  log.error("Something went wrong")
  error(string.format("cannot open %s: check the path exists and is readable", a))
end

return M
