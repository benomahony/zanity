using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;

class Crypto
{
    void Ivs(Aes aes, byte[] key, byte[] data, byte[] iv)
    {
        aes.IV = new byte[16];
        aes.IV = Encoding.UTF8.GetBytes("0123456789abcdef");
        aes.IV = iv;
        aes.CreateEncryptor(key, new byte[] { 1, 2, 3 });
        aes.CreateEncryptor(key, iv);
        aes.EncryptCbc(data, Convert.FromHexString("00112233445566778899aabbccddeeff"));
        aes.GenerateIV();
    }

    void Nonces(AesGcm gcm, RSA rsa, byte[] plain, byte[] cipher, byte[] tag, byte[] nonce)
    {
        gcm.Encrypt(new byte[12], plain, cipher, tag);
        gcm.Encrypt(nonce, plain, cipher, tag);
        rsa.Encrypt(Encoding.UTF8.GetBytes("hello"), RSAEncryptionPadding.OaepSHA256);
    }

    void Shells(string name)
    {
        Process.Start("cmd.exe", "/c dir " + name);
        Process.Start("bash", $"-c 'ls {name}'");
        Process.Start("bash", "-c 'ls /tmp'");
        Process.Start("git", "status " + name);
        new ProcessStartInfo("sh", "-c " + name);
        new ProcessStartInfo { FileName = "pwsh", Arguments = $"-Command {name}" };
        new ProcessStartInfo { FileName = "dotnet", Arguments = $"build {name}" };
    }
}
