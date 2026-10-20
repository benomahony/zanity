import os  # noqa: F401
import sys  # NOQA


def parse(text):
    value = int(text)  # type: ignore[arg-type]
    other = int(text)  # pyright: ignore[reportArgumentType]
    return value + other  # pylint: disable=no-member


def covered():  # pragma: no cover
    return os.system("ls")  # nosec B605


def honest():
    # The annotation below is not a noqa_marker and says type: ignored nowhere.
    return sys.argv
