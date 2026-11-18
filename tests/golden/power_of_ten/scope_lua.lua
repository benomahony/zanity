local M = {}

function M.narrow(flag)
  local only_inside = 3
  if flag then
    return only_inside + 1
  end
  return 0
end

function M.direct(flag)
  local value = 3
  if flag then
    return value
  end
  return value + 1
end

function M.looped(items)
  local seen = 0
  for _, item in ipairs(items) do
    seen = seen + item
  end
  return seen
end

function M.closure()
  local captured = 3
  return function()
    return captured
  end
end

function M.effect(flag)
  local started = os.clock()
  if flag then
    return started
  end
  return 0
end

return M
