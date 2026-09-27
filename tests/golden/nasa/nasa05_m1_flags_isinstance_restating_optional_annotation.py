
from pathlib import Path
def f(path: Path | None) -> None:
    assert isinstance(path, Path), "path must be a Path"
