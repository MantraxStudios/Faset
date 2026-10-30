// =============================================================================
//  std.crypto  —  criptografía: hash, HMAC, PBKDF2, AES-GCM y números aleatorios seguros.
//
//    string h = Sha256.HashHex("hola");                  // "b221d9db..."
//    string mac = HmacSha256.Hash(clave, mensaje);       // 32 bytes
//    string k = Pbkdf2.DeriveKey("contraseña", sal, 600000, 32);
//
//    var aes = new AesGcm(RandomNumberGenerator.GetBytes(32));
//    string sellado = aes.Seal("secreto");               // nonce + cifrado + etiqueta
//    string claro = aes.Open(sellado);                   // CryptographicException si se manipuló
//
//  Los datos binarios (claves, resúmenes, textos cifrados) son cadenas: un string de Faset
//  es una vista de bytes y puede contener cualquier valor. Para mostrarlos usa Hex o
//  Base64 (std.text).
//
//  Implementación: BearSSL (licencia MIT, lib/net/bearssl) en lib/crypto/faset_crypto.c.
//  AES usa AES-NI y PCLMUL si la CPU los tiene y, si no, código de tiempo constante.
//  La aleatoriedad viene del sistema: getrandom (Linux), /dev/urandom (Android) y
//  BCryptGenRandom (Windows).
// =============================================================================
using std.collections;
using std.text;
using std.io;

namespace std.crypto
{
    // Algoritmos de hash (el orden coincide con faset_crypto.c).
    public enum HashAlgorithm { MD5, SHA1, SHA224, SHA256, SHA384, SHA512 }

    // Error criptográfico: etiqueta de autenticación incorrecta (datos manipulados o clave
    // equivocada), clave de tamaño no válido...
    [ExceptionBase("Exception")]
    public class CryptographicException
    {
        public CryptographicException() { Message = "Error en una operación criptográfica."; }
        public CryptographicException(string message) { Message = message; }
        public CryptographicException(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }

        public string ToString() => Exception.Describe(this);
    }

    // Funciones de lib/crypto/faset_crypto.c.
    memory_unsafe static class CryptoNative
    {
        public static extern int faset_crypto_ctx_size();
        public static extern int faset_hash_init(void* ctx, int alg);
        public static extern int faset_hmac_init(void* ctx, int alg, byte* key, long keyLength);
        public static extern void faset_hash_update(void* ctx, byte* data, long n);
        public static extern int faset_hash_final(void* ctx, byte* output);
        public static extern int faset_pbkdf2(int alg, byte* pw, long pwLength, byte* salt, long saltLength, int iterations, byte* output, long outLength);
        public static extern int faset_aes_gcm(int encrypt, byte* key, int keyLength, byte* iv, int ivLength, byte* aad, long aadLength, byte* data, long length, byte* tag);
        public static extern int faset_random_bytes(byte* output, long n);
        public static extern int faset_fixed_time_equals(byte* a, long aLength, byte* b, long bLength);

        public static int DigestSize(HashAlgorithm a)
        {
            if (a == HashAlgorithm.MD5) return 16;
            if (a == HashAlgorithm.SHA1) return 20;
            if (a == HashAlgorithm.SHA224) return 28;
            if (a == HashAlgorithm.SHA256) return 32;
            if (a == HashAlgorithm.SHA384) return 48;
            return 64;
        }
    }

    // ---------------------------------------------------------------- hash incremental

    // Hash o HMAC calculado por partes, como System.Security.Cryptography.IncrementalHash:
    //   var h = IncrementalHash.CreateHash(HashAlgorithm.SHA256);
    //   h.AppendData("parte 1");
    //   h.AppendData("parte 2");
    //   string resumen = h.GetHashAndReset();
    // Las clases Sha256, HmacSha256... derivan de esta.
    public memory_unsafe class IncrementalHash
    {
        byte* ctx;
        HashAlgorithm algorithm;
        bool isHmac;
        string hmacKey;
        int size;

        protected IncrementalHash(HashAlgorithm a, bool hmac, string key)
        {
            algorithm = a;
            isHmac = hmac;
            hmacKey = String.Copy(key);
            ctx = Memory.AllocBytes(CryptoNative.faset_crypto_ctx_size());
            Reset();
        }

        // Hash simple (SHA-256, SHA-512...).
        public static IncrementalHash CreateHash(HashAlgorithm a) => new IncrementalHash(a, false, "");
        // HMAC con la clave 'key'.
        public static IncrementalHash CreateHmac(HashAlgorithm a, string key) => new IncrementalHash(a, true, key);

        public HashAlgorithm Algorithm => algorithm;
        // Tamaño del resultado en bytes (32 para SHA-256).
        public int HashLengthInBytes => size;

        // Añade datos (se puede llamar tantas veces como haga falta).
        public void AppendData(string data) { CryptoNative.faset_hash_update(ctx, data.Ptr, data.Length); }

        // Igual que AppendData, pero encadenable: h.Update("a").Update("b").Final().
        public IncrementalHash Update(string data)
        {
            AppendData(data);
            return this;
        }

        // Resultado de los datos añadidos hasta ahora (se puede seguir añadiendo).
        public string GetCurrentHash()
        {
            byte* p = Memory.AllocBytes(size + 1);
            CryptoNative.faset_hash_final(ctx, p);
            p[size] = 0;
            return String.FromBytes(p, size);
        }

        // Resultado, y vuelve a empezar (como si fuera nuevo).
        public string GetHashAndReset()
        {
            string r = GetCurrentHash();
            Reset();
            return r;
        }

        // Atajos: resultado en bytes o en hexadecimal (minúsculas).
        public string Final() => GetCurrentHash();
        public string FinalHex() => Hex.Encode(GetCurrentHash());

        // Olvida los datos añadidos.
        public void Reset()
        {
            if (!isHmac) size = CryptoNative.faset_hash_init(ctx, (int)algorithm);
            else size = CryptoNative.faset_hmac_init(ctx, (int)algorithm, hmacKey.Ptr, hmacKey.Length);
        }

        // Hash de una sola vez.
        public static string HashData(HashAlgorithm a, string data)
        {
            IncrementalHash h = new IncrementalHash(a, false, "");
            h.AppendData(data);
            return h.GetCurrentHash();
        }

        // HMAC de una sola vez.
        public static string HmacData(HashAlgorithm a, string key, string data)
        {
            IncrementalHash h = new IncrementalHash(a, true, key);
            h.AppendData(data);
            return h.GetCurrentHash();
        }

        // Hash de un archivo, leído por bloques (sirve para archivos grandes).
        [TrackCaller] public static string HashFile(HashAlgorithm a, string path)
        {
            IncrementalHash h = new IncrementalHash(a, false, "");
            FileStream f = File.OpenRead(path);
            if (f == null)
            {
                if (!File.Exists(path)) throw new FileNotFoundException("HashFile: no se encontró el archivo '" + path + "'", path);
                throw new IOException("HashFile: no se puede leer el archivo '" + path + "'");
            }
            byte* buffer = Memory.AllocBytes(65536);
            while (true)
            {
                int n = f.Read(buffer, 65536);
                if (n <= 0) break;
                CryptoNative.faset_hash_update(h.ctx, buffer, n);
            }
            f.Close();
            return h.GetCurrentHash();
        }
    }

    // ---------------------------------------------------------------- funciones hash

    // SHA-256 (FIPS 180-4): resumen de 32 bytes. La elección habitual.
    public class Sha256 : IncrementalHash
    {
        public Sha256() : base(HashAlgorithm.SHA256, false, "") { }
        public const int HashSizeInBytes = 32;
        public static string Hash(string data) => HashData(HashAlgorithm.SHA256, data);
        public static string HashHex(string data) => Hex.Encode(Hash(data));
        [TrackCaller] public static string HashFile(string path) => HashFile(HashAlgorithm.SHA256, path);
    }

    // SHA-224: SHA-256 truncado a 28 bytes.
    public class Sha224 : IncrementalHash
    {
        public Sha224() : base(HashAlgorithm.SHA224, false, "") { }
        public const int HashSizeInBytes = 28;
        public static string Hash(string data) => HashData(HashAlgorithm.SHA224, data);
        public static string HashHex(string data) => Hex.Encode(Hash(data));
    }

    // SHA-384: resumen de 48 bytes.
    public class Sha384 : IncrementalHash
    {
        public Sha384() : base(HashAlgorithm.SHA384, false, "") { }
        public const int HashSizeInBytes = 48;
        public static string Hash(string data) => HashData(HashAlgorithm.SHA384, data);
        public static string HashHex(string data) => Hex.Encode(Hash(data));
    }

    // SHA-512: resumen de 64 bytes.
    public class Sha512 : IncrementalHash
    {
        public Sha512() : base(HashAlgorithm.SHA512, false, "") { }
        public const int HashSizeInBytes = 64;
        public static string Hash(string data) => HashData(HashAlgorithm.SHA512, data);
        public static string HashHex(string data) => Hex.Encode(Hash(data));
        [TrackCaller] public static string HashFile(string path) => HashFile(HashAlgorithm.SHA512, path);
    }

    // SHA-1: resumen de 20 bytes. OBSOLETO para seguridad (hay colisiones prácticas desde
    // 2017): úsalo solo para compatibilidad (Git, WebSocket, formatos antiguos).
    public class Sha1 : IncrementalHash
    {
        public Sha1() : base(HashAlgorithm.SHA1, false, "") { }
        public const int HashSizeInBytes = 20;
        public static string Hash(string data) => HashData(HashAlgorithm.SHA1, data);
        public static string HashHex(string data) => Hex.Encode(Hash(data));
    }

    // MD5: resumen de 16 bytes. INSEGURO: está roto (colisiones en segundos). Úsalo solo
    // para sumas de comprobación sin adversario o compatibilidad, nunca para contraseñas,
    // firmas ni integridad frente a manipulaciones.
    public class Md5 : IncrementalHash
    {
        public Md5() : base(HashAlgorithm.MD5, false, "") { }
        public const int HashSizeInBytes = 16;
        public static string Hash(string data) => HashData(HashAlgorithm.MD5, data);
        public static string HashHex(string data) => Hex.Encode(Hash(data));
    }

    // ---------------------------------------------------------------- HMAC (RFC 2104)

    // HMAC-SHA256: código de autenticación de mensajes de 32 bytes.
    //   string mac = HmacSha256.Hash(clave, mensaje);
    //   bool ok = CryptographicOperations.FixedTimeEquals(mac, macRecibido);
    public class HmacSha256 : IncrementalHash
    {
        public HmacSha256(string key) : base(HashAlgorithm.SHA256, true, key) { }
        public static string Hash(string key, string data) => HmacData(HashAlgorithm.SHA256, key, data);
        public static string HashHex(string key, string data) => Hex.Encode(Hash(key, data));
    }

    public class HmacSha384 : IncrementalHash
    {
        public HmacSha384(string key) : base(HashAlgorithm.SHA384, true, key) { }
        public static string Hash(string key, string data) => HmacData(HashAlgorithm.SHA384, key, data);
        public static string HashHex(string key, string data) => Hex.Encode(Hash(key, data));
    }

    public class HmacSha512 : IncrementalHash
    {
        public HmacSha512(string key) : base(HashAlgorithm.SHA512, true, key) { }
        public static string Hash(string key, string data) => HmacData(HashAlgorithm.SHA512, key, data);
        public static string HashHex(string key, string data) => Hex.Encode(Hash(key, data));
    }

    // HMAC-SHA1 (aceptable en HMAC, pero prefiere HMAC-SHA256 en diseños nuevos).
    public class HmacSha1 : IncrementalHash
    {
        public HmacSha1(string key) : base(HashAlgorithm.SHA1, true, key) { }
        public static string Hash(string key, string data) => HmacData(HashAlgorithm.SHA1, key, data);
        public static string HashHex(string key, string data) => Hex.Encode(Hash(key, data));
    }

    // HMAC-MD5: solo para compatibilidad con protocolos antiguos.
    public class HmacMd5 : IncrementalHash
    {
        public HmacMd5(string key) : base(HashAlgorithm.MD5, true, key) { }
        public static string Hash(string key, string data) => HmacData(HashAlgorithm.MD5, key, data);
        public static string HashHex(string key, string data) => Hex.Encode(Hash(key, data));
    }

    // HMAC con el algoritmo como parámetro: Hmac.Compute(HashAlgorithm.SHA512, clave, datos).
    public static class Hmac
    {
        public static string Compute(HashAlgorithm algorithm, string key, string data) => IncrementalHash.HmacData(algorithm, key, data);
    }

    // ---------------------------------------------------------------- PBKDF2 (RFC 8018)

    // Deriva claves de contraseñas (PBKDF2 con HMAC). Usa una sal aleatoria de al menos
    // 16 bytes por contraseña y muchas iteraciones (OWASP 2023: 600 000 con SHA-256).
    public memory_unsafe static class Pbkdf2
    {
        // PBKDF2-HMAC-SHA256: 'length' bytes derivados.
        [TrackCaller] public static string DeriveKey(string password, string salt, int iterations, int length) =>
            DeriveKey(password, salt, iterations, length, HashAlgorithm.SHA256);

        [TrackCaller] public static string DeriveKey(string password, string salt, int iterations, int length, HashAlgorithm algorithm)
        {
            if (iterations < 1) throw new ArgumentOutOfRangeException("Pbkdf2: 'iterations' debe ser al menos 1", "iterations");
            if (length < 1) throw new ArgumentOutOfRangeException("Pbkdf2: 'length' debe ser al menos 1", "length");
            byte* p = Memory.AllocBytes(length + 1);
            CryptoNative.faset_pbkdf2((int)algorithm, password.Ptr, password.Length, salt.Ptr, salt.Length, iterations, p, length);
            p[length] = 0;
            return String.FromBytes(p, length);
        }
    }

    // Guardar y comprobar contraseñas con PBKDF2-HMAC-SHA256 y sal aleatoria, en un único texto:
    //   string guardado = PasswordHasher.Hash("contraseña");   // "pbkdf2-sha256$600000$<sal>$<hash>"
    //   bool ok = PasswordHasher.Verify("contraseña", guardado);
    public static class PasswordHasher
    {
        public const int DefaultIterations = 600000;

        public static string Hash(string password) => Hash(password, DefaultIterations);

        public static string Hash(string password, int iterations)
        {
            string salt = RandomNumberGenerator.GetBytes(16);
            string key = Pbkdf2.DeriveKey(password, salt, iterations, 32);
            return "pbkdf2-sha256$" + iterations + "$" + Base64.Encode(salt) + "$" + Base64.Encode(key);
        }

        // true si 'password' corresponde a 'stored' (comparación en tiempo constante). Un
        // texto con otro formato devuelve false.
        public static bool Verify(string password, string stored)
        {
            List<string> parts = Text.Split(stored, "$");
            if (parts.Count != 4 || parts[0] != "pbkdf2-sha256") return false;
            int iterations;
            string salt, key;
            if (!int.TryParse(parts[1], out iterations) || iterations < 1) return false;
            if (!Base64.TryDecode(parts[2], out salt) || !Base64.TryDecode(parts[3], out key) || key.Length == 0) return false;
            return CryptographicOperations.FixedTimeEquals(Pbkdf2.DeriveKey(password, salt, iterations, key.Length), key);
        }
    }

    // ---------------------------------------------------------------- AES-GCM

    // Cifrado autenticado AES-GCM (NIST SP 800-38D) con claves de 16, 24 o 32 bytes, nonce
    // de 12 bytes y etiqueta de 16. Nunca repitas un nonce con la misma clave: Seal genera
    // uno aleatorio en cada llamada.
    public memory_unsafe class AesGcm
    {
        string key;

        public const int NonceSize = 12;
        public const int TagSize = 16;

        // ArgumentException si la clave no tiene 16, 24 o 32 bytes.
        public AesGcm(string key)
        {
            if (key.Length != 16 && key.Length != 24 && key.Length != 32)
                throw new ArgumentException("AesGcm: la clave debe tener 16, 24 o 32 bytes (tiene " + key.Length + ")", "key");
            this.key = String.Copy(key);
        }

        // Clave aleatoria de 32 bytes (AES-256).
        public static string GenerateKey() => RandomNumberGenerator.GetBytes(32);

        // Cifra 'plaintext': devuelve el texto cifrado seguido de la etiqueta (16 bytes).
        public string Encrypt(string nonce, string plaintext) => Encrypt(nonce, plaintext, "");

        // Igual, autenticando además 'associatedData' (datos que no se cifran pero no se pueden cambiar).
        [TrackCaller] public string Encrypt(string nonce, string plaintext, string associatedData)
        {
            CheckNonce(nonce);
            byte* p = Memory.AllocBytes(plaintext.Length + TagSize + 1);
            Memory.Copy(p, plaintext.Ptr, plaintext.Length);
            CryptoNative.faset_aes_gcm(1, key.Ptr, key.Length, nonce.Ptr, nonce.Length, associatedData.Ptr, associatedData.Length,
                                       p, plaintext.Length, p + plaintext.Length);
            p[plaintext.Length + TagSize] = 0;
            return String.FromBytes(p, plaintext.Length + TagSize);
        }

        // Descifra lo que devolvió Encrypt. CryptographicException si la etiqueta no coincide.
        [TrackCaller] public string Decrypt(string nonce, string ciphertextAndTag) => Decrypt(nonce, ciphertextAndTag, "");

        [TrackCaller] public string Decrypt(string nonce, string ciphertextAndTag, string associatedData)
        {
            CheckNonce(nonce);
            if (ciphertextAndTag.Length < TagSize) throw new CryptographicException("AesGcm: el texto cifrado es demasiado corto");
            int n = ciphertextAndTag.Length - TagSize;
            return DecryptDetached(nonce, ciphertextAndTag.Substring(0, n), ciphertextAndTag.Substring(n), associatedData);
        }

        // Variante con la etiqueta aparte (como AesGcm.Encrypt de .NET): devuelve el texto
        // cifrado (mismo tamaño que el original) y la etiqueta en 'tag'.
        [TrackCaller] public string EncryptDetached(string nonce, string plaintext, string associatedData, out string tag)
        {
            string all = Encrypt(nonce, plaintext, associatedData);
            tag = all.Substring(plaintext.Length);
            return all.Substring(0, plaintext.Length);
        }

        [TrackCaller] public string DecryptDetached(string nonce, string ciphertext, string tag, string associatedData)
        {
            CheckNonce(nonce);
            if (tag.Length != TagSize) throw new CryptographicException("AesGcm: la etiqueta debe tener 16 bytes");
            byte* p = Memory.AllocBytes(ciphertext.Length + 1);
            Memory.Copy(p, ciphertext.Ptr, ciphertext.Length);
            p[ciphertext.Length] = 0;
            byte* t = Memory.AllocBytes(TagSize);
            Memory.Copy(t, tag.Ptr, TagSize);
            int ok = CryptoNative.faset_aes_gcm(0, key.Ptr, key.Length, nonce.Ptr, nonce.Length, associatedData.Ptr, associatedData.Length,
                                                p, ciphertext.Length, t);
            if (ok != 1) throw new CryptographicException("AesGcm: la etiqueta de autenticación no coincide (datos manipulados o clave incorrecta)");
            return String.FromBytes(p, ciphertext.Length);
        }

        // Cifra con un nonce aleatorio nuevo: devuelve nonce (12) + cifrado + etiqueta (16).
        public string Seal(string plaintext) => Seal(plaintext, "");

        public string Seal(string plaintext, string associatedData)
        {
            string nonce = RandomNumberGenerator.GetBytes(NonceSize);
            return nonce + Encrypt(nonce, plaintext, associatedData);
        }

        // Descifra lo que devolvió Seal. CryptographicException si se manipuló.
        [TrackCaller] public string Open(string sealedData) => Open(sealedData, "");

        [TrackCaller] public string Open(string sealedData, string associatedData)
        {
            if (sealedData.Length < NonceSize + TagSize) throw new CryptographicException("AesGcm.Open: los datos son demasiado cortos");
            return Decrypt(sealedData.Substring(0, NonceSize), sealedData.Substring(NonceSize), associatedData);
        }

        [TrackCaller] static void CheckNonce(string nonce)
        {
            if (nonce.Length == 0) throw new ArgumentException("AesGcm: el nonce no puede estar vacío (usa 12 bytes)", "nonce");
        }
    }

    // ---------------------------------------------------------------- aleatoriedad

    // Números aleatorios criptográficamente seguros del sistema operativo (para claves,
    // sales, nonces y tokens). Para juegos y simulaciones basta std.random (más rápido).
    public memory_unsafe static class RandomNumberGenerator
    {
        // 'count' bytes aleatorios.
        [TrackCaller] public static string GetBytes(int count)
        {
            if (count < 0) throw new ArgumentOutOfRangeException("RandomNumberGenerator.GetBytes: 'count' no puede ser negativo", "count");
            byte* p = Memory.AllocBytes(count + 1);
            if (CryptoNative.faset_random_bytes(p, count) != 0) throw new CryptographicException("RandomNumberGenerator: el sistema no proporcionó números aleatorios");
            p[count] = 0;
            return String.FromBytes(p, count);
        }

        public static ulong GetUInt64()
        {
            ulong v = 0;
            if (CryptoNative.faset_random_bytes((byte*)&v, 8) != 0) throw new CryptographicException("RandomNumberGenerator: el sistema no proporcionó números aleatorios");
            return v;
        }

        // Entero uniforme en [0, toExclusive), sin sesgo.
        [TrackCaller] public static int GetInt32(int toExclusive) => GetInt32(0, toExclusive);

        // Entero uniforme en [fromInclusive, toExclusive), sin sesgo.
        [TrackCaller] public static int GetInt32(int fromInclusive, int toExclusive)
        {
            if (toExclusive <= fromInclusive) throw new ArgumentException("RandomNumberGenerator.GetInt32: el intervalo está vacío", "toExclusive");
            ulong range = (ulong)((long)toExclusive - fromInclusive);
            ulong limit = ulong.MaxValue - ulong.MaxValue % range;   // rechazo: sin sesgo de módulo
            ulong v = GetUInt64();
            while (v >= limit) v = GetUInt64();
            return (int)((long)fromInclusive + (long)(v % range));
        }

        // Texto hexadecimal aleatorio de 'length' caracteres (tokens, identificadores).
        public static string GetHexString(int length)
        {
            string h = Hex.Encode(GetBytes((length + 1) / 2));
            return h.Substring(0, length);
        }

        // Texto aleatorio de 'length' caracteres tomados de 'alphabet' (ASCII), sin sesgo.
        [TrackCaller] public static string GetString(string alphabet, int length)
        {
            if (alphabet.Length == 0) throw new ArgumentException("RandomNumberGenerator.GetString: el alfabeto está vacío", "alphabet");
            StringBuilder sb = new StringBuilder(length);
            for (int i = 0; i < length; i++) sb.AppendByte(alphabet[GetInt32(alphabet.Length)]);
            return sb.ToString();
        }
    }

    // ---------------------------------------------------------------- utilidades

    public memory_unsafe static class CryptographicOperations
    {
        // Compara en tiempo constante (el tiempo no revela dónde está la primera diferencia):
        // úsalo para comparar MAC, etiquetas y resúmenes de contraseñas.
        public static bool FixedTimeEquals(string a, string b) => CryptoNative.faset_fixed_time_equals(a.Ptr, a.Length, b.Ptr, b.Length) != 0;
    }
}
