local M = {}

function M.get()
  return 2
end

M.config = {
  root_dir = function(fname)
    return fname .. "b"
  end,
}

return M
