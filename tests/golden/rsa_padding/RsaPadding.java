class RsaPadding {
    Cipher legacy() throws Exception {
        return Cipher.getInstance("RSA/ECB/PKCS1Padding");
    }

    Cipher oaep() throws Exception {
        return Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding");
    }

    Cipher misleading() throws Exception {
        return OtherCipher.getInstance("RSA/ECB/PKCS1Padding");
    }
}
