import random
import secrets

token = random.getrandbits(128)
safe_token = secrets.token_bytes(16)
