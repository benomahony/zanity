def reserve(size):
    return bytearray(size)


def fixed(size):
    return bytearray(4096)


def bounded(size):
    bounded_size = min(size, 4096)
    return bytearray(bounded_size)
