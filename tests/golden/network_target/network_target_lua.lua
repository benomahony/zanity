local M = {}

function M.fetch(url)
  return http.request(url)
end

function M.fetch_health(url)
  return http.request("https://health.example.invalid")
end

return M
