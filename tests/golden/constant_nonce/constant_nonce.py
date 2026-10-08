from Crypto.Cipher import AES

fixed = AES.new(key, AES.MODE_GCM, nonce=b"fixed-nonce1")
runtime = AES.new(key, AES.MODE_GCM, nonce=nonce)
