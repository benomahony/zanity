function derive(password) {
    return crypto.pbkdf2Sync(password, "shared-salt", 200_000, 32, "sha256");
}
function deriveUnique(password, salt) {
    return crypto.pbkdf2Sync(password, salt, 200_000, 32, "sha256");
}
function literalPassword(dynamicSalt) {
    return crypto.pbkdf2Sync("fixed test password", dynamicSalt, 200_000, 32, "sha256");
}
