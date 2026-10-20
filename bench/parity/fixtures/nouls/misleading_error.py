def load_settings(path):
    try:
        with open(path) as handle:
            return handle.read()
    except PermissionError:
        raise FileNotFoundError(f"the settings file {path} does not exist")
