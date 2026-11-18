it("rejects negative amounts", function()
  assert.has_error(function() withdraw(-1) end)
end)

it("rejects unknown accounts", function()
  assert.has_error(function() withdraw_from("nobody", 1) end, "no account")
end)

function TestAccount:test_rejects_overdraft()
  lu.assertError(withdraw, 10 ^ 9)
end

function TestAccount:test_rejects_zero()
  lu.assertErrorMsgContains("must be positive", withdraw, 0)
end
