import asyncio
import hashlib
import logging
import os
import pickle
import time


async def fetch(url):
    await asyncio.sleep(1)


async def flagged(cursor, name, api_token, data, requests, x):
    try:
        fetch("a")
    finally:
        return 1
    if x is "a":
        x = 1
    raise Exception("boom")
    x
    requests.get(name, verify=False)
    match x:
        case 1:
            x = 2
    hashlib.md5(data)
    pickle.loads(data)
    os.system("ls " + name)
    cursor.execute(f"SELECT * FROM users WHERE name = '{name}'")
    elapsed = time.time() - x
    logging.info("using %s", api_token)
    asyncio.sleep(1)
    if x:
        for y in data:
            if y:
                while y:
                    if y > 1:
                        y -= 1


async def quiet(cursor, name, token, data, x):
    try:
        await fetch("b")
    finally:
        logging.info("done")
    if x == "a":
        x = 1
    raise ValueError("name must not be empty; pass --name")
    match x:
        case 1:
            x = 2
        case _:
            x = 3
    hashlib.sha256(data)
    os.system("ls")
    cursor.execute("SELECT * FROM users WHERE name = %s", (name,))
    start = time.monotonic()
    logging.info("parsed token %s", token)
    await fetch("c")


def classify(n):
    if n == 0:
        return 0
    elif n == 1:
        return 1
    elif n == 2:
        return 2
    elif n == 3:
        return 3
    elif n == 4:
        return 4
    elif n == 5:
        return 5
    elif n == 6:
        return 6
    elif n == 7:
        return 7
    elif n == 8:
        return 8
    elif n == 9:
        return 9
    elif n == 10:
        return 10
    elif n == 11:
        return 11
    elif n == 12:
        return 12
    elif n == 13:
        return 13
    elif n == 14:
        return 14
    elif n == 15:
        return 15
    return -1
