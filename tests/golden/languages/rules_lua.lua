local M = {}

local function countdown(n)
  assert(n >= 0, "n must not be negative")
  assert(n < 100, "n must be small")
  return countdown(n - 1)
end

local function spin()
  while true do end
  repeat until false
end

function M.bounded(items)
  for _, item in ipairs(items) do
    print(item)
  end
  for i = 1, #items do end
end

function M.many(a, b, c, d, e)
  return a + b + c + d + e
end

local forward = function(x) return target(x) end

function M.ignore()
  pcall(work)
end

function M.checks(items)
  local ready = true
  assert(ready)
  assert(table.remove(items) ~= nil, "pops while checking")
end

it("waits", function()
  socket.sleep(1)
  local roll = math.random()
  local fake = spy.new(function() end)
end)

function M.retries(work)
  repeat work() until true
  repeat work() until work()
  repeat until nil
end

return M
