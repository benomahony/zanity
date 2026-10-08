import { createCipheriv } from "node:crypto";

createCipheriv("aes-256-cbc", key, "0123456789abcdef");
createCipheriv("aes-256-cbc", key, iv);
