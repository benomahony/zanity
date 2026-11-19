local M = {}

function M.first()
  local late = require("late")
  return late.second()
end

return M
