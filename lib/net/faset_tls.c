/* =============================================================================
 *  Faset - std.net: TLS (HTTPS) para TlsStream y HttpClient.
 *
 *  El compilador añade este archivo a todo programa que use 'using std.net;' (ver
 *  src/main.cpp). Es C puro y solo lo
 *  llama el hilo que usa el TlsStream: no crea hilos, no llama a código de Faset y no
 *  guarda referencias a objetos de Faset (el estado es memoria de C, opaca para Faset).
 *
 *  Motores (todos con la misma interfaz faset_tls_*):
 *    Linux    OpenSSL 3 (libssl.so.3 / libcrypto.so.3; también vale 1.1) cargado con
 *             dlopen la primera vez que se negocia TLS: un programa sin HTTPS no depende
 *             de OpenSSL y no hacen falta las cabeceras -dev (las pocas funciones que se
 *             usan se declaran aquí). Autoridades de confianza: las del sistema
 *             (SSL_CTX_set_default_verify_paths). TLS 1.2 y 1.3.
 *    Windows  Schannel (SSPI, secur32). Valida contra el almacén de certificados de
 *             Windows. TLS 1.2 y, en Windows 11 / Server 2022, TLS 1.3.
 *    Android  BearSSL (licencia MIT, en lib/net/bearssl; el compilador lo compila
 *             solo para Android) con las autoridades del sistema:
 *             /apex/com.android.conscrypt/cacerts (Android 14+) o
 *             /system/etc/security/cacerts. Solo TLS 1.2. Es una copia sin cambios del
 *             repositorio de BearSSL (bearssl.org, commit 7bea48e, posterior a la 0.6),
 *             sin los fuentes .t0 (de ellos salen algunos .c, que sí están incluidos).
 *    Con -DFASET_TLS_BEARSSL se usa BearSSL también en Linux (para probarlo).
 *
 *  Todos los motores cifran en memoria y este archivo hace la E/S del socket (poll /
 *  select con el tiempo de espera de cada operación). El socket sigue siendo el del
 *  programa, bloqueante, y nunca se recibe SIGPIPE (MSG_NOSIGNAL).
 *
 *  Resultados: 0 = éxito, -1 = error; el motivo queda en faset_tls_error_kind /
 *  faset_tls_error_text (en español) y faset_tls_native_error (errno, código de
 *  OpenSSL, SECURITY_STATUS o código de BearSSL).
 * ============================================================================= */
#if !defined(_WIN32)
#  define _GNU_SOURCE 1
#endif
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  define FT_SCHANNEL 1
#elif defined(__ANDROID__) || defined(FASET_TLS_BEARSSL)
#  define FT_BEARSSL 1
#else
#  define FT_OPENSSL 1
#endif

#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <winsock2.h>
#  include <ws2tcpip.h>
#  include <windows.h>
#  define SECURITY_WIN32
#  define SCHANNEL_USE_BLACKLISTS 1  /* SCH_CREDENTIALS y TLS_PARAMETERS (TLS 1.3) */
#  include <subauth.h>
#  include <security.h>
#  include <schannel.h>
#else
#  include <arpa/inet.h>
#  include <dirent.h>
#  include <errno.h>
#  include <poll.h>
#  include <pthread.h>
#  include <sys/socket.h>
#  include <sys/stat.h>
#  include <time.h>
#  include <unistd.h>
#  if defined(FT_OPENSSL)
#    include <dlfcn.h>
#  endif
#endif

#if defined(FT_BEARSSL)
#  include "bearssl/inc/bearssl.h"
#endif

/* Cadena de Faset (vista: puntero + longitud, sin '\0'). */
typedef struct { const uint8_t* ptr; int64_t len; } ft_str;

/* Clases de error (las traduce TlsStream a SocketError). */
enum {
    FT_OK = 0,
    FT_IO = 1,           /* error del socket: native = errno / WSAGetLastError */
    FT_TIMEOUT = 2,
    FT_CLOSED = 3,       /* el otro extremo cerró durante la negociación */
    FT_TLS = 4,          /* error del protocolo TLS */
    FT_CERT = 5,         /* el certificado no supera la verificación */
    FT_UNAVAILABLE = 6,  /* no hay motor TLS (falta OpenSSL) o la función no existe aquí */
    FT_ARG = 7           /* argumento o archivo no válido (certificado, clave...) */
};

#define FT_REC 16709  /* registro TLS máximo (16 KiB + cabecera y relleno) */

typedef struct ft_tls ft_tls;

#if defined(FT_OPENSSL)
typedef struct { void* ctx; void* ssl; void* rbio; void* wbio; } ft_backend;
#elif defined(FT_BEARSSL)
typedef struct ft_bearssl ft_bearssl;
typedef struct { ft_bearssl* b; } ft_backend;
#else
typedef struct {
    CredHandle cred;
    CtxtHandle ctx;
    int hasCred, hasCtx;
    SecPkgContext_StreamSizes sizes;
    unsigned char* in;   /* datos cifrados recibidos y aún no procesados */
    size_t inLen, inCap;
    unsigned char* dec;  /* texto ya descifrado pendiente de entregar */
    size_t decPos, decLen, decCap;
    unsigned char* out;  /* búfer para cifrar */
    wchar_t whost[256];
} ft_backend;
#endif

struct ft_tls {
    int64_t sock;
    int server;
    int verify;
    int ready;           /* negociación completada */
    int closed;          /* el otro extremo terminó (close_notify o fin del socket) */
    int hostIsIp;
    int kind;
    int native;
    char host[256];
    char msg[512];
    char proto[32];
    char cipher[128];
    ft_backend be;
};

/* ------------------------------------------------------------------ errores */

static int ft_fail(ft_tls* t, int kind, int native, const char* fmt, ...) {
    va_list ap;
    t->kind = kind;
    t->native = native;
    va_start(ap, fmt);
    vsnprintf(t->msg, sizeof t->msg, fmt, ap);
    va_end(ap);
    return -1;
}

static void ft_clear(ft_tls* t) {
    t->kind = FT_OK;
    t->native = 0;
    t->msg[0] = 0;
}

/* Copia una cadena de Faset a un búfer de C terminado en '\0' (false si no cabe o tiene '\0'). */
static int ft_cstr(ft_str s, char* out, size_t cap) {
    if (s.len < 0 || (size_t)s.len >= cap) return 0;
    if (s.len > 0) memcpy(out, s.ptr, (size_t)s.len);
    out[s.len] = 0;
    return strlen(out) == (size_t)s.len;
}

/* Copia de una cadena de Faset con malloc (NULL si está vacía). */
static char* ft_dup(ft_str s) {
    if (s.len <= 0) return NULL;
    char* r = (char*)malloc((size_t)s.len + 1);
    if (!r) return NULL;
    memcpy(r, s.ptr, (size_t)s.len);
    r[s.len] = 0;
    return r;
}

static int ft_is_ip(const char* host) {
    unsigned char buf[16];
#if defined(_WIN32)
    struct sockaddr_storage ss;
    int len = sizeof ss;
    (void)buf;
    char tmp[256];
    snprintf(tmp, sizeof tmp, "%s", host);
    if (WSAStringToAddressA(tmp, AF_INET, NULL, (struct sockaddr*)&ss, &len) == 0) return 1;
    len = sizeof ss;
    snprintf(tmp, sizeof tmp, "%s", host);
    return WSAStringToAddressA(tmp, AF_INET6, NULL, (struct sockaddr*)&ss, &len) == 0;
#else
    return inet_pton(AF_INET, host, buf) == 1 || inet_pton(AF_INET6, host, buf) == 1;
#endif
}

/* ------------------------------------------------------------------ E/S del socket */

static int ft_last_error(void) {
#if defined(_WIN32)
    return WSAGetLastError();
#else
    return errno;
#endif
}

static int ft_again(int e) {
#if defined(_WIN32)
    return e == WSAEWOULDBLOCK || e == WSAEINTR;
#else
    return e == EAGAIN || e == EWOULDBLOCK || e == EINTR;
#endif
}

#if !defined(_WIN32)
static int64_t ft_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
#endif

/* Espera a poder leer (write = 0) o escribir. 1 = listo, 0 = tiempo agotado, -1 = error. */
static int ft_wait(int64_t sock, int write, int timeoutMs) {
#if defined(_WIN32)
    fd_set set, ex;
    struct timeval tv;
    FD_ZERO(&set);
    FD_ZERO(&ex);
    FD_SET((SOCKET)sock, &set);
    FD_SET((SOCKET)sock, &ex);
    if (timeoutMs >= 0) {
        tv.tv_sec = timeoutMs / 1000;
        tv.tv_usec = (timeoutMs % 1000) * 1000;
    }
    int r = select(0, write ? NULL : &set, write ? &set : NULL, &ex, timeoutMs >= 0 ? &tv : NULL);
    return r > 0 ? 1 : (r == 0 ? 0 : -1);
#else
    struct pollfd p;
    int64_t deadline = ft_now_ms() + timeoutMs;
    for (;;) {
        int left = timeoutMs;
        if (timeoutMs >= 0) {
            int64_t l = deadline - ft_now_ms();
            left = l > 0 ? (int)l : 0;
        }
        p.fd = (int)sock;
        p.events = write ? POLLOUT : POLLIN;
        p.revents = 0;
        int r = poll(&p, 1, left);
        if (r > 0) return 1;
        if (r == 0) return 0;
        if (errno != EINTR) return -1;
    }
#endif
}

/* Envía todos los bytes. 0 = bien, -1 = error (anotado). */
static int ft_send_all(ft_tls* t, const unsigned char* p, size_t n, int timeoutMs) {
    while (n > 0) {
        int w = ft_wait(t->sock, 1, timeoutMs);
        if (w == 0) return ft_fail(t, FT_TIMEOUT, 0, "tiempo de espera agotado al enviar");
        if (w < 0) {
            int e = ft_last_error();
            return ft_fail(t, FT_IO, e, "error del socket al enviar");
        }
        int chunk = n > 65536 ? 65536 : (int)n;
#if defined(_WIN32)
        int k = send((SOCKET)t->sock, (const char*)p, chunk, 0);
#else
        int k = (int)send((int)t->sock, p, (size_t)chunk, MSG_NOSIGNAL | MSG_DONTWAIT);
#endif
        if (k < 0) {
            int e = ft_last_error();
            if (ft_again(e)) continue;
            return ft_fail(t, FT_IO, e, "error del socket al enviar");
        }
        p += k;
        n -= (size_t)k;
    }
    return 0;
}

/* Recibe lo que haya (espera como mucho timeoutMs). >0 bytes, 0 = el otro extremo cerró, -1 = error. */
static int ft_recv_some(ft_tls* t, unsigned char* p, size_t cap, int timeoutMs) {
    if (cap > 65536) cap = 65536;
    for (;;) {
        int w = ft_wait(t->sock, 0, timeoutMs);
        if (w == 0) return ft_fail(t, FT_TIMEOUT, 0, "tiempo de espera agotado al recibir");
        if (w < 0) {
            int e = ft_last_error();
            return ft_fail(t, FT_IO, e, "error del socket al recibir");
        }
#if defined(_WIN32)
        int k = recv((SOCKET)t->sock, (char*)p, (int)cap, 0);
#else
        int k = (int)recv((int)t->sock, p, cap, MSG_DONTWAIT);
#endif
        if (k >= 0) return k;
        int e = ft_last_error();
        if (ft_again(e)) continue;
        return ft_fail(t, FT_IO, e, "error del socket al recibir");
    }
}

/* Texto común de los fallos de verificación. */
static int ft_cert_fail(ft_tls* t, int native, const char* why) {
    return ft_fail(t, FT_CERT, native, "certificado no válido para '%s': %s", t->host, why);
}

/* =============================================================================
 *  OpenSSL (Linux), cargado con dlopen
 * ============================================================================= */
#if defined(FT_OPENSSL)

/* Constantes de las cabeceras de OpenSSL (ABI estable desde 1.1). */
#define O_SSL_VERIFY_NONE 0
#define O_SSL_VERIFY_PEER 1
#define O_SSL_FILETYPE_PEM 1
#define O_SSL_CTRL_SET_TLSEXT_HOSTNAME 55
#define O_SSL_CTRL_SET_MIN_PROTO_VERSION 123
#define O_TLSEXT_NAMETYPE_host_name 0
#define O_TLS1_2_VERSION 0x0303
#define O_SSL_ERROR_SSL 1
#define O_SSL_ERROR_WANT_READ 2
#define O_SSL_ERROR_WANT_WRITE 3
#define O_SSL_ERROR_SYSCALL 5
#define O_SSL_ERROR_ZERO_RETURN 6

static struct {
    const void* (*TLS_client_method)(void);
    const void* (*TLS_server_method)(void);
    void* (*SSL_CTX_new)(const void*);
    void (*SSL_CTX_free)(void*);
    int (*SSL_CTX_set_default_verify_paths)(void*);
    int (*SSL_CTX_load_verify_locations)(void*, const char*, const char*);
    void (*SSL_CTX_set_verify)(void*, int, void*);
    long (*SSL_CTX_ctrl)(void*, int, long, void*);
    int (*SSL_CTX_use_certificate_chain_file)(void*, const char*);
    int (*SSL_CTX_use_PrivateKey_file)(void*, const char*, int);
    int (*SSL_CTX_check_private_key)(const void*);
    void* (*SSL_new)(void*);
    void (*SSL_free)(void*);
    long (*SSL_ctrl)(void*, int, long, void*);
    int (*SSL_set1_host)(void*, const char*);
    void* (*SSL_get0_param)(void*);
    void (*SSL_set_bio)(void*, void*, void*);
    void (*SSL_set_connect_state)(void*);
    void (*SSL_set_accept_state)(void*);
    int (*SSL_do_handshake)(void*);
    int (*SSL_read)(void*, void*, int);
    int (*SSL_write)(void*, const void*, int);
    int (*SSL_shutdown)(void*);
    int (*SSL_get_error)(const void*, int);
    long (*SSL_get_verify_result)(const void*);
    const char* (*SSL_get_version)(const void*);
    const void* (*SSL_get_current_cipher)(const void*);
    const char* (*SSL_CIPHER_get_name)(const void*);
    int (*SSL_pending)(const void*);
    void* (*BIO_new)(const void*);
    const void* (*BIO_s_mem)(void);
    int (*BIO_read)(void*, void*, int);
    int (*BIO_write)(void*, const void*, int);
    size_t (*BIO_ctrl_pending)(void*);
    unsigned long (*ERR_get_error)(void);
    void (*ERR_error_string_n)(unsigned long, char*, size_t);
    void (*ERR_clear_error)(void);
    const char* (*X509_verify_cert_error_string)(long);
    int (*X509_VERIFY_PARAM_set1_ip_asc)(void*, const char*);
} O;

static pthread_once_t g_load_once = PTHREAD_ONCE_INIT;
static int g_loaded;
static char g_load_error[256];
static char g_backend[64] = "OpenSSL";

static void o_load(void) {
    static const char* const sslNames[] = {"libssl.so.3", "libssl.so.1.1", "libssl.so"};
    static const char* const cryptoNames[] = {"libcrypto.so.3", "libcrypto.so.1.1", "libcrypto.so"};
    void* ssl = NULL;
    void* crypto = NULL;
    for (int i = 0; i < 3 && !ssl; i++) {
        crypto = dlopen(cryptoNames[i], RTLD_NOW | RTLD_LOCAL);
        ssl = dlopen(sslNames[i], RTLD_NOW | RTLD_LOCAL);
        if (ssl) snprintf(g_backend, sizeof g_backend, "OpenSSL (%s)", sslNames[i]);
        else if (crypto) {
            dlclose(crypto);
            crypto = NULL;
        }
    }
    if (!ssl) {
        snprintf(g_load_error, sizeof g_load_error,
                 "no se encontró OpenSSL (libssl.so.3): instala el paquete libssl3 (o openssl) para usar HTTPS");
        return;
    }
    struct { const char* name; void** slot; } fns[] = {
#define F(n) {#n, (void**)&O.n}
        F(TLS_client_method), F(TLS_server_method), F(SSL_CTX_new), F(SSL_CTX_free),
        F(SSL_CTX_set_default_verify_paths), F(SSL_CTX_load_verify_locations), F(SSL_CTX_set_verify),
        F(SSL_CTX_ctrl), F(SSL_CTX_use_certificate_chain_file), F(SSL_CTX_use_PrivateKey_file),
        F(SSL_CTX_check_private_key), F(SSL_new), F(SSL_free), F(SSL_ctrl), F(SSL_set1_host),
        F(SSL_get0_param), F(SSL_set_bio), F(SSL_set_connect_state), F(SSL_set_accept_state),
        F(SSL_do_handshake), F(SSL_read), F(SSL_write), F(SSL_shutdown), F(SSL_get_error),
        F(SSL_get_verify_result), F(SSL_get_version), F(SSL_get_current_cipher), F(SSL_CIPHER_get_name),
        F(SSL_pending), F(BIO_new), F(BIO_s_mem), F(BIO_read), F(BIO_write), F(BIO_ctrl_pending),
        F(ERR_get_error), F(ERR_error_string_n), F(ERR_clear_error), F(X509_verify_cert_error_string),
        F(X509_VERIFY_PARAM_set1_ip_asc),
#undef F
    };
    for (size_t i = 0; i < sizeof fns / sizeof fns[0]; i++) {
        void* f = dlsym(ssl, fns[i].name);
        if (!f && crypto) f = dlsym(crypto, fns[i].name);
        if (!f) {
            snprintf(g_load_error, sizeof g_load_error,
                     "OpenSSL es demasiado antiguo (falta %s): hace falta OpenSSL 1.1 o 3", fns[i].name);
            return;
        }
        *fns[i].slot = f;
    }
    g_loaded = 1;
}

static int o_ready(ft_tls* t) {
    pthread_once(&g_load_once, o_load);
    if (!g_loaded) return ft_fail(t, FT_UNAVAILABLE, 0, "%s", g_load_error);
    return 0;
}

/* Envía lo que OpenSSL dejó en el BIO de salida. */
static int o_flush(ft_tls* t, int timeoutMs) {
    unsigned char buf[FT_REC];
    while (O.BIO_ctrl_pending(t->be.wbio) > 0) {
        int n = O.BIO_read(t->be.wbio, buf, sizeof buf);
        if (n <= 0) break;
        if (ft_send_all(t, buf, (size_t)n, timeoutMs) < 0) return -1;
    }
    return 0;
}

/* Lee del socket al BIO de entrada. >0 bytes, 0 = fin de la conexión, -1 = error. */
static int o_fill(ft_tls* t, int timeoutMs) {
    unsigned char buf[FT_REC];
    int n = ft_recv_some(t, buf, sizeof buf, timeoutMs);
    if (n > 0) O.BIO_write(t->be.rbio, buf, n);
    return n;
}

static const char* o_cert_reason(long v) {
    switch (v) {
        case 2: case 20: case 21: return "no lo firma ninguna autoridad de confianza";
        case 9: return "aún no es válido (¿la fecha del sistema es correcta?)";
        case 10: return "ha caducado";
        case 18: return "es autofirmado (no lo firma ninguna autoridad de confianza)";
        case 19: return "la cadena termina en una autoridad que no es de confianza";
        case 23: return "está revocado";
        case 26: return "no sirve para identificar un servidor";
        case 62: return "se emitió para otro nombre de equipo";
        case 64: return "se emitió para otra dirección IP";
        default: return NULL;
    }
}

/* Describe el fallo de una llamada de OpenSSL. */
static int o_error(ft_tls* t, int ret, const char* what) {
    int e = O.SSL_get_error(t->be.ssl, ret);
    if (!t->server && t->verify) {
        long v = O.SSL_get_verify_result(t->be.ssl);
        if (v != 0) {
            const char* why = o_cert_reason(v);
            if (!why) why = O.X509_verify_cert_error_string(v);
            O.ERR_clear_error();
            return ft_cert_fail(t, (int)v, why);
        }
    }
    unsigned long code = O.ERR_get_error();
    char text[256];
    if (code) O.ERR_error_string_n(code, text, sizeof text);
    else snprintf(text, sizeof text, "código %d", e);
    O.ERR_clear_error();
    return ft_fail(t, FT_TLS, (int)code, "%s: %s", what, text);
}

static void o_free(ft_tls* t) {
    if (t->be.ssl) O.SSL_free(t->be.ssl);  /* libera también los dos BIO */
    if (t->be.ctx) O.SSL_CTX_free(t->be.ctx);
    t->be.ssl = t->be.ctx = NULL;
}

static int o_handshake(ft_tls* t, int timeoutMs) {
    for (;;) {
        O.ERR_clear_error();
        int r = O.SSL_do_handshake(t->be.ssl);
        if (o_flush(t, timeoutMs) < 0) return -1;
        if (r == 1) break;
        int e = O.SSL_get_error(t->be.ssl, r);
        if (e == O_SSL_ERROR_WANT_READ) {
            int n = o_fill(t, timeoutMs);
            if (n < 0) return -1;
            if (n == 0) return ft_fail(t, FT_CLOSED, 0, "el otro extremo cerró la conexión durante la negociación TLS");
            continue;
        }
        if (e == O_SSL_ERROR_WANT_WRITE) continue;
        return o_error(t, r, "fallo en la negociación TLS");
    }
    const void* c = O.SSL_get_current_cipher(t->be.ssl);
    snprintf(t->proto, sizeof t->proto, "%s", O.SSL_get_version(t->be.ssl));
    snprintf(t->cipher, sizeof t->cipher, "%s", c ? O.SSL_CIPHER_get_name(c) : "");
    return 0;
}

static int o_setup(ft_tls* t, int server) {
    t->be.ctx = O.SSL_CTX_new(server ? O.TLS_server_method() : O.TLS_client_method());
    if (!t->be.ctx) return o_error(t, 0, "no se pudo crear el contexto TLS");
    O.SSL_CTX_ctrl(t->be.ctx, O_SSL_CTRL_SET_MIN_PROTO_VERSION, O_TLS1_2_VERSION, NULL);
    return 0;
}

static int o_attach(ft_tls* t) {
    t->be.ssl = O.SSL_new(t->be.ctx);
    void* rb = O.BIO_new(O.BIO_s_mem());
    void* wb = O.BIO_new(O.BIO_s_mem());
    if (!t->be.ssl || !rb || !wb) return ft_fail(t, FT_TLS, 0, "sin memoria para TLS");
    O.SSL_set_bio(t->be.ssl, rb, wb);
    t->be.rbio = rb;
    t->be.wbio = wb;
    return 0;
}

static int be_client(ft_tls* t, const char* caFile, int timeoutMs) {
    if (o_ready(t) < 0 || o_setup(t, 0) < 0) return -1;
    if (t->verify) {
        O.SSL_CTX_set_verify(t->be.ctx, O_SSL_VERIFY_PEER, NULL);
        O.SSL_CTX_set_default_verify_paths(t->be.ctx);
        if (caFile && O.SSL_CTX_load_verify_locations(t->be.ctx, caFile, NULL) != 1) {
            O.ERR_clear_error();
            return ft_fail(t, FT_ARG, 0, "no se pudo leer el archivo de autoridades '%s'", caFile);
        }
    } else {
        O.SSL_CTX_set_verify(t->be.ctx, O_SSL_VERIFY_NONE, NULL);
    }
    if (o_attach(t) < 0) return -1;
    if (!t->hostIsIp && t->host[0])
        O.SSL_ctrl(t->be.ssl, O_SSL_CTRL_SET_TLSEXT_HOSTNAME, O_TLSEXT_NAMETYPE_host_name, t->host);  /* SNI */
    if (t->verify && t->host[0]) {
        int ok = t->hostIsIp ? O.X509_VERIFY_PARAM_set1_ip_asc(O.SSL_get0_param(t->be.ssl), t->host)
                             : O.SSL_set1_host(t->be.ssl, t->host);
        if (ok != 1) return ft_fail(t, FT_ARG, 0, "nombre de equipo no válido para TLS: '%s'", t->host);
    }
    O.SSL_set_connect_state(t->be.ssl);
    return o_handshake(t, timeoutMs);
}

static int be_server(ft_tls* t, const char* certFile, const char* keyFile, int timeoutMs) {
    if (o_ready(t) < 0 || o_setup(t, 1) < 0) return -1;
    if (O.SSL_CTX_use_certificate_chain_file(t->be.ctx, certFile) != 1) {
        O.ERR_clear_error();
        return ft_fail(t, FT_ARG, 0, "no se pudo leer el certificado '%s' (PEM)", certFile);
    }
    if (O.SSL_CTX_use_PrivateKey_file(t->be.ctx, keyFile, O_SSL_FILETYPE_PEM) != 1) {
        O.ERR_clear_error();
        return ft_fail(t, FT_ARG, 0, "no se pudo leer la clave privada '%s' (PEM)", keyFile);
    }
    if (O.SSL_CTX_check_private_key(t->be.ctx) != 1) {
        O.ERR_clear_error();
        return ft_fail(t, FT_ARG, 0, "la clave privada no corresponde al certificado");
    }
    if (o_attach(t) < 0) return -1;
    O.SSL_set_accept_state(t->be.ssl);
    return o_handshake(t, timeoutMs);
}

static int be_send(ft_tls* t, const unsigned char* p, int n, int timeoutMs) {
    int done = 0;
    while (done < n) {
        int chunk = n - done > 16384 ? 16384 : n - done;
        O.ERR_clear_error();
        int r = O.SSL_write(t->be.ssl, p + done, chunk);
        if (r <= 0) {
            int e = O.SSL_get_error(t->be.ssl, r);
            if (e == O_SSL_ERROR_WANT_READ) {
                if (o_flush(t, timeoutMs) < 0) return -1;
                int k = o_fill(t, timeoutMs);
                if (k < 0) return -1;
                if (k == 0) return ft_fail(t, FT_IO, 0, "el otro extremo cerró la conexión");
                continue;
            }
            return o_error(t, r, "error de TLS al enviar");
        }
        done += r;
        if (o_flush(t, timeoutMs) < 0) return -1;
    }
    return n;
}

static int be_recv(ft_tls* t, unsigned char* p, int cap, int timeoutMs) {
    for (;;) {
        O.ERR_clear_error();
        int r = O.SSL_read(t->be.ssl, p, cap);
        if (r > 0) return r;
        int e = O.SSL_get_error(t->be.ssl, r);
        if (o_flush(t, timeoutMs) < 0) return -1;  /* p. ej. respuesta a un KeyUpdate de TLS 1.3 */
        if (e == O_SSL_ERROR_ZERO_RETURN) {
            t->closed = 1;
            return 0;
        }
        if (e == O_SSL_ERROR_WANT_READ) {
            int k = o_fill(t, timeoutMs);
            if (k < 0) return -1;
            if (k == 0) {  /* fin sin close_notify: se trata como fin normal (HTTP/1.0 hace esto) */
                t->closed = 1;
                return 0;
            }
            continue;
        }
        if (e == O_SSL_ERROR_WANT_WRITE) continue;
        return o_error(t, r, "error de TLS al recibir");
    }
}

static int be_pending(ft_tls* t) { return t->be.ssl ? O.SSL_pending(t->be.ssl) : 0; }

static void be_close(ft_tls* t, int timeoutMs) {
    if (!t->be.ssl) return;
    O.ERR_clear_error();
    O.SSL_shutdown(t->be.ssl);
    O.ERR_clear_error();
    o_flush(t, timeoutMs);
}

static void be_free(ft_tls* t) {
    if (g_loaded) o_free(t);
}

static const char* be_name(void) {
    pthread_once(&g_load_once, o_load);
    return g_backend;
}

static int be_available(void) {
    pthread_once(&g_load_once, o_load);
    return g_loaded;
}

#endif /* FT_OPENSSL */

/* =============================================================================
 *  BearSSL (Android; en Linux con -DFASET_TLS_BEARSSL)
 * ============================================================================= */
#if defined(FT_BEARSSL)

/* Lista de autoridades de confianza. */
typedef struct {
    br_x509_trust_anchor* v;
    size_t n, cap;
} ft_anchors;

/* Validador que acepta cualquier certificado (ValidateCertificate = false): solo toma la
   clave pública del primer certificado de la cadena. */
typedef struct {
    const br_x509_class* vtable;
    br_x509_decoder_context dc;
    int depth;
} ft_noverify;

struct ft_bearssl {
    br_ssl_engine_context* eng;
    union {
        br_ssl_client_context cc;
        br_ssl_server_context sc;
    } u;
    br_x509_minimal_context xc;
    ft_noverify nv;
    ft_anchors extra;           /* autoridades del archivo CertificateAuthorityFile */
    br_x509_trust_anchor* all;  /* las del sistema + las extra */
    br_x509_certificate* chain; /* servidor: cadena de certificados */
    size_t chainLen;
    br_skey_decoder_context skey;
    unsigned char iobuf[BR_SSL_BUFSIZE_BIDI];
};

static ft_anchors g_sys;
static pthread_once_t g_sys_once = PTHREAD_ONCE_INIT;

typedef struct { unsigned char* p; size_t n, cap; } ft_buf;

static void buf_append(void* ctx, const void* data, size_t len) {
    ft_buf* b = (ft_buf*)ctx;
    if (b->n + len > b->cap) {
        size_t c = b->cap ? b->cap * 2 : 2048;
        while (c < b->n + len) c *= 2;
        unsigned char* np = (unsigned char*)realloc(b->p, c);
        if (!np) return;
        b->p = np;
        b->cap = c;
    }
    memcpy(b->p + b->n, data, len);
    b->n += len;
}

static void* ft_memdup(const void* p, size_t n) {
    void* r = malloc(n ? n : 1);
    if (r && n) memcpy(r, p, n);
    return r;
}

/* Convierte un certificado DER en autoridad de confianza y la añade. */
static void anchors_add_der(ft_anchors* a, const unsigned char* der, size_t len) {
    br_x509_decoder_context dc;
    ft_buf dn = {0};
    br_x509_decoder_init(&dc, buf_append, &dn);
    br_x509_decoder_push(&dc, der, len);
    const br_x509_pkey* pk = br_x509_decoder_get_pkey(&dc);
    if (!pk || !dn.p) {
        free(dn.p);
        return;
    }
    if (a->n == a->cap) {
        size_t c = a->cap ? a->cap * 2 : 64;
        br_x509_trust_anchor* nv = (br_x509_trust_anchor*)realloc(a->v, c * sizeof *nv);
        if (!nv) {
            free(dn.p);
            return;
        }
        a->v = nv;
        a->cap = c;
    }
    br_x509_trust_anchor* ta = &a->v[a->n];
    memset(ta, 0, sizeof *ta);
    ta->dn.data = dn.p;
    ta->dn.len = dn.n;
    ta->flags = BR_X509_TA_CA;  /* todas actúan como autoridad (algunas raíces v1 no lo declaran) */
    ta->pkey.key_type = pk->key_type;
    if (pk->key_type == BR_KEYTYPE_RSA) {
        ta->pkey.key.rsa.n = (unsigned char*)ft_memdup(pk->key.rsa.n, pk->key.rsa.nlen);
        ta->pkey.key.rsa.nlen = pk->key.rsa.nlen;
        ta->pkey.key.rsa.e = (unsigned char*)ft_memdup(pk->key.rsa.e, pk->key.rsa.elen);
        ta->pkey.key.rsa.elen = pk->key.rsa.elen;
    } else if (pk->key_type == BR_KEYTYPE_EC) {
        ta->pkey.key.ec.curve = pk->key.ec.curve;
        ta->pkey.key.ec.q = (unsigned char*)ft_memdup(pk->key.ec.q, pk->key.ec.qlen);
        ta->pkey.key.ec.qlen = pk->key.ec.qlen;
    } else {
        free(dn.p);
        return;
    }
    a->n++;
}

static void anchors_free(ft_anchors* a) {
    for (size_t i = 0; i < a->n; i++) {
        br_x509_trust_anchor* ta = &a->v[i];
        free(ta->dn.data);
        if (ta->pkey.key_type == BR_KEYTYPE_RSA) {
            free(ta->pkey.key.rsa.n);
            free(ta->pkey.key.rsa.e);
        } else {
            free(ta->pkey.key.ec.q);
        }
    }
    free(a->v);
    a->v = NULL;
    a->n = a->cap = 0;
}

/* Recorre los objetos PEM de 'data' y llama a 'fn' con el DER de cada uno. */
static void pem_each(const unsigned char* data, size_t len,
                     void (*fn)(void* ctx, const char* name, const unsigned char* der, size_t n), void* ctx) {
    br_pem_decoder_context pc;
    ft_buf der = {0};
    char name[128] = {0};
    int inObj = 0;
    br_pem_decoder_init(&pc);
    int tail = 0;  /* se añade un salto de línea final por si el archivo no lo tiene */
    while (len > 0 || !tail) {
        if (len == 0) {
            data = (const unsigned char*)"\n";
            len = 1;
            tail = 1;
        }
        size_t used = br_pem_decoder_push(&pc, data, len);
        data += used;
        len -= used;
        switch (br_pem_decoder_event(&pc)) {
            case BR_PEM_BEGIN_OBJ:
                snprintf(name, sizeof name, "%s", br_pem_decoder_name(&pc));
                der.n = 0;
                br_pem_decoder_setdest(&pc, buf_append, &der);
                inObj = 1;
                break;
            case BR_PEM_END_OBJ:
                if (inObj && der.p) fn(ctx, name, der.p, der.n);
                inObj = 0;
                break;
            case BR_PEM_ERROR:
                br_pem_decoder_init(&pc);  /* objeto roto: se salta */
                inObj = 0;
                break;
            default:
                break;
        }
    }
    free(der.p);
}

static int read_file(const char* path, unsigned char** out, size_t* outLen) {
    FILE* f = fopen(path, "rb");
    if (!f) return 0;
    ft_buf b = {0};
    unsigned char tmp[8192];
    size_t k;
    while ((k = fread(tmp, 1, sizeof tmp, f)) > 0) buf_append(&b, tmp, k);
    fclose(f);
    *out = b.p;
    *outLen = b.n;
    return b.p != NULL;
}

static int is_cert_name(const char* name) {
    return strcmp(name, "CERTIFICATE") == 0 || strcmp(name, "X509 CERTIFICATE") == 0 ||
           strcmp(name, "TRUSTED CERTIFICATE") == 0;
}

static void pem_to_anchor(void* ctx, const char* name, const unsigned char* der, size_t n) {
    if (is_cert_name(name)) anchors_add_der((ft_anchors*)ctx, der, n);
}

static int anchors_load_file(ft_anchors* a, const char* path) {
    unsigned char* data;
    size_t len;
    if (!read_file(path, &data, &len)) return 0;
    size_t before = a->n;
    pem_each(data, len, pem_to_anchor, a);
    free(data);
    return a->n > before;
}

static void anchors_load_dir(ft_anchors* a, const char* dir) {
    DIR* d = opendir(dir);
    if (!d) return;
    struct dirent* e;
    char path[1024];
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
        anchors_load_file(a, path);
    }
    closedir(d);
}

/* Autoridades del sistema (una vez por proceso). SSL_CERT_FILE / SSL_CERT_DIR las sustituyen. */
static void sys_anchors_load(void) {
    const char* envFile = getenv("SSL_CERT_FILE");
    const char* envDir = getenv("SSL_CERT_DIR");
    if (envFile && *envFile) anchors_load_file(&g_sys, envFile);
    if (envDir && *envDir) anchors_load_dir(&g_sys, envDir);
    if (g_sys.n > 0) return;
#if defined(__ANDROID__)
    static const char* const dirs[] = {"/apex/com.android.conscrypt/cacerts", "/system/etc/security/cacerts"};
    for (size_t i = 0; i < sizeof dirs / sizeof dirs[0] && g_sys.n == 0; i++) anchors_load_dir(&g_sys, dirs[i]);
#else
    static const char* const files[] = {"/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt",
                                        "/etc/ssl/ca-bundle.pem", "/etc/ssl/cert.pem"};
    for (size_t i = 0; i < sizeof files / sizeof files[0] && g_sys.n == 0; i++) anchors_load_file(&g_sys, files[i]);
    if (g_sys.n == 0) anchors_load_dir(&g_sys, "/etc/ssl/certs");
#endif
}

/* ---- validador sin verificación */

static void nv_dn(void* ctx, const void* buf, size_t len) { (void)ctx; (void)buf; (void)len; }

static void nv_start_chain(const br_x509_class** ctx, const char* server_name) {
    (void)server_name;
    ((ft_noverify*)(void*)ctx)->depth = 0;
}

static void nv_start_cert(const br_x509_class** ctx, uint32_t length) {
    ft_noverify* x = (ft_noverify*)(void*)ctx;
    (void)length;
    if (x->depth == 0) br_x509_decoder_init(&x->dc, nv_dn, NULL);
}

static void nv_append(const br_x509_class** ctx, const unsigned char* buf, size_t len) {
    ft_noverify* x = (ft_noverify*)(void*)ctx;
    if (x->depth == 0) br_x509_decoder_push(&x->dc, buf, len);
}

static void nv_end_cert(const br_x509_class** ctx) { ((ft_noverify*)(void*)ctx)->depth++; }

static unsigned nv_end_chain(const br_x509_class** ctx) {
    ft_noverify* x = (ft_noverify*)(void*)ctx;
    return br_x509_decoder_get_pkey(&x->dc) ? 0 : BR_ERR_X509_EMPTY_CHAIN;
}

static const br_x509_pkey* nv_get_pkey(const br_x509_class* const* ctx, unsigned* usages) {
    ft_noverify* x = (ft_noverify*)(void*)ctx;
    if (usages) *usages = BR_KEYTYPE_KEYX | BR_KEYTYPE_SIGN;
    return br_x509_decoder_get_pkey(&x->dc);
}

static const br_x509_class nv_vtable = {
    sizeof(ft_noverify), nv_start_chain, nv_start_cert, nv_append, nv_end_cert, nv_end_chain, nv_get_pkey,
};

/* ---- motor */

static const char* b_suite_name(unsigned s) {
    switch (s) {
        case 0xC02B: return "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256";
        case 0xC02C: return "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384";
        case 0xC02F: return "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256";
        case 0xC030: return "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384";
        case 0xCCA8: return "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256";
        case 0xCCA9: return "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256";
        case 0xC023: return "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256";
        case 0xC027: return "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256";
        case 0xC009: return "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA";
        case 0xC013: return "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA";
        case 0x009C: return "TLS_RSA_WITH_AES_128_GCM_SHA256";
        case 0x009D: return "TLS_RSA_WITH_AES_256_GCM_SHA384";
        default: return NULL;
    }
}

/* Traduce br_ssl_engine_last_error. */
static int b_error(ft_tls* t, const char* what) {
    int err = br_ssl_engine_last_error(t->be.b->eng);
    switch (err) {
        case BR_ERR_X509_EXPIRED: return ft_cert_fail(t, err, "ha caducado o aún no es válido");
        case BR_ERR_X509_BAD_SERVER_NAME: return ft_cert_fail(t, err, "se emitió para otro nombre de equipo");
        case BR_ERR_X509_NOT_TRUSTED: return ft_cert_fail(t, err, "no lo firma ninguna autoridad de confianza");
        case BR_ERR_X509_NOT_CA: return ft_cert_fail(t, err, "lo firma un certificado que no es de una autoridad");
        case BR_ERR_X509_BAD_SIGNATURE: return ft_cert_fail(t, err, "la firma no es válida");
        case BR_ERR_X509_TIME_UNKNOWN: return ft_cert_fail(t, err, "no se conoce la fecha actual");
        case BR_ERR_X509_WEAK_PUBLIC_KEY: return ft_cert_fail(t, err, "su clave es demasiado débil");
        case BR_ERR_X509_FORBIDDEN_KEY_USAGE: return ft_cert_fail(t, err, "no sirve para identificar un servidor");
        default: break;
    }
    if (err >= BR_ERR_X509_OK && err < 64) {
        char why[64];
        snprintf(why, sizeof why, "error de X.509 %d (BearSSL)", err);
        return ft_cert_fail(t, err, why);
    }
    if (err >= BR_ERR_RECV_FATAL_ALERT && err < BR_ERR_SEND_FATAL_ALERT) {
        int alert = err - BR_ERR_RECV_FATAL_ALERT;
        if (alert == 70 || alert == 71)
            return ft_fail(t, FT_TLS, err, "%s: el otro extremo no admite TLS 1.2 (alerta %d)", what, alert);
        return ft_fail(t, FT_TLS, err, "%s: el otro extremo envió la alerta TLS %d", what, alert);
    }
    if (err >= BR_ERR_SEND_FATAL_ALERT)
        return ft_fail(t, FT_TLS, err, "%s: alerta TLS %d", what, err - BR_ERR_SEND_FATAL_ALERT);
    if (err == BR_ERR_OK) return ft_fail(t, FT_CLOSED, 0, "%s: el otro extremo cerró la conexión", what);
    return ft_fail(t, FT_TLS, err, "%s (código de BearSSL %d)", what, err);
}

/* Hace avanzar el motor hasta que su estado tenga algún bit de 'target'.
   1 = listo, 0 = motor cerrado (ver last_error), -2 = el socket se cerró, -1 = error de E/S. */
static int b_run(ft_tls* t, unsigned target, int timeoutMs) {
    br_ssl_engine_context* eng = t->be.b->eng;
    for (;;) {
        unsigned st = br_ssl_engine_current_state(eng);
        if (st & BR_SSL_CLOSED) return 0;
        if (st & BR_SSL_SENDREC) {
            size_t len;
            unsigned char* buf = br_ssl_engine_sendrec_buf(eng, &len);
            if (ft_send_all(t, buf, len, timeoutMs) < 0) return -1;
            br_ssl_engine_sendrec_ack(eng, len);
            continue;
        }
        if (st & target) return 1;
        if ((st & BR_SSL_RECVAPP) && (target & BR_SSL_SENDAPP)) {
            /* hay datos sin leer y el motor no acepta más para enviar */
            return ft_fail(t, FT_TLS, 0, "llegaron datos sin leer antes de poder enviar");
        }
        if (st & BR_SSL_RECVREC) {
            size_t len;
            unsigned char* buf = br_ssl_engine_recvrec_buf(eng, &len);
            int n = ft_recv_some(t, buf, len, timeoutMs);
            if (n < 0) return -1;
            if (n == 0) return -2;
            br_ssl_engine_recvrec_ack(eng, (size_t)n);
            continue;
        }
        br_ssl_engine_flush(eng, 0);
    }
}

static int b_handshake(ft_tls* t, int timeoutMs) {
    int r = b_run(t, BR_SSL_SENDAPP | BR_SSL_RECVAPP, timeoutMs);
    if (r == -1) return -1;
    if (r == -2) return ft_fail(t, FT_CLOSED, 0, "el otro extremo cerró la conexión durante la negociación TLS");
    if (r == 0) return b_error(t, "fallo en la negociación TLS");
    br_ssl_engine_context* eng = t->be.b->eng;
    unsigned v = br_ssl_engine_get_version(eng);
    snprintf(t->proto, sizeof t->proto, "%s", v == BR_TLS12 ? "TLSv1.2" : v == BR_TLS11 ? "TLSv1.1" : "TLSv1.0");
    const char* s = b_suite_name(eng->session.cipher_suite);
    if (s) snprintf(t->cipher, sizeof t->cipher, "%s", s);
    else snprintf(t->cipher, sizeof t->cipher, "0x%04X", eng->session.cipher_suite);
    return 0;
}

static int b_alloc(ft_tls* t) {
    t->be.b = (ft_bearssl*)calloc(1, sizeof(ft_bearssl));
    if (!t->be.b) return ft_fail(t, FT_TLS, 0, "sin memoria para TLS");
    return 0;
}

static int be_client(ft_tls* t, const char* caFile, int timeoutMs) {
    if (b_alloc(t) < 0) return -1;
    ft_bearssl* b = t->be.b;
    if (t->verify && t->hostIsIp)
        return ft_fail(t, FT_UNAVAILABLE, 0,
                       "BearSSL no puede comprobar certificados emitidos para direcciones IP ('%s'): "
                       "conecta por nombre", t->host);
    size_t n = 0;
    if (t->verify) {
        pthread_once(&g_sys_once, sys_anchors_load);
        if (caFile && !anchors_load_file(&b->extra, caFile))
            return ft_fail(t, FT_ARG, 0, "no se pudo leer el archivo de autoridades '%s'", caFile);
        n = g_sys.n + b->extra.n;
        if (n == 0)
            return ft_fail(t, FT_CERT, 0, "no se encontraron las autoridades de confianza del sistema");
        b->all = (br_x509_trust_anchor*)malloc(n * sizeof *b->all);
        if (!b->all) return ft_fail(t, FT_TLS, 0, "sin memoria para TLS");
        if (g_sys.n) memcpy(b->all, g_sys.v, g_sys.n * sizeof *b->all);
        if (b->extra.n) memcpy(b->all + g_sys.n, b->extra.v, b->extra.n * sizeof *b->all);
    }
    br_ssl_client_init_full(&b->u.cc, &b->xc, b->all, n);
    b->eng = &b->u.cc.eng;
    if (!t->verify) {
        b->nv.vtable = &nv_vtable;
        br_ssl_engine_set_x509(b->eng, &b->nv.vtable);
    }
    br_ssl_engine_set_versions(b->eng, BR_TLS12, BR_TLS12);
    br_ssl_engine_set_buffer(b->eng, b->iobuf, sizeof b->iobuf, 1);
    if (!br_ssl_client_reset(&b->u.cc, t->hostIsIp || !t->host[0] ? NULL : t->host, 0))
        return b_error(t, "no se pudo iniciar TLS");
    return b_handshake(t, timeoutMs);
}

/* ---- servidor: certificado (cadena PEM) y clave privada PEM */

static void pem_to_chain(void* ctx, const char* name, const unsigned char* der, size_t n) {
    ft_bearssl* b = (ft_bearssl*)ctx;
    if (!is_cert_name(name)) return;
    br_x509_certificate* nc = (br_x509_certificate*)realloc(b->chain, (b->chainLen + 1) * sizeof *nc);
    if (!nc) return;
    b->chain = nc;
    nc[b->chainLen].data = (unsigned char*)ft_memdup(der, n);
    nc[b->chainLen].data_len = n;
    b->chainLen++;
}

typedef struct { br_skey_decoder_context* dc; int found; } ft_keyctx;

static void pem_to_key(void* ctx, const char* name, const unsigned char* der, size_t n) {
    ft_keyctx* k = (ft_keyctx*)ctx;
    if (k->found) return;
    if (strcmp(name, "PRIVATE KEY") && strcmp(name, "RSA PRIVATE KEY") && strcmp(name, "EC PRIVATE KEY")) return;
    br_skey_decoder_init(k->dc);
    br_skey_decoder_push(k->dc, der, n);
    k->found = br_skey_decoder_last_error(k->dc) == 0 && br_skey_decoder_key_type(k->dc) != 0;
}

static int be_server(ft_tls* t, const char* certFile, const char* keyFile, int timeoutMs) {
    if (b_alloc(t) < 0) return -1;
    ft_bearssl* b = t->be.b;
    unsigned char* data;
    size_t len;
    if (!read_file(certFile, &data, &len))
        return ft_fail(t, FT_ARG, 0, "no se pudo leer el certificado '%s' (PEM)", certFile);
    pem_each(data, len, pem_to_chain, b);
    free(data);
    if (b->chainLen == 0) return ft_fail(t, FT_ARG, 0, "no se pudo leer el certificado '%s' (PEM)", certFile);
    if (!read_file(keyFile, &data, &len))
        return ft_fail(t, FT_ARG, 0, "no se pudo leer la clave privada '%s' (PEM)", keyFile);
    ft_keyctx k = {&b->skey, 0};
    pem_each(data, len, pem_to_key, &k);
    free(data);
    if (!k.found) return ft_fail(t, FT_ARG, 0, "no se pudo leer la clave privada '%s' (PEM)", keyFile);
    int type = br_skey_decoder_key_type(&b->skey);
    if (type == BR_KEYTYPE_RSA) {
        br_ssl_server_init_full_rsa(&b->u.sc, b->chain, b->chainLen, br_skey_decoder_get_rsa(&b->skey));
    } else {
        br_x509_decoder_context dc;
        br_x509_decoder_init(&dc, nv_dn, NULL);
        br_x509_decoder_push(&dc, b->chain[0].data, b->chain[0].data_len);
        int issuer = br_x509_decoder_get_signer_key_type(&dc);
        br_ssl_server_init_full_ec(&b->u.sc, b->chain, b->chainLen, issuer ? issuer : BR_KEYTYPE_EC,
                                   br_skey_decoder_get_ec(&b->skey));
    }
    b->eng = &b->u.sc.eng;
    br_ssl_engine_set_versions(b->eng, BR_TLS12, BR_TLS12);
    br_ssl_engine_set_buffer(b->eng, b->iobuf, sizeof b->iobuf, 1);
    if (!br_ssl_server_reset(&b->u.sc)) return b_error(t, "no se pudo iniciar TLS");
    return b_handshake(t, timeoutMs);
}

static int be_send(ft_tls* t, const unsigned char* p, int n, int timeoutMs) {
    br_ssl_engine_context* eng = t->be.b->eng;
    int done = 0;
    while (done < n) {
        int r = b_run(t, BR_SSL_SENDAPP, timeoutMs);
        if (r == -1) return -1;
        if (r <= 0) return r == -2 ? ft_fail(t, FT_IO, 0, "el otro extremo cerró la conexión")
                                   : b_error(t, "error de TLS al enviar");
        size_t alen;
        unsigned char* buf = br_ssl_engine_sendapp_buf(eng, &alen);
        size_t k = (size_t)(n - done) < alen ? (size_t)(n - done) : alen;
        memcpy(buf, p + done, k);
        br_ssl_engine_sendapp_ack(eng, k);
        done += (int)k;
    }
    br_ssl_engine_flush(eng, 0);
    int r = b_run(t, BR_SSL_SENDAPP | BR_SSL_RECVAPP, timeoutMs);
    if (r == -1) return -1;
    if (r == 0) return b_error(t, "error de TLS al enviar");
    return n;
}

static int be_recv(ft_tls* t, unsigned char* p, int cap, int timeoutMs) {
    br_ssl_engine_context* eng = t->be.b->eng;
    int r = b_run(t, BR_SSL_RECVAPP, timeoutMs);
    if (r == -1) return -1;
    if (r == -2 || (r == 0 && br_ssl_engine_last_error(eng) == BR_ERR_OK)) {
        t->closed = 1;  /* close_notify, o fin del socket sin él (se trata como fin normal) */
        return 0;
    }
    if (r == 0) return b_error(t, "error de TLS al recibir");
    size_t alen;
    unsigned char* buf = br_ssl_engine_recvapp_buf(eng, &alen);
    size_t k = (size_t)cap < alen ? (size_t)cap : alen;
    memcpy(p, buf, k);
    br_ssl_engine_recvapp_ack(eng, k);
    return (int)k;
}

static int be_pending(ft_tls* t) {
    if (!t->be.b || !t->be.b->eng) return 0;
    size_t alen = 0;
    if (br_ssl_engine_current_state(t->be.b->eng) & BR_SSL_RECVAPP) br_ssl_engine_recvapp_buf(t->be.b->eng, &alen);
    return (int)alen;
}

static void be_close(ft_tls* t, int timeoutMs) {
    if (!t->be.b || !t->be.b->eng) return;
    br_ssl_engine_context* eng = t->be.b->eng;
    br_ssl_engine_close(eng);
    while (br_ssl_engine_current_state(eng) & BR_SSL_SENDREC) {  /* envía close_notify; no espera el del otro */
        size_t len;
        unsigned char* buf = br_ssl_engine_sendrec_buf(eng, &len);
        if (ft_send_all(t, buf, len, timeoutMs) < 0) break;
        br_ssl_engine_sendrec_ack(eng, len);
    }
}

static void be_free(ft_tls* t) {
    ft_bearssl* b = t->be.b;
    if (!b) return;
    anchors_free(&b->extra);
    free(b->all);
    for (size_t i = 0; i < b->chainLen; i++) free(b->chain[i].data);
    free(b->chain);
    memset(b, 0, sizeof *b);  /* borra las claves de sesión */
    free(b);
    t->be.b = NULL;
}

static const char* be_name(void) { return "BearSSL"; }
static int be_available(void) { return 1; }

#endif /* FT_BEARSSL */

/* =============================================================================
 *  Schannel (Windows)
 * ============================================================================= */
#if defined(FT_SCHANNEL)

#ifndef SEC_E_INVALID_PARAMETER
#  define SEC_E_INVALID_PARAMETER ((HRESULT)0x8009035DL)
#endif
#ifndef SCH_CRED_NO_DEFAULT_CREDS
#  define SCH_CRED_NO_DEFAULT_CREDS 0x00000010
#endif

static const char* s_reason(SECURITY_STATUS st) {
    switch ((unsigned long)st) {
        case 0x80090325UL: return "no lo firma ninguna autoridad de confianza";   /* SEC_E_UNTRUSTED_ROOT */
        case 0x800B0109UL: return "no lo firma ninguna autoridad de confianza";   /* CERT_E_UNTRUSTEDROOT */
        case 0x800B010AUL: return "no lo firma ninguna autoridad de confianza";   /* CERT_E_CHAINING */
        case 0x80090328UL: return "ha caducado o aún no es válido";             /* SEC_E_CERT_EXPIRED */
        case 0x800B0101UL: return "ha caducado o aún no es válido";             /* CERT_E_EXPIRED */
        case 0x80090322UL: return "se emitió para otro nombre de equipo";         /* SEC_E_WRONG_PRINCIPAL */
        case 0x800B010FUL: return "se emitió para otro nombre de equipo";         /* CERT_E_CN_NO_MATCH */
        case 0x80092010UL: return "está revocado";                               /* CRYPT_E_REVOKED */
        case 0x800B010CUL: return "está revocado";                               /* CERT_E_REVOKED */
        case 0x80090327UL: return "no se pudo validar";                          /* SEC_E_CERT_UNKNOWN */
        case 0x800B0110UL: return "no sirve para identificar un servidor";        /* CERT_E_WRONG_USAGE */
        default: return NULL;
    }
}

static int s_error(ft_tls* t, SECURITY_STATUS st, const char* what) {
    const char* why = s_reason(st);
    if (why) return ft_cert_fail(t, (int)st, why);
    if ((unsigned long)st == 0x80090331UL)  /* SEC_E_ALGORITHM_MISMATCH */
        return ft_fail(t, FT_TLS, (int)st, "%s: no hay ningún cifrado o versión de TLS en común", what);
    return ft_fail(t, FT_TLS, (int)st, "%s (SECURITY_STATUS 0x%08lX)", what, (unsigned long)st);
}

static int s_grow(unsigned char** p, size_t* cap, size_t need) {
    if (need <= *cap) return 1;
    size_t c = *cap ? *cap : 4096;
    while (c < need) c *= 2;
    unsigned char* np = (unsigned char*)realloc(*p, c);
    if (!np) return 0;
    *p = np;
    *cap = c;
    return 1;
}

/* Lee más datos cifrados del socket al final de 'in'. >0, 0 = fin, -1 = error. */
static int s_fill(ft_tls* t, int timeoutMs) {
    ft_backend* b = &t->be;
    if (!s_grow(&b->in, &b->inCap, b->inLen + FT_REC)) return ft_fail(t, FT_TLS, 0, "sin memoria para TLS");
    int n = ft_recv_some(t, b->in + b->inLen, FT_REC, timeoutMs);
    if (n > 0) b->inLen += (size_t)n;
    return n;
}

static int s_send_token(ft_tls* t, SecBuffer* sb, int timeoutMs) {
    int r = 0;
    if (sb->pvBuffer && sb->cbBuffer > 0) r = ft_send_all(t, (unsigned char*)sb->pvBuffer, sb->cbBuffer, timeoutMs);
    if (sb->pvBuffer) FreeContextBuffer(sb->pvBuffer);
    sb->pvBuffer = NULL;
    sb->cbBuffer = 0;
    return r;
}

#define S_ISC_FLAGS (ISC_REQ_SEQUENCE_DETECT | ISC_REQ_REPLAY_DETECT | ISC_REQ_CONFIDENTIALITY | \
                     ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_STREAM | ISC_REQ_EXTENDED_ERROR)

/* Bucle de negociación (también para SEC_I_RENEGOTIATE de TLS 1.3); usa lo que haya en 'in'. */
static int s_handshake_loop(ft_tls* t, int timeoutMs) {
    ft_backend* b = &t->be;
    int needData = b->inLen == 0;
    for (;;) {
        if (needData) {
            int n = s_fill(t, timeoutMs);
            if (n < 0) return -1;
            if (n == 0) return ft_fail(t, FT_CLOSED, 0, "el otro extremo cerró la conexión durante la negociación TLS");
        }
        SecBuffer inb[2], outb[2];
        SecBufferDesc ind, outd;
        inb[0].BufferType = SECBUFFER_TOKEN;
        inb[0].pvBuffer = b->in;
        inb[0].cbBuffer = (unsigned long)b->inLen;
        inb[1].BufferType = SECBUFFER_EMPTY;
        inb[1].pvBuffer = NULL;
        inb[1].cbBuffer = 0;
        ind.ulVersion = SECBUFFER_VERSION;
        ind.cBuffers = 2;
        ind.pBuffers = inb;
        outb[0].BufferType = SECBUFFER_TOKEN;
        outb[0].pvBuffer = NULL;
        outb[0].cbBuffer = 0;
        outb[1].BufferType = SECBUFFER_ALERT;
        outb[1].pvBuffer = NULL;
        outb[1].cbBuffer = 0;
        outd.ulVersion = SECBUFFER_VERSION;
        outd.cBuffers = 2;
        outd.pBuffers = outb;
        unsigned long outFlags = 0;
        SECURITY_STATUS st = InitializeSecurityContextW(&b->cred, &b->ctx, b->whost[0] ? b->whost : NULL, S_ISC_FLAGS, 0, 0,
                                                        &ind, 0, NULL, &outd, &outFlags, NULL);
        if (st == SEC_E_INCOMPLETE_MESSAGE) {
            needData = 1;
            continue;
        }
        if (st == SEC_E_OK || st == SEC_I_CONTINUE_NEEDED || FAILED(st)) {
            /* el token de salida (o la alerta de un fallo) se envía siempre */
            if (s_send_token(t, &outb[0], timeoutMs) < 0) {
                if (outb[1].pvBuffer) FreeContextBuffer(outb[1].pvBuffer);
                return -1;
            }
        }
        if (outb[0].pvBuffer) FreeContextBuffer(outb[0].pvBuffer);
        if (outb[1].pvBuffer) FreeContextBuffer(outb[1].pvBuffer);
        if (inb[1].BufferType == SECBUFFER_EXTRA && inb[1].cbBuffer > 0) {
            memmove(b->in, b->in + (b->inLen - inb[1].cbBuffer), inb[1].cbBuffer);
            b->inLen = inb[1].cbBuffer;
        } else if (st != SEC_E_INCOMPLETE_MESSAGE) {
            b->inLen = 0;
        }
        if (st == SEC_E_OK) return 0;
        if (st == SEC_I_CONTINUE_NEEDED || st == SEC_I_INCOMPLETE_CREDENTIALS) {
            needData = b->inLen == 0;
            continue;
        }
        return s_error(t, st, "fallo en la negociación TLS");
    }
}

static void s_info(ft_tls* t) {
    SecPkgContext_ConnectionInfo ci;
    memset(&ci, 0, sizeof ci);
    if (QueryContextAttributesW(&t->be.ctx, SECPKG_ATTR_CONNECTION_INFO, &ci) == SEC_E_OK) {
        DWORD p = ci.dwProtocol;
        const char* name = (p & SP_PROT_TLS1_3) ? "TLSv1.3" : (p & SP_PROT_TLS1_2) ? "TLSv1.2"
                         : (p & SP_PROT_TLS1_1) ? "TLSv1.1" : "TLS";
        snprintf(t->proto, sizeof t->proto, "%s", name);
    }
    SecPkgContext_CipherInfo info;
    memset(&info, 0, sizeof info);
    info.dwVersion = SECPKGCONTEXT_CIPHERINFO_V1;
    if (QueryContextAttributesW(&t->be.ctx, SECPKG_ATTR_CIPHER_INFO, &info) == SEC_E_OK)
        WideCharToMultiByte(CP_UTF8, 0, info.szCipherSuite, -1, t->cipher, sizeof t->cipher, NULL, NULL);
}

static int be_client(ft_tls* t, const char* caFile, int timeoutMs) {
    ft_backend* b = &t->be;
    if (caFile)
        return ft_fail(t, FT_UNAVAILABLE, 0,
                       "CertificateAuthorityFile no está disponible en Windows: instala la autoridad en el "
                       "almacén de certificados de Windows");
    if (t->host[0] && !MultiByteToWideChar(CP_UTF8, 0, t->host, -1, b->whost, 256))
        return ft_fail(t, FT_ARG, 0, "nombre de equipo no válido para TLS: '%s'", t->host);
    DWORD flags = SCH_USE_STRONG_CRYPTO | SCH_CRED_NO_DEFAULT_CREDS;
    if (t->verify) flags |= SCH_CRED_AUTO_CRED_VALIDATION;
    else flags |= SCH_CRED_MANUAL_CRED_VALIDATION | SCH_CRED_NO_SERVERNAME_CHECK;
    TimeStamp expiry;
    /* SCH_CREDENTIALS (Windows 10 1809+) permite TLS 1.3; si no existe, SCHANNEL_CRED con TLS 1.2. */
    TLS_PARAMETERS tp;
    SCH_CREDENTIALS sc;
    memset(&tp, 0, sizeof tp);
    memset(&sc, 0, sizeof sc);
    tp.grbitDisabledProtocols = (DWORD)~(SP_PROT_TLS1_2_CLIENT | SP_PROT_TLS1_3_CLIENT);
    sc.dwVersion = SCH_CREDENTIALS_VERSION;
    sc.dwFlags = flags;
    sc.cTlsParameters = 1;
    sc.pTlsParameters = &tp;
    SECURITY_STATUS st = AcquireCredentialsHandleW(NULL, (LPWSTR)UNISP_NAME_W, SECPKG_CRED_OUTBOUND, NULL, &sc, NULL, NULL,
                                                   &b->cred, &expiry);
    if (st != SEC_E_OK) {
        SCHANNEL_CRED old;
        memset(&old, 0, sizeof old);
        old.dwVersion = SCHANNEL_CRED_VERSION;
        old.grbitEnabledProtocols = SP_PROT_TLS1_2_CLIENT;
        old.dwFlags = flags;
        st = AcquireCredentialsHandleW(NULL, (LPWSTR)UNISP_NAME_W, SECPKG_CRED_OUTBOUND, NULL, &old, NULL, NULL, &b->cred,
                                       &expiry);
    }
    if (st != SEC_E_OK) return s_error(t, st, "no se pudo iniciar Schannel");
    b->hasCred = 1;

    /* Primer mensaje (ClientHello), sin datos de entrada. */
    SecBuffer outb;
    SecBufferDesc outd;
    outb.BufferType = SECBUFFER_TOKEN;
    outb.pvBuffer = NULL;
    outb.cbBuffer = 0;
    outd.ulVersion = SECBUFFER_VERSION;
    outd.cBuffers = 1;
    outd.pBuffers = &outb;
    unsigned long outFlags = 0;
    st = InitializeSecurityContextW(&b->cred, NULL, b->whost[0] ? b->whost : NULL, S_ISC_FLAGS, 0, 0, NULL, 0, &b->ctx,
                                    &outd, &outFlags, NULL);
    if (st != SEC_I_CONTINUE_NEEDED) {
        if (outb.pvBuffer) FreeContextBuffer(outb.pvBuffer);
        return s_error(t, st, "no se pudo iniciar la negociación TLS");
    }
    b->hasCtx = 1;
    if (s_send_token(t, &outb, timeoutMs) < 0) return -1;
    if (s_handshake_loop(t, timeoutMs) < 0) return -1;
    st = QueryContextAttributesW(&b->ctx, SECPKG_ATTR_STREAM_SIZES, &b->sizes);
    if (st != SEC_E_OK) return s_error(t, st, "fallo en la negociación TLS");
    b->out = (unsigned char*)malloc(b->sizes.cbHeader + b->sizes.cbMaximumMessage + b->sizes.cbTrailer);
    if (!b->out) return ft_fail(t, FT_TLS, 0, "sin memoria para TLS");
    s_info(t);
    return 0;
}

static int be_server(ft_tls* t, const char* certFile, const char* keyFile, int timeoutMs) {
    (void)certFile;
    (void)keyFile;
    (void)timeoutMs;
    return ft_fail(t, FT_UNAVAILABLE, 0, "TLS de servidor (AuthenticateAsServer) no está disponible en Windows");
}

static int be_send(ft_tls* t, const unsigned char* p, int n, int timeoutMs) {
    ft_backend* b = &t->be;
    int done = 0;
    while (done < n) {
        unsigned long chunk = (unsigned long)(n - done);
        if (chunk > b->sizes.cbMaximumMessage) chunk = b->sizes.cbMaximumMessage;
        SecBuffer sb[4];
        SecBufferDesc d;
        sb[0].BufferType = SECBUFFER_STREAM_HEADER;
        sb[0].pvBuffer = b->out;
        sb[0].cbBuffer = b->sizes.cbHeader;
        sb[1].BufferType = SECBUFFER_DATA;
        sb[1].pvBuffer = b->out + b->sizes.cbHeader;
        sb[1].cbBuffer = chunk;
        sb[2].BufferType = SECBUFFER_STREAM_TRAILER;
        sb[2].pvBuffer = b->out + b->sizes.cbHeader + chunk;
        sb[2].cbBuffer = b->sizes.cbTrailer;
        sb[3].BufferType = SECBUFFER_EMPTY;
        sb[3].pvBuffer = NULL;
        sb[3].cbBuffer = 0;
        d.ulVersion = SECBUFFER_VERSION;
        d.cBuffers = 4;
        d.pBuffers = sb;
        memcpy(sb[1].pvBuffer, p + done, chunk);
        SECURITY_STATUS st = EncryptMessage(&b->ctx, 0, &d, 0);
        if (st != SEC_E_OK) return s_error(t, st, "error de TLS al enviar");
        if (ft_send_all(t, b->out, (size_t)sb[0].cbBuffer + sb[1].cbBuffer + sb[2].cbBuffer, timeoutMs) < 0) return -1;
        done += (int)chunk;
    }
    return n;
}

static int be_recv(ft_tls* t, unsigned char* p, int cap, int timeoutMs) {
    ft_backend* b = &t->be;
    for (;;) {
        if (b->decPos < b->decLen) {
            size_t k = b->decLen - b->decPos;
            if (k > (size_t)cap) k = (size_t)cap;
            memcpy(p, b->dec + b->decPos, k);
            b->decPos += k;
            return (int)k;
        }
        if (t->closed) return 0;
        if (b->inLen > 0) {
            SecBuffer sb[4];
            SecBufferDesc d;
            sb[0].BufferType = SECBUFFER_DATA;
            sb[0].pvBuffer = b->in;
            sb[0].cbBuffer = (unsigned long)b->inLen;
            for (int i = 1; i < 4; i++) {
                sb[i].BufferType = SECBUFFER_EMPTY;
                sb[i].pvBuffer = NULL;
                sb[i].cbBuffer = 0;
            }
            d.ulVersion = SECBUFFER_VERSION;
            d.cBuffers = 4;
            d.pBuffers = sb;
            SECURITY_STATUS st = DecryptMessage(&b->ctx, &d, 0, NULL);
            if (st == SEC_E_OK || st == SEC_I_RENEGOTIATE || st == SEC_I_CONTEXT_EXPIRED) {
                SecBuffer* data = NULL;
                SecBuffer* extra = NULL;
                for (int i = 1; i < 4; i++) {
                    if (sb[i].BufferType == SECBUFFER_DATA && !data) data = &sb[i];
                    if (sb[i].BufferType == SECBUFFER_EXTRA && !extra) extra = &sb[i];
                }
                b->decPos = b->decLen = 0;
                if (data && data->cbBuffer > 0) {  /* el texto está dentro de 'in': se copia antes de moverlo */
                    if (!s_grow(&b->dec, &b->decCap, data->cbBuffer)) return ft_fail(t, FT_TLS, 0, "sin memoria para TLS");
                    memcpy(b->dec, data->pvBuffer, data->cbBuffer);
                    b->decLen = data->cbBuffer;
                }
                if (extra && extra->cbBuffer > 0) {
                    memmove(b->in, (unsigned char*)extra->pvBuffer, extra->cbBuffer);
                    b->inLen = extra->cbBuffer;
                } else {
                    b->inLen = 0;
                }
                if (st == SEC_I_CONTEXT_EXPIRED) t->closed = 1;  /* close_notify */
                if (st == SEC_I_RENEGOTIATE) {
                    /* TLS 1.3: mensajes posteriores a la negociación (NewSessionTicket, KeyUpdate) */
                    if (s_handshake_loop(t, timeoutMs) < 0) return -1;
                }
                continue;
            }
            if (st != SEC_E_INCOMPLETE_MESSAGE) return s_error(t, st, "error de TLS al recibir");
        }
        int n = s_fill(t, timeoutMs);
        if (n < 0) return -1;
        if (n == 0) {  /* fin sin close_notify: se trata como fin normal */
            t->closed = 1;
            return 0;
        }
    }
}

static int be_pending(ft_tls* t) { return (int)(t->be.decLen - t->be.decPos); }

static void be_close(ft_tls* t, int timeoutMs) {
    ft_backend* b = &t->be;
    if (!b->hasCtx) return;
    DWORD type = SCHANNEL_SHUTDOWN;
    SecBuffer sb;
    SecBufferDesc d;
    sb.BufferType = SECBUFFER_TOKEN;
    sb.pvBuffer = &type;
    sb.cbBuffer = sizeof type;
    d.ulVersion = SECBUFFER_VERSION;
    d.cBuffers = 1;
    d.pBuffers = &sb;
    if (ApplyControlToken(&b->ctx, &d) != SEC_E_OK) return;
    SecBuffer outb;
    SecBufferDesc outd;
    outb.BufferType = SECBUFFER_TOKEN;
    outb.pvBuffer = NULL;
    outb.cbBuffer = 0;
    outd.ulVersion = SECBUFFER_VERSION;
    outd.cBuffers = 1;
    outd.pBuffers = &outb;
    unsigned long outFlags = 0;
    SECURITY_STATUS st = InitializeSecurityContextW(&b->cred, &b->ctx, b->whost[0] ? b->whost : NULL, S_ISC_FLAGS, 0, 0,
                                                    NULL, 0, NULL, &outd, &outFlags, NULL);
    if (st == SEC_E_OK || st == SEC_I_CONTINUE_NEEDED) s_send_token(t, &outb, timeoutMs);
    else if (outb.pvBuffer) FreeContextBuffer(outb.pvBuffer);
}

static void be_free(ft_tls* t) {
    ft_backend* b = &t->be;
    if (b->hasCtx) DeleteSecurityContext(&b->ctx);
    if (b->hasCred) FreeCredentialsHandle(&b->cred);
    b->hasCtx = b->hasCred = 0;
    free(b->in);
    free(b->dec);
    free(b->out);
    b->in = b->dec = b->out = NULL;
}

static const char* be_name(void) { return "Schannel"; }
static int be_available(void) { return 1; }

#endif /* FT_SCHANNEL */

/* =============================================================================
 *  Interfaz para Faset (lib/std/net.fst, clase TlsStream)
 * ============================================================================= */

void* faset_tls_new(int64_t sock) {
    ft_tls* t = (ft_tls*)calloc(1, sizeof(ft_tls));
    if (!t) return NULL;
    t->sock = sock;
    return t;
}

void faset_tls_free(void* p) {
    ft_tls* t = (ft_tls*)p;
    if (!t) return;
    be_free(t);
    memset(t, 0, sizeof *t);
    free(t);
}

/* Negociación como cliente: SNI y verificación del nombre con 'host' (vacío = sin nombre). */
int32_t faset_tls_client(void* p, ft_str host, int32_t verify, ft_str caFile, int32_t timeoutMs) {
    ft_tls* t = (ft_tls*)p;
    if (!t) return -1;
    ft_clear(t);
    if (t->ready || t->kind) return ft_fail(t, FT_ARG, 0, "la conexión TLS ya está negociada");
    if (!ft_cstr(host, t->host, sizeof t->host)) return ft_fail(t, FT_ARG, 0, "nombre de equipo no válido para TLS");
    /* IPv6 entre corchetes: [::1] -> ::1 */
    size_t hl = strlen(t->host);
    if (hl >= 2 && t->host[0] == '[' && t->host[hl - 1] == ']') {
        memmove(t->host, t->host + 1, hl - 2);
        t->host[hl - 2] = 0;
    }
    if (verify && !t->host[0])
        return ft_fail(t, FT_ARG, 0, "hace falta el nombre del equipo para verificar su certificado");
    t->hostIsIp = t->host[0] && ft_is_ip(t->host);
    t->verify = verify != 0;
    t->server = 0;
    char* ca = ft_dup(caFile);
    int r = be_client(t, ca, timeoutMs);
    free(ca);
    if (r == 0) t->ready = 1;
    return r;
}

/* Negociación como servidor con un certificado (cadena PEM) y su clave privada PEM. */
int32_t faset_tls_server(void* p, ft_str certFile, ft_str keyFile, int32_t timeoutMs) {
    ft_tls* t = (ft_tls*)p;
    if (!t) return -1;
    ft_clear(t);
    if (t->ready) return ft_fail(t, FT_ARG, 0, "la conexión TLS ya está negociada");
    char* cert = ft_dup(certFile);
    char* key = ft_dup(keyFile);
    t->server = 1;
    int r = cert && key ? be_server(t, cert, key, timeoutMs)
                        : ft_fail(t, FT_ARG, 0, "faltan el certificado o la clave privada");
    free(cert);
    free(key);
    if (r == 0) t->ready = 1;
    return r;
}

/* Cifra y envía todos los bytes: devuelve 'length' o -1. */
int32_t faset_tls_send(void* p, const uint8_t* data, int32_t length, int32_t timeoutMs) {
    ft_tls* t = (ft_tls*)p;
    if (!t) return -1;
    ft_clear(t);
    if (!t->ready) return ft_fail(t, FT_ARG, 0, "la conexión TLS no está negociada");
    if (length <= 0) return 0;
    return be_send(t, data, length, timeoutMs);
}

/* Recibe texto descifrado: >0 bytes, 0 = el otro extremo terminó, -1 = error. */
int32_t faset_tls_recv(void* p, uint8_t* buffer, int32_t capacity, int32_t timeoutMs) {
    ft_tls* t = (ft_tls*)p;
    if (!t) return -1;
    ft_clear(t);
    if (!t->ready) return ft_fail(t, FT_ARG, 0, "la conexión TLS no está negociada");
    if (capacity <= 0) return 0;
    return be_recv(t, buffer, capacity, timeoutMs);
}

/* Bytes ya descifrados que se pueden leer sin tocar el socket. */
int32_t faset_tls_pending(void* p) {
    ft_tls* t = (ft_tls*)p;
    return t && t->ready ? be_pending(t) : 0;
}

/* Envía close_notify (no espera la respuesta). El socket no se cierra. */
void faset_tls_shutdown(void* p, int32_t timeoutMs) {
    ft_tls* t = (ft_tls*)p;
    if (!t || !t->ready) return;
    be_close(t, timeoutMs);
    t->ready = 0;
}

int32_t faset_tls_error_kind(void* p) { return p ? ((ft_tls*)p)->kind : FT_TLS; }
int32_t faset_tls_native_error(void* p) { return p ? ((ft_tls*)p)->native : 0; }
const char* faset_tls_error_text(void* p) { return p ? ((ft_tls*)p)->msg : "sin memoria para TLS"; }
const char* faset_tls_protocol(void* p) { return p ? ((ft_tls*)p)->proto : ""; }
const char* faset_tls_cipher(void* p) { return p ? ((ft_tls*)p)->cipher : ""; }

/* Nombre del motor ("OpenSSL (libssl.so.3)", "Schannel", "BearSSL") y si se puede usar. */
const char* faset_tls_backend(void) { return be_name(); }
int32_t faset_tls_available(void) { return be_available(); }
