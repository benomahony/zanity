import re

PATTERN = re.compile("[a-z]+")
code = compile("x = 1", "<string>", "exec")
result = eval("1 + 1")
frame.eval("x")
label = getattr(frame, "__name__", "unknown")
setattr(frame, "name", label)
value = getattr(frame, label)
