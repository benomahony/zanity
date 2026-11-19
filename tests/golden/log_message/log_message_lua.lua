local M = {}

function M.report(message)
  ngx.log(message)
end

function M.report_fixed(message)
  print("report sent", #message)
end

return M
