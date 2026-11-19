pending("case")

pending("with a body", function() end)

it("on", function()
  assert.are.equal(1, 1)
end)

function TestSkips:test_off()
  lu.skip("broken")
end

function TestSkips:test_skipped_when_needed()
  if package.config:sub(1, 1) == "\\" then
    lu.skip("posix only")
  end
  lu.assertEquals(1, 1)
end

function TestSkips:test_conditional()
  lu.skipIf(package.config:sub(1, 1) == "\\", "posix only")
  lu.assertEquals(1, 1)
end
