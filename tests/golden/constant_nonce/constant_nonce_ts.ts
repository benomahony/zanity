import { createCipheriv } from "node:crypto";

createCipheriv("aes-256-gcm", key, "fixed-nonce1");
createCipheriv("aes-256-gcm", key, nonce);
createCipheriv("aes-256-cbc", key, "0123456789abcdef");
