using System.Security.Cryptography;

class Sealing
{
    byte[] Seal(RSA rsa, byte[] data)
    {
        return rsa.Encrypt(data, RSAEncryptionPadding.Pkcs1);
    }

    byte[] SealSafely(RSA rsa, byte[] data)
    {
        return rsa.Encrypt(data, RSAEncryptionPadding.OaepSHA256);
    }
}
