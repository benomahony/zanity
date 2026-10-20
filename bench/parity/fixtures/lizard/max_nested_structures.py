def first_match(rows: list[list[int]], wanted: int) -> int:
    for row in rows:
        for value in row:
            if value > 0:
                if value == wanted:
                    return value
    return -1
