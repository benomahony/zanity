def set_port(config, port):
    if port < 1 or port > 65535:
        raise ValueError("bad input")
    config.port = port
