/* =============================================================================
 *  Faset - std.sqlite: enlace con SQLite.
 *
 *  El compilador añade este archivo a todo programa que use 'using std.sqlite;' y enlaza
 *  la amalgamación de SQLite (lib/sqlite/sqlite3.c, dominio público), compilada una sola
 *  vez por compilador y arquitectura en modo serializado (SQLITE_THREADSAFE=1): una
 *  conexión se puede usar desde varios hilos (las tareas de ExecuteAsync / QueryAsync y
 *  los destructores que ejecuta el recolector).
 *
 *  La mayoría de las funciones de SQLite se llaman directamente desde Faset con 'extern'
 *  (lib/std/sqlite.fst); aquí solo están las que reciben o devuelven cadenas de Faset
 *  ({puntero, longitud}) o necesitan constantes de C (SQLITE_TRANSIENT).
 * ============================================================================= */
#include <stdint.h>
#include <string.h>
#include "sqlite3.h"

typedef struct { const uint8_t* ptr; int64_t len; } fs_str;

void* faset_alloc_atomic(int64_t size);

/* Copia en memoria del recolector (terminada en 0). */
static fs_str fs_copy(const void* p, int64_t n) {
    fs_str s;
    uint8_t* d = (uint8_t*)faset_alloc_atomic(n + 1);
    if (n > 0) memcpy(d, p, (size_t)n);
    d[n] = 0;
    s.ptr = d;
    s.len = n;
    return s;
}

/* Abre la base de datos. flags: 1 = solo lectura, 2 = no crear si no existe. */
int32_t faset_sqlite_open(fs_str path, int32_t flags, void** db) {
    char buf[4096];
    if (path.len >= (int64_t)sizeof buf) return SQLITE_CANTOPEN;
    memcpy(buf, path.ptr, (size_t)path.len);
    buf[path.len] = 0;
    int f = SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI;
    if (flags & 1) f |= SQLITE_OPEN_READONLY;
    else f |= SQLITE_OPEN_READWRITE | ((flags & 2) ? 0 : SQLITE_OPEN_CREATE);
    sqlite3* h = NULL;
    int rc = sqlite3_open_v2(buf, &h, f, NULL);
    *db = h;
    if (rc == SQLITE_OK) {
        sqlite3_extended_result_codes(h, 1);
        sqlite3_busy_timeout(h, 5000);  /* espera hasta 5 s si otra conexión tiene el bloqueo */
    }
    return rc;
}

/* Prepara la primera sentencia de 'sql' a partir del byte 'offset'; devuelve en '*next' dónde
 * empieza la siguiente ('*stmt' es NULL si solo quedaban espacios o comentarios). */
int32_t faset_sqlite_prepare(void* db, fs_str sql, int64_t offset, void** stmt, int64_t* next) {
    const char* start = (const char*)sql.ptr + offset;
    const char* tail = NULL;
    sqlite3_stmt* st = NULL;
    int64_t n = sql.len - offset;
    int rc = sqlite3_prepare_v3((sqlite3*)db, start, n > 0x7fffffff ? 0x7fffffff : (int)n, 0, &st, &tail);
    *stmt = st;
    *next = tail ? offset + (tail - start) : sql.len;
    return rc;
}

int32_t faset_sqlite_bind_text(void* stmt, int32_t i, fs_str s) {
    return sqlite3_bind_text64((sqlite3_stmt*)stmt, i, (const char*)(s.ptr ? s.ptr : (const uint8_t*)""), (sqlite3_uint64)s.len,
                               SQLITE_TRANSIENT, SQLITE_UTF8);
}

int32_t faset_sqlite_bind_blob(void* stmt, int32_t i, fs_str s) {
    return sqlite3_bind_blob64((sqlite3_stmt*)stmt, i, s.ptr ? (const void*)s.ptr : (const void*)"", (sqlite3_uint64)s.len,
                               SQLITE_TRANSIENT);
}

/* Índice (desde 1) del parámetro 'name' o 0. Se prueba el nombre tal cual y, sin su prefijo,
 * con @, : y $ ("edad", "@edad" y ":edad" encuentran el mismo parámetro). */
int32_t faset_sqlite_param_index(void* stmt, fs_str name) {
    char buf[512];
    if (name.len <= 0 || name.len >= (int64_t)sizeof buf - 1) return 0;
    const uint8_t* p = name.ptr;
    int64_t n = name.len;
    char c = (char)p[0];
    if (c == '@' || c == ':' || c == '$' || c == '?') {
        memcpy(buf, p, (size_t)n);
        buf[n] = 0;
        int i = sqlite3_bind_parameter_index((sqlite3_stmt*)stmt, buf);
        if (i > 0 || c == '?') return i;
        p++;
        n--;
        if (n == 0) return 0;
    }
    static const char prefixes[3] = {'@', ':', '$'};
    for (int k = 0; k < 3; k++) {
        buf[0] = prefixes[k];
        memcpy(buf + 1, p, (size_t)n);
        buf[n + 1] = 0;
        int i = sqlite3_bind_parameter_index((sqlite3_stmt*)stmt, buf);
        if (i > 0) return i;
    }
    return 0;
}

fs_str faset_sqlite_column_text(void* stmt, int32_t i) {
    const unsigned char* p = sqlite3_column_text((sqlite3_stmt*)stmt, i);
    int n = sqlite3_column_bytes((sqlite3_stmt*)stmt, i);
    return fs_copy(p, p ? n : 0);
}

fs_str faset_sqlite_column_blob(void* stmt, int32_t i) {
    const void* p = sqlite3_column_blob((sqlite3_stmt*)stmt, i);
    int n = sqlite3_column_bytes((sqlite3_stmt*)stmt, i);
    return fs_copy(p, p ? n : 0);
}

fs_str faset_sqlite_cstr(const char* p) { return fs_copy(p ? p : "", p ? (int64_t)strlen(p) : 0); }
