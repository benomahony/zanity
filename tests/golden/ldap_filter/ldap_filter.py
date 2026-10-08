def query(directory, base, filter_text):
    return directory.search_s(base, 2, filter_text)


def fixed(directory, base, filter_text):
    return directory.search_s(base, 2, "(uid=service)")


def local_filter(directory, base):
    filter_text = "(uid=service)"
    return directory.search_s(base, 2, filter_text)
