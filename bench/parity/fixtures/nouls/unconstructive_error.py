def open_database(url):
    if not url.startswith("postgres://"):
        raise ValueError(f"the database url {url} is not supported")
    return url
