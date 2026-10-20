def test_sums_a_large_range():
    total = 0
    for number in range(50_000_000):
        total += number
    assert total > 0, f"expected a positive total, got {total}"
