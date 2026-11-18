local M = {}

function M.total(prices, currency, rounding)
  local result = sum(prices)
  return round(result, rounding)
end

function M.stub(value, other) end

function M.uses_all(a, b)
  local first = a + 1
  return first * b
end

function M:area(scale, _unused)
  local width = 2
  return width * scale
end

local mt = {
  __index = function(t, key)
    return rawget(t, "default")
  end,
}

function M.outer(factor)
  local function inner(x)
    return x * factor
  end
  return inner
end

return M, mt
