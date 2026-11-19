local helpers = require("helpers")

it("doubles the number", function()
  assert.are.equal(4, helpers.used_helper(2))
end)
