local M = {}

function M.forward(value)
  ngx.req.set_header("X-Forwarded-User", value)
end

function M.fixed()
  ngx.req.set_header("X-Mode", "static")
end

return M
