def test_reaches_real_resources():
    time.sleep(1)  # parity: sleep-in-test
    while ready():  # parity: polling-loop
        time.sleep(1)  # parity: sleep-in-test
    random.random()  # parity: nondeterministic-test
    open("config")  # parity: filesystem-in-test
    requests.get("https://example.com")  # parity: network-in-test
    subprocess.run(["ls"])  # parity: process-in-test
    input()  # parity: stdin-in-test

def helper():
    time.sleep(1)
    open("config")
