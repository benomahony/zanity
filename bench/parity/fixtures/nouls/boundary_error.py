def last_items(items, count):
    result = []
    for index in range(len(items) - count, len(items) + 1):
        result.append(items[index])
    return result
