use rsa::{Oaep, Pkcs1v15Encrypt, RsaPublicKey};

pub fn seal(key: &RsaPublicKey, data: &[u8]) -> Vec<u8> {
    key.encrypt(&mut rand::thread_rng(), Pkcs1v15Encrypt, data).unwrap()
}

pub fn seal_safely(key: &RsaPublicKey, data: &[u8]) -> Vec<u8> {
    key.encrypt(&mut rand::thread_rng(), Oaep::new::<sha2::Sha256>(), data).unwrap()
}
