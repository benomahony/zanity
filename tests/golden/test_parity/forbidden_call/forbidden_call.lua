local M = {}

function M.run(code)
  return load(code)()
end

function M.parse(text)
  return tonumber(text)
end

return M
