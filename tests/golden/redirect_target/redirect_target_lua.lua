local M = {}

function M.back(target)
  return ngx.redirect(target)
end

function M.home()
  return ngx.redirect("/")
end

return M
