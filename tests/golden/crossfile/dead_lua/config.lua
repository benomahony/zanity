local actions = require("actions")

local keys = { ["<c-x>"] = { "mark_delete", mode = "n" } }
local source = { format = "git_branch" }

local function announce()
  print("forgotten_action")
end

return { keys = keys, source = source, pick = actions["definitions"], announce = announce }
