local function f(n, t, i)
  assert(n % 2 == 0)
  assert(t[i % 2] == nil)
  assert(n, "already explained")
  assert(true)
end

return { f = f }
