local M = {}

function M.used_helper(n)
  return n * 2
end

function M.old_helper(n)
  return n * 3
end

function M._internal(n)
  return n * 4
end

return M
