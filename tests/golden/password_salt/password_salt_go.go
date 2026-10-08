package main

func derive(password []byte) []byte {
	return pbkdf2.Key(password, []byte("shared-salt"), 200_000, 32, sha256.New)
}

func deriveUnique(password, salt []byte) []byte {
	return pbkdf2.Key(password, salt, 200_000, 32, sha256.New)
}

func literalPassword(dynamicSalt []byte) []byte {
	return pbkdf2.Key([]byte("fixed test password"), dynamicSalt, 200_000, 32, sha256.New)
}
