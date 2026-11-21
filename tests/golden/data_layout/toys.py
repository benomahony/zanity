import re
import timeit
from dataclasses import dataclass


@dataclass
class Customer:
    balance: float


@dataclass
class Row:
    customer: Customer


ROWS = [Row(Customer(float(i))) for i in range(200_000)]
BALANCES = [row.customer.balance for row in ROWS]
LINES = ["the quick brown fox" if i % 7 == 0 else "jumps over the lazy dog" for i in range(200_000)]


def chained(rows: list[Row]) -> float:
    total = 0.0
    for row in rows:
        total += row.customer.balance
    return total


def parallel(balances: list[float]) -> float:
    total = 0.0
    for balance in balances:
        total += balance
    return total


def compile_each_pass(lines: list[str], pattern: str) -> int:
    found = 0
    for line in lines:
        if re.compile(pattern).search(line):
            found += 1
    return found


def compile_once(lines: list[str], pattern: str) -> int:
    compiled = re.compile(pattern)
    found = 0
    for line in lines:
        if compiled.search(line):
            found += 1
    return found


def lower_each_pass(lines: list[str], word: str) -> int:
    found = 0
    for line in lines:
        if word.lower() in line:
            found += 1
    return found


def lower_once(lines: list[str], word: str) -> int:
    wanted = word.lower()
    found = 0
    for line in lines:
        if wanted in line:
            found += 1
    return found


def fastest(call) -> float:
    return min(timeit.repeat(call, number=1, repeat=5)) * 1000


def report(rule: str, before, after) -> None:
    slow, fast = fastest(before), fastest(after)
    print(f"{rule:<36} {slow:>9.2f} ms {fast:>9.2f} ms {slow / fast:>7.2f}x")


print(f"{'rule (python, 200k)':<36} {'before':>12} {'after':>12} {'speedup':>8}")
report("field-chain-in-loop", lambda: chained(ROWS), lambda: parallel(BALANCES))
report("invariant-in-loop: re.compile", lambda: compile_each_pass(LINES, "fox"), lambda: compile_once(LINES, "fox"))
report("invariant-in-loop: word.lower()", lambda: lower_each_pass(LINES, "FOX"), lambda: lower_once(LINES, "FOX"))
