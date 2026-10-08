package main

func encrypt(key *rsa.PublicKey, message []byte) {
	_, _ = rsa.EncryptPKCS1v15(rand.Reader, key, message)
}

func encryptOAEP(key *rsa.PublicKey, message []byte) {
	_, _ = rsa.EncryptOAEP(sha256.New(), rand.Reader, key, message, nil)
}

func unrelated(rsaFactory Factory, message []byte) {
	rsaFactory.EncryptPKCS1v15(message)
}
