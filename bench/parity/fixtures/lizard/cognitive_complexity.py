def score(rows: list[list[int]]) -> int:
    total = 0
    for row in rows:
        for value in row:
            if value > 0:
                if value % 2 == 0:
                    if value > 100:
                        total += value
                elif value % 3 == 0:
                    total -= value
            elif value < -10 and value % 7 == 0:
                total += 1
    return total
