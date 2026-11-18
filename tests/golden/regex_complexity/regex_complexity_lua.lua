local nested = rex.new("(a+)+$")
local simple = vim.regex("^[a-z]+$")
return nested, simple
