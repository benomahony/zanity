import re


def matches(lines, pattern):
    found = 0
    for line in lines:
        if re.compile(pattern).match(line):
            found += 1
    return found


def widths(rows, limit):
    out = 0
    for row in rows:
        out += min(len(row), limit)
        limit = limit - 1
    return out


def pairs(tools, old):
    out = {}
    for rule, targets in tools.items():
        fired, answered = old[rule], targets
        out[rule] = len(fired) + len(answered)
    return out


def stripped(rules):
    return [", ".join(name.strip() for name in rule.split(",")) for rule in rules]
