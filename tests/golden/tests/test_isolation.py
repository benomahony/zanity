import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile

import requests

counter = 0


def test_reaches_out(tmp_path):
    os.environ["MODE"] = "test"
    os.environ.update({"LEVEL": "1"})
    sys.path.append("lib")
    open("config.json")
    shutil.rmtree("build")
    (tmp_path / "out.txt").write_text("ok")
    open(tmp_path / "in.txt")
    tempfile.mkdtemp()
    requests.get("https://example.com")
    sqlite3.connect("app.db")
    sqlite3.connect(":memory:")
    subprocess.run(["ls"])


def test_counts():
    global counter
    counter += 1


def helper():
    os.environ["MODE"] = "prod"
    subprocess.run(["ls"])
