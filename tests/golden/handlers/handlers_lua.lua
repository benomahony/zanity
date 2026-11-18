local M = {}

function M.handle_error(err) end

function M.handle_request(request) end

function M.on_error(err)
  log.error(err)
end

local ok = xpcall(work, function(err) end)

return M, ok
