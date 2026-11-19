local M = {}

function M.get()
  return 1
end

M.config = {
  root_dir = function(fname)
    return fname .. "a"
  end,
}

return M
