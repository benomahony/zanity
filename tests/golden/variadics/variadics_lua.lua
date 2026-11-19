local M = {}

function M.log_all(...)
  return select("#", ...)
end

function M.total(prices)
  return #prices
end

function M.wrap(f)
  return function(...)
    return f(...)
  end
end

function M.find(items, wanted)
  for _, item in ipairs(items) do
    if item == wanted then
      goto found
    end
  end
  do return nil end
  ::found::
  return wanted
end

return M
