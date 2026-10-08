def load(name, handle, path, description):
    return imp.load_module(name, handle, path, description)


def load_supported(name):
    return importlib.import_module(name)


def unrelated(loader, name):
    return loader.load_module(name)
