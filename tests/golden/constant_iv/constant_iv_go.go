package main

import "crypto/cipher"

func encrypt(block cipher.Block, iv []byte) {
	_ = cipher.NewCBCEncrypter(block, []byte("0123456789abcdef"))
	_ = cipher.NewCBCEncrypter(block, iv)
}
