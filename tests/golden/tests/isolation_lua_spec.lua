it("reaches out", function()
  _G.MODE = "test"
  package.path = "./?.lua;" .. package.path
  lfs.chdir("/tmp")
  io.open("config.json")
  os.tmpname()
  http.request("https://example.com")
  sqlite3.open("app.db")
  sqlite3.open(":memory:")
  io.popen("ls")
end)

it("works in neovim's temporary directory", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/bin", "p")
  io.open(dir .. "/bin/python", "w")
end)

local function helper()
  _G.MODE = "prod"
  io.popen("ls")
end
