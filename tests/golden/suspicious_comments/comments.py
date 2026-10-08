# FIXME: this accepts expired credentials.
def authenticate(token):
    return token is not None


# Debug output is intentionally disabled; bugfix links belong in the issue tracker.
def quiet():
    return True
