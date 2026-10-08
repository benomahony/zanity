from cryptography.hazmat.primitives.ciphers import modes

fixed = modes.CBC(b"0123456789abcdef")
runtime = modes.CBC(iv)
