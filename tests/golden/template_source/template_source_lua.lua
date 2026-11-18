local template = require("resty.template")

local M = {}

function M.render_user(source, context)
  return template.compile(source)(context)
end

function M.render_page(context)
  return template.compile("page.html")(context)
end

return M
