// std.crypto con vectores oficiales: FIPS 180 (SHA), RFC 1321 (MD5), RFC 4231 / 2202 / 2104
// (HMAC), RFC 6070 / 7914 (PBKDF2), McGrew-Viega / NIST (AES-GCM); aleatoriedad del sistema
// y comparación en tiempo constante.
using std.crypto;
using std.text;
using std.io;

void Comprobar(string nombre, string obtenido, string esperado)
{
    println((obtenido == esperado ? "ok    " : "FALLO ") + nombre + (obtenido == esperado ? "" : " -> " + obtenido));
}

void main()
{
    // ---- hash
    Comprobar("MD5('')", Md5.HashHex(""), "d41d8cd98f00b204e9800998ecf8427e");
    Comprobar("MD5(abc)", Md5.HashHex("abc"), "900150983cd24fb0d6963f7d28e17f72");
    Comprobar("SHA1(abc)", Sha1.HashHex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d");
    Comprobar("SHA224(abc)", Sha224.HashHex("abc"), "23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7");
    Comprobar("SHA256(abc)", Sha256.HashHex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    Comprobar("SHA256(448 bits)", Sha256.HashHex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
              "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    Comprobar("SHA384(abc)", Sha384.HashHex("abc"),
              "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7");
    Comprobar("SHA512(abc)", Sha512.HashHex("abc"),
              "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f");

    // Un millón de 'a' por partes (incremental).
    var h = new Sha256();
    string mil = Text.Repeat("a", 1000);
    for (int i = 0; i < 1000; i++) h.AppendData(mil);
    Comprobar("SHA256(10^6 a)", h.FinalHex(), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
    h.Reset();
    Comprobar("SHA256 tras Reset", Hex.Encode(h.Update("a").Update("bc").GetHashAndReset()), Sha256.HashHex("abc"));
    println(h.HashLengthInBytes);
    var inc = IncrementalHash.CreateHash(HashAlgorithm.SHA512);
    inc.AppendData("ab");
    inc.AppendData("c");
    Comprobar("IncrementalHash SHA512", Hex.Encode(inc.GetCurrentHash()), Sha512.HashHex("abc"));

    string tmp = Path.GetTempFileName();
    File.WriteAllText(tmp, "abc");
    Comprobar("Sha256.HashFile", Hex.Encode(Sha256.HashFile(tmp)), Sha256.HashHex("abc"));
    File.Delete(tmp);
    try { Sha256.HashFile("no_existe.bin"); } catch (FileNotFoundException e) { println("FileNotFoundException"); }

    // ---- HMAC
    string k20 = Text.Repeat("\u000b", 20);
    Comprobar("HMAC-SHA256 RFC4231 #1", HmacSha256.HashHex(k20, "Hi There"),
              "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
    Comprobar("HMAC-SHA256 RFC4231 #2", HmacSha256.HashHex("Jefe", "what do ya want for nothing?"),
              "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    Comprobar("HMAC-SHA512 RFC4231 #1", HmacSha512.HashHex(k20, "Hi There"),
              "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cdedaa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854");
    Comprobar("HMAC-SHA1 RFC2202 #2", HmacSha1.HashHex("Jefe", "what do ya want for nothing?"), "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79");
    Comprobar("HMAC-MD5 RFC2104", HmacMd5.HashHex("Jefe", "what do ya want for nothing?"), "750c783e6ab0b503eaa86e310a5db738");
    // Clave más larga que el bloque (RFC 4231 #6).
    Comprobar("HMAC-SHA256 RFC4231 #6", HmacSha256.HashHex(Text.Repeat("ª", 1) == "" ? "" : Hex.Decode(Text.Repeat("aa", 131)),
                                                         "Test Using Larger Than Block-Size Key - Hash Key First"),
              "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54");
    var mac = new HmacSha256("Jefe");
    mac.AppendData("what do ya want ");
    mac.AppendData("for nothing?");
    Comprobar("HMAC incremental", mac.FinalHex(), HmacSha256.HashHex("Jefe", "what do ya want for nothing?"));
    Comprobar("Hmac.Compute", Hex.Encode(Hmac.Compute(HashAlgorithm.SHA384, "k", "d")), HmacSha384.HashHex("k", "d"));

    // ---- PBKDF2
    Comprobar("PBKDF2-SHA1 RFC6070 c=1", Hex.Encode(Pbkdf2.DeriveKey("password", "salt", 1, 20, HashAlgorithm.SHA1)),
              "0c60c80f961f0e71f3a9b524af6012062fe037a6");
    Comprobar("PBKDF2-SHA1 RFC6070 c=4096", Hex.Encode(Pbkdf2.DeriveKey("password", "salt", 4096, 20, HashAlgorithm.SHA1)),
              "4b007901b765489abead49d926f721d065a429c1");
    Comprobar("PBKDF2-SHA1 RFC6070 25 bytes", Hex.Encode(Pbkdf2.DeriveKey("passwordPASSWORDpassword", "saltSALTsaltSALTsaltSALTsaltSALTsalt", 4096, 25, HashAlgorithm.SHA1)),
              "3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038");
    Comprobar("PBKDF2-SHA256 RFC7914", Hex.Encode(Pbkdf2.DeriveKey("passwd", "salt", 1, 64)),
              "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783");
    string guardado = PasswordHasher.Hash("secreto", 1000);
    println(guardado.StartsWith("pbkdf2-sha256$1000$"));
    println(PasswordHasher.Verify("secreto", guardado));
    println(PasswordHasher.Verify("Secreto", guardado));
    println(PasswordHasher.Verify("secreto", "basura"));

    // ---- AES-GCM (McGrew-Viega, casos 2, 4 y 16)
    var cero = new AesGcm(Hex.Decode("00000000000000000000000000000000"));
    Comprobar("AES-128-GCM #2", Hex.Encode(cero.Encrypt(Hex.Decode("000000000000000000000000"), Hex.Decode("00000000000000000000000000000000"))),
              "0388dace60b6a392f328c2b971b2fe78" + "ab6e47d42cec13bdf53a67b21257bddf");
    string p4 = Hex.Decode("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39");
    string a4 = Hex.Decode("feedfacedeadbeeffeedfacedeadbeefabaddad2");
    string iv4 = Hex.Decode("cafebabefacedbaddecaf888");
    var aes128 = new AesGcm(Hex.Decode("feffe9928665731c6d6a8f9467308308"));
    string c4 = aes128.Encrypt(iv4, p4, a4);
    Comprobar("AES-128-GCM #4", Hex.Encode(c4),
              "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091" +
              "5bc94fbc3221a5db94fae95ae7121a47");
    Comprobar("AES-128-GCM #4 descifrado", Hex.Encode(aes128.Decrypt(iv4, c4, a4)), Hex.Encode(p4));
    var aes256 = new AesGcm(Hex.Decode("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308"));
    string tag;
    string c16 = aes256.EncryptDetached(iv4, p4, a4, out tag);
    Comprobar("AES-256-GCM #16", Hex.Encode(c16),
              "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662");
    Comprobar("AES-256-GCM #16 etiqueta", Hex.Encode(tag), "76fc6ece0f4e1768cddf8853bb2d551b");
    try
    {
        aes128.Decrypt(iv4, c4, "otros datos asociados");
        println("FALLO: no detectó la manipulación");
    }
    catch (CryptographicException e) { println("manipulación detectada"); }
    var clave = new AesGcm(AesGcm.GenerateKey());
    string sellado = clave.Seal("mensaje secreto");
    println(sellado.Length);                      // 12 + 15 + 16
    println(clave.Open(sellado));
    println(clave.Seal("x") != clave.Seal("x"));  // nonce aleatorio
    try { new AesGcm("corta"); } catch (ArgumentException e) { println(e.Message); }

    // ---- aleatoriedad y utilidades
    string r1 = RandomNumberGenerator.GetBytes(32), r2 = RandomNumberGenerator.GetBytes(32);
    println(r1.Length == 32 && r1 != r2);
    bool enRango = true;
    for (int i = 0; i < 1000; i++)
    {
        int v = RandomNumberGenerator.GetInt32(-5, 5);
        if (v < -5 || v >= 5) enRango = false;
    }
    println(enRango);
    println(RandomNumberGenerator.GetHexString(7).Length);
    println(Text.Replace(Text.Replace(RandomNumberGenerator.GetString("ab", 10), "a", ""), "b", "").Length);
    println(CryptographicOperations.FixedTimeEquals("abc", "abc"));
    println(CryptographicOperations.FixedTimeEquals("abc", "abd"));
    println(CryptographicOperations.FixedTimeEquals("abc", "abcd"));
}
