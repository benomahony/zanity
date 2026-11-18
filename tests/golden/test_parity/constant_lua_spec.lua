it("rejects constant checks", function()
    assert.is_true(true) -- parity: constant
    assert.are.equal(2, 1 + 1) -- parity: constant
    assert.are.same("abc", "abc") -- parity: constant
    local actual = calculate()
    assert.are.equal(2, actual)
    assert.are.equal(actual, 2)
    assert.are.equal(2, calculate())
    if unexpected() then
        assert.is_true(false)
    end
    assert.are.equal("2", tostring(actual))
end)

function TestFrameworkChecks:test_constants()
    lu.assertTrue(true) -- parity: constant
    lu.assertEquals(2, 1 + 1) -- parity: constant
    lu.assertEquals(2, calculate())
    lu.assertEquals(calculate(), 2)
end

local function helper()
    assert.are.equal(2, 2)
end
