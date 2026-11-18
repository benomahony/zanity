local M = {}

function M.read(path)
  return io.open(path)
end

function M.read_config()
  return io.open("config.lua")
end

return M
