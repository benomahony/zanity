def deepest(rows: list[list[list[list[int]]]]) -> int:
    found = 0
    for block in rows:
        for row in block:
            for cell in row:
                for value in cell:
                    if value > 0:
                        if value % 2 == 0:
                            if value % 3 == 0:
                                if value % 5 == 0:
                                    found += value
    return found
