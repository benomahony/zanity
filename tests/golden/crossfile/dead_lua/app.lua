local helpers = require("helpers")

local M = {}

local function forgotten()
  return 1
end

local function run()
  return helpers.used_helper(2)
end

M.config = {
  on_attach = function(client)
    return client.id
  end,
}

local mt = {
  __tostring = function()
    return "app"
  end,
}

function M.pick()
  return run()
end

vim.keymap.set("n", "<leader>p", "<cmd>lua require('app').pick()<CR>")

local function from_comment_only()
  return "lua is mentioned in no string that calls this"
end

function M.setup(opts)
  return setmetatable(opts or {}, mt), run()
end

return M
