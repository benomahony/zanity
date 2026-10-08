fn derive(password: &[u8]) {
    pbkdf2::pbkdf2_hmac(password, b"shared-salt", 200_000, &mut [0; 32]);
}

fn derive_unique(password: &[u8], salt: &[u8]) {
    pbkdf2::pbkdf2_hmac(password, salt, 200_000, &mut [0; 32]);
}

fn literal_password(dynamic_salt: &[u8]) {
    pbkdf2::pbkdf2_hmac(b"fixed test password", dynamic_salt, 200_000, &mut [0; 32]);
}
