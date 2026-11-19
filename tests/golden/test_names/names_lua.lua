local M = {}

function M.test_args(x)
  return x
end

M.test_set = function(path)
  return path
end

TestAccount = {}

function TestAccount:test_x()
  return M.test_args(1)
end

function test_parse()
  return M.test_set("/")
end

return M
