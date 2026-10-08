import re

dangerous = re.compile(r"([a-z]+)+$")
safe = re.compile(r"(?:ab+)+$")
