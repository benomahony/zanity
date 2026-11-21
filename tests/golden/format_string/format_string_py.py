import logging


def formatter(fmt):
    return logging.Formatter(fmt)


def fixed():
    return logging.Formatter("%(levelname)s %(message)s")
