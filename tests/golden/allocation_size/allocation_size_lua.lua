local M = {}

function M.pad(text, width)
  return string.rep(" ", width) .. text
end

function M.reserve(count)
  return table.new(count, 0)
end

function M.indent(text)
  return string.rep(" ", 4) .. text
end

return M
