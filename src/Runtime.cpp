#include "Runtime.h"

const char* const kRuntimeHeader = R"FASET(
#include <stdint.h>
#include <stddef.h>

#if defined(_WIN32)
#  define FASET_EXPORT __declspec(dllexport)
#else
#  define FASET_EXPORT __attribute__((visibility("default")))
#endif

typedef struct faset_string { const uint8_t* ptr; int64_t len; } faset_string;
#define FASET_STR(s, n) ((faset_string){ (const uint8_t*)(s), (int64_t)(n) })

void faset_rt_init(int argc, char** argv);
void faset_rt_exit(void);
void* faset_alloc_zeroed(int64_t size);
void faset_free(void* p);
_Bool faset_str_eq(faset_string a, faset_string b);
int32_t faset_str_cmp(faset_string a, faset_string b);

/* ---- seguridad de memoria
   FASET_CHECKS=1 (Debug por defecto, o <RuntimeChecks>true</RuntimeChecks> / --checks):
   cada objeto de clase lleva una cabecera con un número mágico que 'delete' invalida, y el
   código generado comprueba referencias nulas, objetos ya liberados, índices de cadenas,
   divisiones enteras por cero y punteros a función nulos. Un fallo termina con
     Faset panic: <mensaje> at archivo.fst:línea
   en stderr y código de salida 101 (FASET_PANIC_ABORT=1 llama a abort() para depurar). */
#if !defined(FASET_CHECKS)
#  define FASET_CHECKS 0
#endif
#if defined(__GNUC__) || defined(__clang__)
#  define FASET_UNLIKELY(x) __builtin_expect(!!(x), 0)
#  define FASET_NORETURN __attribute__((noreturn))
#  define FASET_CHECK_FN static inline __attribute__((always_inline))
#else
#  define FASET_UNLIKELY(x) (x)
#  define FASET_NORETURN
#  define FASET_CHECK_FN static inline
#endif

void* faset_obj_alloc(int64_t size);
_Bool faset_obj_delete_begin(void* p, const char* file, int32_t line);
void faset_obj_delete_end(void* p);
FASET_NORETURN void faset_panic_at(faset_string msg, const char* file, int32_t line);
FASET_NORETURN void faset_panic_msg(const char* msg, const char* file, int32_t line);

#if FASET_CHECKS
typedef struct faset_obj_hdr { uint64_t magic; uint64_t size; } faset_obj_hdr;
#define FASET_OBJ_LIVE 0x4A424F5445534146ULL /* "FASETOBJ" */
#define FASET_OBJ_DEAD 0xDEADDEADFA5E7DEDULL
FASET_NORETURN void faset_panic_obj(void* p, const char* file, int32_t line);
FASET_NORETURN void faset_panic_index(int64_t i, int64_t len, const char* file, int32_t line);

/* Referencia a objeto: no nula y no liberada con 'delete'. */
FASET_CHECK_FN void* faset_chk_obj(void* p, const char* f, int32_t l) {
    if (FASET_UNLIKELY(!p || ((faset_obj_hdr*)p)[-1].magic != FASET_OBJ_LIVE)) faset_panic_obj(p, f, l);
    return p;
}
FASET_CHECK_FN void* faset_chk_fn(void* p, const char* f, int32_t l) {
    if (FASET_UNLIKELY(!p)) faset_panic_msg("llamada a través de un puntero a función nulo", f, l);
    return p;
}
FASET_CHECK_FN uint8_t faset_str_at(faset_string s, int64_t i, const char* f, int32_t l) {
    if (FASET_UNLIKELY((uint64_t)i >= (uint64_t)s.len)) faset_panic_index(i, s.len, f, l);
    return s.ptr[i];
}
#define FASET_DIV_FN(T, N, MIN)                                                                       \
    FASET_CHECK_FN T faset_div_##N(T a, T b, const char* f, int32_t l) {                                \
        if (FASET_UNLIKELY(b == 0)) faset_panic_msg("división entera por cero", f, l);                  \
        if (MIN && FASET_UNLIKELY(b == (T)-1 && a == (T)MIN)) faset_panic_msg("desbordamiento en la división entera", f, l); \
        return a / b;                                                                                 \
    }                                                                                                 \
    FASET_CHECK_FN T faset_mod_##N(T a, T b, const char* f, int32_t l) {                                \
        if (FASET_UNLIKELY(b == 0)) faset_panic_msg("división entera por cero (operador %)", f, l);     \
        if (MIN && FASET_UNLIKELY(b == (T)-1)) return 0;                                              \
        return a % b;                                                                                 \
    }
FASET_DIV_FN(int32_t, i32, INT32_MIN)
FASET_DIV_FN(int64_t, i64, INT64_MIN)
FASET_DIV_FN(uint32_t, u32, 0)
FASET_DIV_FN(uint64_t, u64, 0)
/* Divisor de '/=' y '%=': solo se comprueba el cero. */
FASET_CHECK_FN int64_t faset_divisor_i64(int64_t b, const char* f, int32_t l) {
    if (FASET_UNLIKELY(b == 0)) faset_panic_msg("división entera por cero", f, l);
    return b;
}
FASET_CHECK_FN uint64_t faset_divisor_u64(uint64_t b, const char* f, int32_t l) {
    if (FASET_UNLIKELY(b == 0)) faset_panic_msg("división entera por cero", f, l);
    return b;
}
#endif
)FASET";

const char* const kRuntimeSource = R"FASET(
/* Runtime de Faset. */
#define __USE_MINGW_ANSI_STDIO 1
#define _DEFAULT_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <sys/stat.h>
#if defined(_WIN32)
#  include <windows.h>
#  include <direct.h>
#else
#  include <unistd.h>
#  include <dirent.h>
#  include <fcntl.h>
#  include <poll.h>
#  include <signal.h>
#  include <sys/wait.h>
#endif
#include "faset_rt.h"
#if !defined(S_ISDIR)
#  define S_ISDIR(m) (((m) & S_IFMT) == S_IFDIR)
#endif

static int faset_argc;
static char** faset_argv;

void faset_rt_init(int argc, char** argv) {
    faset_argc = argc;
    faset_argv = argv;
#if defined(_WIN32)
    SetConsoleOutputCP(65001); /* UTF-8 */
#endif
}

void faset_rt_exit(void) { fflush(stdout); }

static void faset_oom(void) {
    fputs("faset: sin memoria\n", stderr);
    abort();
}

void* faset_alloc(int64_t size) {
    void* p = malloc((size_t)(size > 0 ? size : 1));
    if (!p) faset_oom();
    return p;
}

void* faset_alloc_zeroed(int64_t size) {
    void* p = calloc(1, (size_t)(size > 0 ? size : 1));
    if (!p) faset_oom();
    return p;
}

void* faset_realloc(void* p, int64_t size) {
    void* q = realloc(p, (size_t)(size > 0 ? size : 1));
    if (!q) faset_oom();
    return q;
}

void faset_free(void* p) { free(p); }

/* ---- objetos de clase ('new' / 'delete') */
#if FASET_CHECKS
/* Cuarentena: los objetos liberados no se devuelven enseguida a malloc, para que un uso
   posterior encuentre la cabecera marcada como liberada (y no memoria reutilizada). */
#define FASET_QUAR_SLOTS 4096
#define FASET_QUAR_BYTES ((int64_t)64 << 20)
static faset_obj_hdr* faset_quar[FASET_QUAR_SLOTS];
static int faset_quar_head, faset_quar_count;
static int64_t faset_quar_bytes;
static volatile char faset_quar_lock;

void* faset_obj_alloc(int64_t size) {
    faset_obj_hdr* h = (faset_obj_hdr*)faset_alloc_zeroed((int64_t)sizeof(faset_obj_hdr) + (size > 0 ? size : 1));
    h->magic = FASET_OBJ_LIVE;
    h->size = (uint64_t)size;
    return h + 1;
}

_Bool faset_obj_delete_begin(void* p, const char* file, int32_t line) {
    if (!p) return 0;
    faset_obj_hdr* h = (faset_obj_hdr*)p - 1;
    if (h->magic == FASET_OBJ_DEAD) faset_panic_msg("'delete' doble: el objeto ya se había liberado", file, line);
    if (h->magic != FASET_OBJ_LIVE)
        faset_panic_msg("'delete' de una referencia que no apunta a un objeto creado con 'new'", file, line);
    return 1;
}

void faset_obj_delete_end(void* p) {
    faset_obj_hdr* h = (faset_obj_hdr*)p - 1;
    h->magic = FASET_OBJ_DEAD;
    while (__atomic_test_and_set(&faset_quar_lock, __ATOMIC_ACQUIRE)) {}
    while (faset_quar_count > 0 &&
           (faset_quar_count == FASET_QUAR_SLOTS || faset_quar_bytes + (int64_t)h->size > FASET_QUAR_BYTES)) {
        faset_obj_hdr* old = faset_quar[faset_quar_head];
        faset_quar_head = (faset_quar_head + 1) % FASET_QUAR_SLOTS;
        faset_quar_count--;
        faset_quar_bytes -= (int64_t)old->size;
        free(old);
    }
    faset_quar[(faset_quar_head + faset_quar_count) % FASET_QUAR_SLOTS] = h;
    faset_quar_count++;
    faset_quar_bytes += (int64_t)h->size;
    __atomic_clear(&faset_quar_lock, __ATOMIC_RELEASE);
}
#else
void* faset_obj_alloc(int64_t size) { return faset_alloc_zeroed(size); }
_Bool faset_obj_delete_begin(void* p, const char* file, int32_t line) { (void)file; (void)line; return p != 0; }
void faset_obj_delete_end(void* p) { free(p); }
#endif
void faset_mem_copy(void* dst, const void* src, int64_t n) { if (n > 0) memmove(dst, src, (size_t)n); }
void faset_mem_set(void* dst, int32_t v, int64_t n) { if (n > 0) memset(dst, v, (size_t)n); }
int32_t faset_mem_compare(const void* a, const void* b, int64_t n) { return n > 0 ? memcmp(a, b, (size_t)n) : 0; }

/* ---- cadenas */

_Bool faset_str_eq(faset_string a, faset_string b) {
    return a.len == b.len && (a.len == 0 || memcmp(a.ptr, b.ptr, (size_t)a.len) == 0);
}

int32_t faset_str_cmp(faset_string a, faset_string b) {
    int64_t n = a.len < b.len ? a.len : b.len;
    int c = n > 0 ? memcmp(a.ptr, b.ptr, (size_t)n) : 0;
    if (c != 0) return c < 0 ? -1 : 1;
    return a.len == b.len ? 0 : (a.len < b.len ? -1 : 1);
}

static faset_string faset_str_alloc(int64_t len) {
    uint8_t* p = (uint8_t*)faset_alloc(len + 1);
    p[len] = 0;
    faset_string s = { p, len };
    return s;
}

faset_string faset_str_concat(faset_string a, faset_string b) {
    faset_string s = faset_str_alloc(a.len + b.len);
    if (a.len) memcpy((void*)s.ptr, a.ptr, (size_t)a.len);
    if (b.len) memcpy((void*)(s.ptr + a.len), b.ptr, (size_t)b.len);
    return s;
}

faset_string faset_str_copy(faset_string a) {
    faset_string s = faset_str_alloc(a.len);
    if (a.len) memcpy((void*)s.ptr, a.ptr, (size_t)a.len);
    return s;
}

faset_string faset_str_from_cstr(const uint8_t* p) {
    faset_string s = { p, p ? (int64_t)strlen((const char*)p) : 0 };
    return s;
}

void faset_str_free(faset_string s) { free((void*)s.ptr); }

static faset_string faset_str_from_buf(const char* buf) {
    faset_string s = faset_str_alloc((int64_t)strlen(buf));
    memcpy((void*)s.ptr, buf, (size_t)s.len);
    return s;
}

/* Formato estilo C#: representación más corta que conserva el valor;
   notación decimal salvo para exponentes muy grandes o pequeños. */
static void faset_fmt_double(char* buf, size_t cap, double v, int maxPrec) {
    if (v != v) { snprintf(buf, cap, "NaN"); return; }
    if (v > 1.7976931348623157e308) { snprintf(buf, cap, "\xE2\x88\x9E"); return; }
    if (v < -1.7976931348623157e308) { snprintf(buf, cap, "-\xE2\x88\x9E"); return; }
    if (v == 0) { snprintf(buf, cap, (1.0 / v) < 0 ? "-0" : "0"); return; }
    char tmp[64];
    int prec = 1;
    for (; prec <= maxPrec; prec++) {
        snprintf(tmp, sizeof tmp, "%.*e", prec - 1, v);
        double back = strtod(tmp, NULL);
        if (maxPrec == 9 ? (float)back == (float)v : back == v) break;
    }
    if (prec > maxPrec) prec = maxPrec;
    const char* e = strchr(tmp, 'e');
    int exp = e ? atoi(e + 1) : 0;
    if (exp > -5 && exp < 15) {
        int dec = prec - 1 - exp;
        snprintf(buf, cap, "%.*f", dec < 0 ? 0 : dec, v);
    } else {
        snprintf(buf, cap, "%.*E", prec - 1, v);
    }
}

faset_string faset_i64_to_str(int64_t v) {
    char buf[32];
    snprintf(buf, sizeof buf, "%lld", (long long)v);
    return faset_str_from_buf(buf);
}

faset_string faset_f64_to_str(double v) {
    char buf[64];
    faset_fmt_double(buf, sizeof buf, v, 17);
    return faset_str_from_buf(buf);
}

/* ---- consola */

void faset_write_str(faset_string s) { if (s.len) fwrite(s.ptr, 1, (size_t)s.len, stdout); }
void faset_write_i64(int64_t v) { printf("%lld", (long long)v); }
void faset_write_u64(uint64_t v) { printf("%llu", (unsigned long long)v); }
void faset_write_ptr(void* p) { printf("0x%llx", (unsigned long long)(uintptr_t)p); }

void faset_write_f64(double v) {
    char buf[64];
    faset_fmt_double(buf, sizeof buf, v, 17);
    fputs(buf, stdout);
}

void faset_write_f32(float v) {
    char buf[64];
    faset_fmt_double(buf, sizeof buf, (double)v, 9);
    fputs(buf, stdout);
}

void faset_write_char(uint32_t c) {
    char b[4];
    int n;
    if (c < 0x80) { b[0] = (char)c; n = 1; }
    else if (c < 0x800) { b[0] = (char)(0xC0 | (c >> 6)); b[1] = (char)(0x80 | (c & 0x3F)); n = 2; }
    else if (c < 0x10000) {
        b[0] = (char)(0xE0 | (c >> 12)); b[1] = (char)(0x80 | ((c >> 6) & 0x3F)); b[2] = (char)(0x80 | (c & 0x3F)); n = 3;
    } else {
        b[0] = (char)(0xF0 | (c >> 18)); b[1] = (char)(0x80 | ((c >> 12) & 0x3F));
        b[2] = (char)(0x80 | ((c >> 6) & 0x3F)); b[3] = (char)(0x80 | (c & 0x3F)); n = 4;
    }
    fwrite(b, 1, (size_t)n, stdout);
}

void faset_flush(void) { fflush(stdout); }

faset_string faset_read_line(void) {
    fflush(stdout);
    size_t cap = 64, len = 0;
    char* buf = (char*)faset_alloc((int64_t)cap);
    int c;
    while ((c = fgetc(stdin)) != EOF && c != '\n') {
        if (len + 1 >= cap) { cap *= 2; buf = (char*)faset_realloc(buf, (int64_t)cap); }
        buf[len++] = (char)c;
    }
    if (len > 0 && buf[len - 1] == '\r') len--;
    buf[len] = 0;
    faset_string s = { (const uint8_t*)buf, (int64_t)len };
    return s;
}


/* ---- errores */

/* Un 'panic' termina el programa con código 101 (FASET_PANIC_ABORT=1: abort(), para depurar). */
static FASET_NORETURN void faset_panic_exit(void) {
    fflush(stderr);
    const char* a = getenv("FASET_PANIC_ABORT");
    if (a && *a && *a != '0') abort();
    exit(101);
}

void faset_panic(faset_string msg) {
    fflush(stdout);
    fputs("Faset panic: ", stderr);
    if (msg.len) fwrite(msg.ptr, 1, (size_t)msg.len, stderr);
    fputc('\n', stderr);
    faset_panic_exit();
}

void faset_panic_at(faset_string msg, const char* file, int32_t line) {
    fflush(stdout);
    fputs("Faset panic: ", stderr);
    if (msg.len) fwrite(msg.ptr, 1, (size_t)msg.len, stderr);
    fprintf(stderr, " at %s:%d\n", file ? file : "?", (int)line);
    faset_panic_exit();
}

void faset_panic_msg(const char* msg, const char* file, int32_t line) {
    faset_panic_at(faset_str_from_cstr((const uint8_t*)msg), file, line);
}

#if FASET_CHECKS
void faset_panic_obj(void* p, const char* file, int32_t line) {
    if (!p) faset_panic_msg("referencia nula (null): el objeto no existe", file, line);
    if (((faset_obj_hdr*)p)[-1].magic == FASET_OBJ_DEAD)
        faset_panic_msg("uso de un objeto después de 'delete'", file, line);
    faset_panic_msg("referencia no válida: no apunta a un objeto creado con 'new'", file, line);
}

void faset_panic_index(int64_t i, int64_t len, const char* file, int32_t line) {
    char buf[96];
    snprintf(buf, sizeof buf, "índice fuera de rango: %lld (longitud %lld)", (long long)i, (long long)len);
    faset_panic_msg(buf, file, line);
}
#endif

void faset_write_err_str(faset_string s) { if (s.len) fwrite(s.ptr, 1, (size_t)s.len, stderr); }

/* ---- cadenas: utilidades */

faset_string faset_str_make(const uint8_t* p, int64_t len) {
    faset_string s = { p, len };
    return s;
}

faset_string faset_u64_to_str(uint64_t v) {
    char buf[32];
    snprintf(buf, sizeof buf, "%llu", (unsigned long long)v);
    return faset_str_from_buf(buf);
}

/* Copia temporal terminada en '\0' (para llamar a APIs de C). */
static char* faset_cstr(faset_string s) {
    char* p = (char*)faset_alloc(s.len + 1);
    if (s.len) memcpy(p, s.ptr, (size_t)s.len);
    p[s.len] = 0;
    return p;
}

_Bool faset_parse_i64(faset_string s, int64_t* out) {
    char* c = faset_cstr(s);
    char* end = NULL;
    errno = 0;
    long long v = strtoll(c, &end, 10);
    _Bool ok = s.len > 0 && end && *end == 0 && errno == 0;
    if (ok) *out = (int64_t)v;
    free(c);
    return ok;
}

_Bool faset_parse_f64(faset_string s, double* out) {
    char* c = faset_cstr(s);
    char* end = NULL;
    double v = strtod(c, &end);
    _Bool ok = s.len > 0 && end && *end == 0;
    if (ok) *out = v;
    free(c);
    return ok;
}

/* ---- archivos */

faset_string faset_file_read_all(faset_string path, _Bool* ok) {
    faset_string r = { 0, 0 };
    char* p = faset_cstr(path);
    FILE* f = fopen(p, "rb");
    free(p);
    if (ok) *ok = 0;
    if (!f) return r;
    size_t cap = 4096, len = 0;
    uint8_t* buf = (uint8_t*)faset_alloc((int64_t)cap);
    size_t n;
    while ((n = fread(buf + len, 1, cap - len - 1, f)) > 0) {
        len += n;
        if (len + 1 >= cap) { cap *= 2; buf = (uint8_t*)faset_realloc(buf, (int64_t)cap); }
    }
    fclose(f);
    buf[len] = 0;
    r.ptr = buf;
    r.len = (int64_t)len;
    if (ok) *ok = 1;
    return r;
}

_Bool faset_file_write(faset_string path, faset_string data, _Bool append) {
    char* p = faset_cstr(path);
    FILE* f = fopen(p, append ? "ab" : "wb");
    free(p);
    if (!f) return 0;
    _Bool ok = data.len == 0 || fwrite(data.ptr, 1, (size_t)data.len, f) == (size_t)data.len;
    return fclose(f) == 0 && ok;
}

_Bool faset_file_exists(faset_string path) {
    char* p = faset_cstr(path);
    struct stat st;
    _Bool r = stat(p, &st) == 0 && !S_ISDIR(st.st_mode);
    free(p);
    return r;
}

_Bool faset_dir_exists(faset_string path) {
    char* p = faset_cstr(path);
    struct stat st;
    _Bool r = stat(p, &st) == 0 && S_ISDIR(st.st_mode);
    free(p);
    return r;
}

_Bool faset_file_delete(faset_string path) {
    char* p = faset_cstr(path);
    _Bool r = remove(p) == 0;
    free(p);
    return r;
}

_Bool faset_dir_create(faset_string path) {
    char* p = faset_cstr(path);
#if defined(_WIN32)
    _Bool r = _mkdir(p) == 0 || errno == EEXIST;
#else
    _Bool r = mkdir(p, 0755) == 0 || errno == EEXIST;
#endif
    free(p);
    return r;
}

/* ---- tiempo, entorno y procesos */

void faset_sleep_ms(int64_t ms) {
    if (ms <= 0) return;
#if defined(_WIN32)
    Sleep((DWORD)ms);
#else
    struct timespec ts = { (time_t)(ms / 1000), (long)((ms % 1000) * 1000000) };
    nanosleep(&ts, NULL);
#endif
}

int64_t faset_time_unix_ms(void) {
    struct timespec ts;
    timespec_get(&ts, TIME_UTC);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

faset_string faset_getenv(faset_string name) {
    char* p = faset_cstr(name);
    const char* v = getenv(p);
    free(p);
    if (!v) { faset_string e = { 0, 0 }; return e; }
    return faset_str_from_buf(v);
}

int32_t faset_system(faset_string cmd) {
    char* p = faset_cstr(cmd);
    fflush(stdout);
    int r = system(p);
    free(p);
    return (int32_t)r;
}


/* ---- directorios: "d nombre\nf nombre\n..." (copia; liberar con faset_str_free) */

faset_string faset_dir_list(faset_string path) {
    faset_string r = { 0, 0 };
    size_t cap = 256, len = 0;
    char* out = (char*)faset_alloc((int64_t)cap);
    char* p = faset_cstr(path);
#if defined(_WIN32)
    size_t n = strlen(p);
    char* pattern = (char*)faset_alloc((int64_t)n + 3);
    memcpy(pattern, p, n);
    memcpy(pattern + n, "\\*", 3);
    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pattern, &fd);
    free(pattern);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            const char* name = fd.cFileName;
            int dir = (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
#else
    DIR* d = opendir(p);
    if (d) {
        struct dirent* e;
        while ((e = readdir(d)) != NULL) {
            const char* name = e->d_name;
            int dir = 0;
            size_t pl = strlen(p), nl = strlen(name);
            char* full = (char*)faset_alloc((int64_t)(pl + nl + 2));
            memcpy(full, p, pl);
            full[pl] = '/';
            memcpy(full + pl + 1, name, nl + 1);
            struct stat st;
            if (stat(full, &st) == 0 && S_ISDIR(st.st_mode)) dir = 1;
            free(full);
#endif
            if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;
            size_t nl2 = strlen(name);
            while (len + nl2 + 4 > cap) { cap *= 2; out = (char*)faset_realloc(out, (int64_t)cap); }
            out[len++] = dir ? 'd' : 'f';
            out[len++] = ' ';
            memcpy(out + len, name, nl2);
            len += nl2;
            out[len++] = '\n';
#if defined(_WIN32)
        } while (FindNextFileA(h, &fd));
        FindClose(h);
    }
#else
        }
        closedir(d);
    }
#endif
    free(p);
    out[len] = 0;
    r.ptr = (const uint8_t*)out;
    r.len = (int64_t)len;
    return r;
}

faset_string faset_full_path(faset_string path) {
    char* p = faset_cstr(path);
    char buf[4096];
#if defined(_WIN32)
    char* r = _fullpath(buf, p, sizeof buf);
#else
    char* r = realpath(p, buf);
#endif
    faset_string s = r ? faset_str_from_buf(buf) : faset_str_copy(path);
    free(p);
    return s;
}

_Bool faset_path_move(faset_string from, faset_string to) {
    char* a = faset_cstr(from);
    char* b = faset_cstr(to);
    _Bool ok = rename(a, b) == 0;
    free(a);
    free(b);
    return ok;
}

/* Borra un archivo o una carpeta con todo su contenido. */
static _Bool faset_delete_tree(const char* p) {
    struct stat st;
    if (stat(p, &st) != 0) return 0;
    if (!S_ISDIR(st.st_mode)) return remove(p) == 0;
#if defined(_WIN32)
    size_t n = strlen(p);
    char* pattern = (char*)faset_alloc((int64_t)n + 3);
    memcpy(pattern, p, n);
    memcpy(pattern + n, "\\*", 3);
    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pattern, &fd);
    free(pattern);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            const char* name = fd.cFileName;
#else
    DIR* d = opendir(p);
    if (d) {
        struct dirent* e;
        while ((e = readdir(d)) != NULL) {
            const char* name = e->d_name;
#endif
            if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;
            size_t pl = strlen(p), nl = strlen(name);
            char* full = (char*)faset_alloc((int64_t)(pl + nl + 2));
            memcpy(full, p, pl);
            full[pl] = '/';
            memcpy(full + pl + 1, name, nl + 1);
            faset_delete_tree(full);
            free(full);
#if defined(_WIN32)
        } while (FindNextFileA(h, &fd));
        FindClose(h);
    }
    return _rmdir(p) == 0;
#else
        }
        closedir(d);
    }
    return rmdir(p) == 0;
#endif
}

_Bool faset_path_delete(faset_string path) {
    char* p = faset_cstr(path);
    _Bool ok = faset_delete_tree(p);
    free(p);
    return ok;
}

faset_string faset_get_cwd(void) {
    char buf[4096];
#if defined(_WIN32)
    if (!_getcwd(buf, sizeof buf)) buf[0] = 0;
#else
    if (!getcwd(buf, sizeof buf)) buf[0] = 0;
#endif
    return faset_str_from_buf(buf);
}

/* ---- procesos asíncronos (salida estándar y de error combinadas, lectura sin bloqueo) */

#define FASET_MAX_PROCS 64
typedef struct { int used; int fd; int exited; int code;
#if defined(_WIN32)
    HANDLE process; HANDLE pipe;
#else
    pid_t pid;
#endif
} faset_proc;
static faset_proc faset_procs[FASET_MAX_PROCS];

int64_t faset_proc_start(faset_string cmd, faset_string cwd) {
    int slot = -1;
    for (int i = 1; i < FASET_MAX_PROCS; i++) if (!faset_procs[i].used) { slot = i; break; }
    if (slot < 0) return -1;
    char* c = faset_cstr(cmd);
    char* dir = cwd.len ? faset_cstr(cwd) : NULL;
#if defined(_WIN32)
    SECURITY_ATTRIBUTES sa = { sizeof sa, NULL, TRUE };
    HANDLE rd, wr;
    if (!CreatePipe(&rd, &wr, &sa, 0)) { free(c); free(dir); return -1; }
    SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);
    STARTUPINFOA si; memset(&si, 0, sizeof si); si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES; si.hStdOutput = wr; si.hStdError = wr; si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    PROCESS_INFORMATION pi;
    size_t n = strlen(c);
    char* line = (char*)faset_alloc((int64_t)n + 16);
    memcpy(line, "cmd.exe /C ", 11); memcpy(line + 11, c, n + 1);
    BOOL ok = CreateProcessA(NULL, line, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, dir, &si, &pi);
    free(line); CloseHandle(wr);
    free(c); free(dir);
    if (!ok) { CloseHandle(rd); return -1; }
    CloseHandle(pi.hThread);
    faset_procs[slot].process = pi.hProcess;
    faset_procs[slot].pipe = rd;
#else
    int fds[2];
    if (pipe(fds) != 0) { free(c); free(dir); return -1; }
    fflush(stdout);
    pid_t pid = fork();
    if (pid < 0) { close(fds[0]); close(fds[1]); free(c); free(dir); return -1; }
    if (pid == 0) {
        setpgid(0, 0);
        dup2(fds[1], 1); dup2(fds[1], 2);
        close(fds[0]); close(fds[1]);
        if (dir && chdir(dir) != 0) _exit(127);
        execl("/bin/sh", "sh", "-c", c, (char*)NULL);
        _exit(127);
    }
    close(fds[1]);
    fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK);
    faset_procs[slot].pid = pid;
    faset_procs[slot].fd = fds[0];
    free(c); free(dir);
#endif
    faset_procs[slot].used = 1;
    faset_procs[slot].exited = 0;
    faset_procs[slot].code = -1;
    return slot;
}

/* Bytes leídos (>0), 0 si no hay datos ahora, -1 si la salida terminó. */
int32_t faset_proc_read(int64_t h, uint8_t* buf, int32_t cap) {
    if (h <= 0 || h >= FASET_MAX_PROCS || !faset_procs[h].used) return -1;
#if defined(_WIN32)
    DWORD avail = 0;
    if (!PeekNamedPipe(faset_procs[h].pipe, NULL, 0, NULL, &avail, NULL)) return -1;
    if (avail == 0) return 0;
    DWORD got = 0;
    if (!ReadFile(faset_procs[h].pipe, buf, (DWORD)(avail < (DWORD)cap ? avail : (DWORD)cap), &got, NULL)) return -1;
    return (int32_t)got;
#else
    ssize_t n = read(faset_procs[h].fd, buf, (size_t)cap);
    if (n > 0) return (int32_t)n;
    if (n == 0) return -1;
    return (errno == EAGAIN || errno == EWOULDBLOCK) ? 0 : -1;
#endif
}

/* -1 mientras sigue en ejecución; después, el código de salida. */
int32_t faset_proc_status(int64_t h) {
    if (h <= 0 || h >= FASET_MAX_PROCS || !faset_procs[h].used) return -2;
    faset_proc* p = &faset_procs[h];
    if (p->exited) return p->code;
#if defined(_WIN32)
    DWORD code;
    if (GetExitCodeProcess(p->process, &code) && code != STILL_ACTIVE) { p->exited = 1; p->code = (int)code; }
#else
    int status;
    if (waitpid(p->pid, &status, WNOHANG) == p->pid) {
        p->exited = 1;
        p->code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + (WIFSIGNALED(status) ? WTERMSIG(status) : 0);
    }
#endif
    return p->exited ? p->code : -1;
}

void faset_proc_kill(int64_t h) {
    if (h <= 0 || h >= FASET_MAX_PROCS || !faset_procs[h].used) return;
#if defined(_WIN32)
    TerminateProcess(faset_procs[h].process, 1);
#else
    kill(-faset_procs[h].pid, SIGKILL);
#endif
}

void faset_proc_close(int64_t h) {
    if (h <= 0 || h >= FASET_MAX_PROCS || !faset_procs[h].used) return;
#if defined(_WIN32)
    CloseHandle(faset_procs[h].pipe);
    CloseHandle(faset_procs[h].process);
#else
    close(faset_procs[h].fd);
    if (!faset_procs[h].exited) waitpid(faset_procs[h].pid, NULL, WNOHANG);
#endif
    memset(&faset_procs[h], 0, sizeof faset_procs[h]);
}

/* Espera hasta 'ms' milisegundos a que haya datos en un descriptor (bucles de eventos). */
_Bool faset_wait_fd(int32_t fd, int32_t ms) {
#if defined(_WIN32)
    (void)fd; Sleep((DWORD)(ms > 0 ? ms : 0)); return 0;
#else
    struct pollfd p = { fd, POLLIN, 0 };
    return poll(&p, 1, ms) > 0;
#endif
}

/* ---- entorno */

void faset_exit(int32_t code) { fflush(stdout); exit(code); }
int32_t faset_arg_count(void) { return faset_argc; }

faset_string faset_arg_get(int32_t i) {
    faset_string s = { 0, 0 };
    if (i >= 0 && i < faset_argc) s = faset_str_from_cstr((const uint8_t*)faset_argv[i]);
    return s;
}

int64_t faset_ticks_ms(void) {
#if defined(_WIN32)
    return (int64_t)GetTickCount64();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
#endif
}

int32_t faset_platform(void) {
#if defined(__ANDROID__)
    return 2;
#elif defined(_WIN32)
    return 1;
#elif defined(__APPLE__)
    return 3;
#elif defined(__linux__)
    return 0;
#else
    return 4;
#endif
}
)FASET";
