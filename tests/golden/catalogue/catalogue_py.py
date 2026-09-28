import pdb


def flagged(x, items):
    if x:
        pass
    for _ in items:
        pass
    if True:
        x = 1
    while False:
        x = 2
    x == 1.5
    try:
        x = items[0]
    except Exception:
        x = None
    try:
        x = items[1]
    except:
        x = None
    db_password = "hunter2"
    breakpoint()
    pdb.set_trace()
    return x
    x = 3


def quiet(x, items):
    if x:
        # nothing to do until the cache is warm
        pass
    if x == 0.0:
        x = 1
    y = x == 1.5
    try:
        x = items[0]
    except (KeyError, IndexError):
        x = None
    password_env = "DB_PASSWORD"
    token_type = "Bearer"
    empty_secret = ""
    return x, y


def stub():
    pass
