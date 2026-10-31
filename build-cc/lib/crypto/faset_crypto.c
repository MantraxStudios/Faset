/* =============================================================================
 *  Faset - std.crypto: funciones hash, HMAC, PBKDF2, AES-GCM y números aleatorios.
 *
 *  El compilador añade este archivo a todo programa que use 'using std.crypto;' y enlaza
 *  BearSSL (lib/net/bearssl, licencia MIT), compilado una sola vez por compilador y
 *  arquitectura: de BearSSL se usan MD5, SHA-1, SHA-2, HMAC, AES (con AES-NI si la CPU lo
 *  tiene; si no, la versión de tiempo constante 'ct64') y GHASH para GCM.
 *
 *  Los contextos (hash, HMAC) los reserva Faset en memoria del recolector sin punteros
 *  (Memory.AllocBytes) con el tamaño de faset_crypto_ctx_size(): solo contienen datos y
 *  punteros a tablas estáticas de BearSSL.
 *
 *  Aleatoriedad del sistema operativo: getrandom() en Linux, /dev/urandom en Android (y si
 *  getrandom no existe) y BCryptGenRandom en Windows.
 * ============================================================================= */
#if !defined(_WIN32)
#  define _GNU_SOURCE 1
#endif
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "../net/bearssl/inc/bearssl.h"

#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>
#  include <bcrypt.h>
#else
#  include <errno.h>
#  include <fcntl.h>
#  include <unistd.h>
#  if defined(__linux__) && !defined(__ANDROID__)
#    include <sys/syscall.h>
#  endif
#endif

/* Algoritmos (el mismo orden que el enum HashAlgorithm de crypto.fst). */
enum { FC_MD5 = 0, FC_SHA1 = 1, FC_SHA224 = 2, FC_SHA256 = 3, FC_SHA384 = 4, FC_SHA512 = 5 };

typedef struct {
    int32_t kind;  /* 1 = hash, 2 = HMAC */
    union {
        br_hash_compat_context hash;
        struct {
            br_hmac_key_context key;
            br_hmac_context mac;
        } hmac;
    } u;
} fc_ctx;

static const br_hash_class* fc_class(int32_t alg) {
    switch (alg) {
        case FC_MD5: return &br_md5_vtable;
        case FC_SHA1: return &br_sha1_vtable;
        case FC_SHA224: return &br_sha224_vtable;
        case FC_SHA256: return &br_sha256_vtable;
        case FC_SHA384: return &br_sha384_vtable;
        case FC_SHA512: return &br_sha512_vtable;
        default: return NULL;
    }
}

static int32_t fc_size(const br_hash_class* c) { return (int32_t)((c->desc >> BR_HASHDESC_OUT_OFF) & BR_HASHDESC_OUT_MASK); }

int32_t faset_crypto_ctx_size(void) { return (int32_t)sizeof(fc_ctx); }

/* ---------------------------------------------------------------- hash */

int32_t faset_hash_init(void* p, int32_t alg) {
    fc_ctx* c = (fc_ctx*)p;
    const br_hash_class* k = fc_class(alg);
    if (!k) return -1;
    c->kind = 1;
    k->init(&c->u.hash.vtable);
    return fc_size(k);
}

void faset_hash_update(void* p, const uint8_t* data, int64_t n) {
    fc_ctx* c = (fc_ctx*)p;
    while (n > 0) {
        size_t chunk = n > (1 << 30) ? (size_t)1 << 30 : (size_t)n;
        if (c->kind == 1) c->u.hash.vtable->update(&c->u.hash.vtable, data, chunk);
        else br_hmac_update(&c->u.hmac.mac, data, chunk);
        data += chunk;
        n -= (int64_t)chunk;
    }
}

/* Escribe el resultado en 'out' (no cambia el contexto: se puede seguir añadiendo datos). */
int32_t faset_hash_final(void* p, uint8_t* out) {
    fc_ctx* c = (fc_ctx*)p;
    if (c->kind == 1) {
        c->u.hash.vtable->out(&c->u.hash.vtable, out);
        return fc_size(c->u.hash.vtable);
    }
    return (int32_t)br_hmac_out(&c->u.hmac.mac, out);
}

/* ---------------------------------------------------------------- HMAC */

int32_t faset_hmac_init(void* p, int32_t alg, const uint8_t* key, int64_t keyLength) {
    fc_ctx* c = (fc_ctx*)p;
    const br_hash_class* k = fc_class(alg);
    if (!k) return -1;
    c->kind = 2;
    br_hmac_key_init(&c->u.hmac.key, k, key, (size_t)keyLength);
    br_hmac_init(&c->u.hmac.mac, &c->u.hmac.key, 0);
    return fc_size(k);
}

/* ---------------------------------------------------------------- PBKDF2 (RFC 8018) */

int32_t faset_pbkdf2(int32_t alg, const uint8_t* pw, int64_t pwLength, const uint8_t* salt, int64_t saltLength,
                     int32_t iterations, uint8_t* out, int64_t outLength) {
    const br_hash_class* k = fc_class(alg);
    if (!k || iterations < 1) return -1;
    size_t hlen = (size_t)fc_size(k);
    br_hmac_key_context key;
    br_hmac_context mac;
    br_hmac_key_init(&key, k, pw, (size_t)pwLength);
    uint8_t u[64], t[64];
    uint32_t block = 1;
    while (outLength > 0) {
        uint8_t be[4] = {(uint8_t)(block >> 24), (uint8_t)(block >> 16), (uint8_t)(block >> 8), (uint8_t)block};
        br_hmac_init(&mac, &key, 0);
        br_hmac_update(&mac, salt, (size_t)saltLength);
        br_hmac_update(&mac, be, 4);
        br_hmac_out(&mac, u);
        memcpy(t, u, hlen);
        for (int32_t i = 1; i < iterations; i++) {
            br_hmac_init(&mac, &key, 0);
            br_hmac_update(&mac, u, hlen);
            br_hmac_out(&mac, u);
            for (size_t j = 0; j < hlen; j++) t[j] ^= u[j];
        }
        size_t take = (int64_t)hlen < outLength ? hlen : (size_t)outLength;
        memcpy(out, t, take);
        out += take;
        outLength -= (int64_t)take;
        block++;
    }
    memset(u, 0, sizeof u);
    memset(t, 0, sizeof t);
    memset(&key, 0, sizeof key);
    return 0;
}

/* ---------------------------------------------------------------- AES-GCM */

/* Cifra (encrypt = 1) o descifra 'data' en su sitio. Al cifrar escribe la etiqueta de 16
 * bytes en 'tag'; al descifrar la comprueba (en tiempo constante) y devuelve 0 si no
 * coincide (y borra los datos). Devuelve 1 si todo va bien y -1 si la clave no es válida. */
int32_t faset_aes_gcm(int32_t encrypt, const uint8_t* key, int32_t keyLength, const uint8_t* iv, int32_t ivLength,
                      const uint8_t* aad, int64_t aadLength, uint8_t* data, int64_t length, uint8_t* tag) {
    if (keyLength != 16 && keyLength != 24 && keyLength != 32) return -1;
    union {
        const br_block_ctr_class* vtable;
        br_aes_ct64_ctr_keys ct64;
        br_aes_x86ni_ctr_keys x86ni;
    } aes;
    const br_block_ctr_class* cls = br_aes_x86ni_ctr_get_vtable();
    if (!cls) cls = &br_aes_ct64_ctr_vtable;
    cls->init(&aes.vtable, key, (size_t)keyLength);
    br_ghash gh = br_ghash_pclmul_get();
    if (!gh) gh = &br_ghash_ctmul64;
    br_gcm_context gcm;
    br_gcm_init(&gcm, &aes.vtable, gh);
    br_gcm_reset(&gcm, iv, (size_t)ivLength);
    if (aadLength > 0) br_gcm_aad_inject(&gcm, aad, (size_t)aadLength);
    br_gcm_flip(&gcm);
    int64_t left = length;
    uint8_t* d = data;
    while (left > 0) {
        /* trozos múltiplos de 16 (br_gcm_run admite cualquier longitud, pero solo la última puede ser parcial) */
        size_t chunk = left > (1 << 30) ? (size_t)1 << 30 : (size_t)left;
        br_gcm_run(&gcm, encrypt, d, chunk);
        d += chunk;
        left -= (int64_t)chunk;
    }
    int32_t r = 1;
    if (encrypt) br_gcm_get_tag(&gcm, tag);
    else if (!br_gcm_check_tag(&gcm, tag)) {
        memset(data, 0, (size_t)length);
        r = 0;
    }
    memset(&aes, 0, sizeof aes);
    memset(&gcm, 0, sizeof gcm);
    return r;
}

/* ---------------------------------------------------------------- aleatoriedad del sistema */

int32_t faset_random_bytes(uint8_t* out, int64_t n) {
#if defined(_WIN32)
    while (n > 0) {
        ULONG chunk = n > 0x40000000 ? 0x40000000u : (ULONG)n;
        if (BCryptGenRandom(NULL, out, chunk, BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) return -1;
        out += chunk;
        n -= chunk;
    }
    return 0;
#else
#  if defined(__linux__) && !defined(__ANDROID__) && defined(SYS_getrandom)
    while (n > 0) {
        size_t chunk = n > 0x2000000 ? 0x2000000 : (size_t)n;
        long r = syscall(SYS_getrandom, out, chunk, 0);
        if (r < 0) {
            if (errno == EINTR) continue;
            break;  /* ENOSYS (núcleo antiguo): /dev/urandom */
        }
        out += r;
        n -= r;
    }
    if (n == 0) return 0;
#  endif
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    while (n > 0) {
        ssize_t r = read(fd, out, n > 0x100000 ? 0x100000 : (size_t)n);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) {
            close(fd);
            return -1;
        }
        out += r;
        n -= r;
    }
    close(fd);
    return 0;
#endif
}

/* ---------------------------------------------------------------- comparación en tiempo constante */

/* 1 si son iguales. El tiempo solo depende de la longitud (no de dónde está la diferencia). */
int32_t faset_fixed_time_equals(const uint8_t* a, int64_t aLength, const uint8_t* b, int64_t bLength) {
    if (aLength != bLength) return 0;
    volatile uint8_t acc = 0;
    for (int64_t i = 0; i < aLength; i++) acc |= a[i] ^ b[i];
    return acc == 0;
}
