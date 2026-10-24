test("reaches real resources", () => {
    sleep(1); // parity: sleep-in-test
    while (ready()) { // parity: polling-loop
        sleep(1); // parity: sleep-in-test
    }
    Math.random(); // parity: nondeterministic-test
    fs.readFileSync("config"); // parity: filesystem-in-test
    fetch("https://example.com"); // parity: network-in-test
    child_process.spawn("ls"); // parity: process-in-test
    prompt("input"); // parity: stdin-in-test
});
function helper() { sleep(1); fs.readFileSync("config"); }
