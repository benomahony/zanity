local M = {}

function M.release(handle, meta)
  meta.__gc(handle)
end

function M.close(handle)
  handle:close()
end

return M
