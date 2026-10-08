function derive(password: Buffer) {
  return crypto.pbkdf2Sync(password, "shared-salt", 200_000, 32, "sha256");
}

function deriveUnique(password: Buffer, salt: Buffer) {
  return crypto.pbkdf2Sync(password, salt, 200_000, 32, "sha256");
}

function literalPassword(dynamicSalt: Buffer) {
  return crypto.pbkdf2Sync("fixed test password", dynamicSalt, 200_000, 32, "sha256");
}
