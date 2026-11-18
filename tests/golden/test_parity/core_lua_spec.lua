it("reaches real resources", function()
    socket.sleep(1) -- parity: sleep-in-test
    while ready() do -- parity: polling-loop
        socket.sleep(1) -- parity: sleep-in-test
    end
    math.random() -- parity: nondeterministic-test
    io.open("config") -- parity: filesystem-in-test
    http.request("https://example.com") -- parity: network-in-test
    os.execute("ls") -- parity: process-in-test
    io.read() -- parity: stdin-in-test
end)

local function helper()
    socket.sleep(1)
    io.open("config")
end
