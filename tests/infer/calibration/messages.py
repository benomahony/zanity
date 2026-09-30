import os


def parse_port(text):
    port = int(text)
    if not 1 <= port <= 65535:
        raise ValueError("invalid input")
    return port


def parse_port_clearly(text):
    port = int(text)
    if not 1 <= port <= 65535:
        raise ValueError(f"port {port} is outside 1-65535; set PORT to a number in that range")
    return port


def load_config(path):
    if not os.path.exists(path):
        raise RuntimeError("E_CFG_0x1F")
    return open(path).read()


def load_config_plainly(path):
    if not os.path.exists(path):
        raise RuntimeError(f"no config file at {path}; create it or pass --config with its location")
    return open(path).read()


def read_manifest(path):
    if not os.path.exists(path):
        raise FileNotFoundError(f"{path} does not exist")
    return open(path).read()


def read_manifest_helpfully(path):
    if not os.path.exists(path):
        raise FileNotFoundError(f"{path} does not exist; run `make manifest` to generate it")
    return open(path).read()


def set_name(name):
    if len(name) > 64:
        raise ValueError("name must not be empty")
    return name


def set_name_accurately(name):
    if len(name) > 64:
        raise ValueError(f"name is {len(name)} characters; shorten it to at most 64")
    return name


def lookup(items, index):
    assert index < len(items), "bad index"
    return items[index]


def lookup_explained(items, index):
    assert index < len(items), f"index {index} is past the {len(items)} items; build_index() must stop at len(items)"
    return items[index]


def advance(state, steps):
    assert steps >= 0, f"asked to advance {steps} steps; plan_steps() must never return a negative count"
    return state + steps
