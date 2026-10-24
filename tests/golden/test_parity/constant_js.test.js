test("rejects constant checks", () => {
    expect(true).toBeTruthy(); // parity: constant
    expect(1 + 1).toBe(2); // parity: constant
    assert.strictEqual("abc", "abc"); // parity: constant
    const actual = calculate();
    expect(actual).toBe(2);
    expect(2).toBe(actual);
    expect(calculate()).toBe(2);
    if (unexpected()) { assert(false); }
    expect(`${actual}`).toBe("2");
});
function helper() { expect(2).toBe(2); }
