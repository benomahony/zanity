local ping = require("ping").ping

local M = {}

function M.pong(n)
  return ping(n)
end

local Tree = {}

function Tree:walk()
  return self:walk()
end

function Tree:visit(node)
  return node:visit()
end

M.Tree = Tree

return M
