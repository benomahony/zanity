def derive(password):
    return hashlib.pbkdf2_hmac("sha256", password, b"shared-salt", 200_000)


def derive_unique(password, salt):
    return hashlib.pbkdf2_hmac("sha256", password, salt, 200_000)


def literal_password(dynamic_salt):
    return bcrypt.hashpw(b"fixed test password", dynamic_salt)
