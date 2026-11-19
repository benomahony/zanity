local M = {}

function M.show(format, value)
  return string.format(format, value)
end

function M.show_fixed(value)
  return string.format("%d items", value)
end

return M
