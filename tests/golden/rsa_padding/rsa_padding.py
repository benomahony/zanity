def encrypt(public_key, message):
    return public_key.encrypt(message, padding.PKCS1v15())


def encrypt_oaep(public_key, message):
    return public_key.encrypt(message, padding.OAEP())


def unrelated_padding(factory):
    return factory.PKCS1v15()
