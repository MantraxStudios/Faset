// Faset - runtime de las excepciones (try / catch / finally / throw). El diseño está explicado en
// Exceptions.cpp. kRuntimeExcHeader se añade a faset_rt.h (lo ven el programa y el runtime) y
// kRuntimeExcSource al final de faset_rt.c (en la misma unidad que el resto del runtime).
#include "Runtime.h"

const char* const kRuntimeExcHeader = R"FASET(
/* ---- excepciones
   Cada 'try' declara un marco (faset_exc_frame) en la pila de C y lo enlaza en la pila de marcos del
   hilo (faset_exc_top, thread-local); 'throw' desapila el marco más cercano, guarda en él la excepción
   y hace longjmp. Los marcos están en la pila, así que el recolector ve la excepción en vuelo.
   Sin un marco, una excepción termina el programa como un panic (código 101). */
#include <setjmp.h>
#if defined(__MINGW32__) && defined(__x86_64__)
   /* MinGW x64: setjmp(b) es _setjmp(b, marco) y longjmp desenrolla con SEH (RtlUnwindEx) hasta
      ese marco; falla al cruzar marcos sin datos de desenrollado o devoluciones de llamada del
      sistema (un WndProc). Con marco nulo, longjmp solo restaura los registros, como en POSIX. */
#  define FASET_SETJMP(b) _setjmp((b), NULL)
#  define FASET_LONGJMP(b) longjmp(b, 1)
#elif defined(_WIN32)
#  define FASET_SETJMP(b) setjmp(b)
#  define FASET_LONGJMP(b) longjmp(b, 1)
#else
   /* _setjmp no guarda la máscara de señales (en bionic setjmp hace una llamada al sistema). */
#  define FASET_SETJMP(b) _setjmp(b)
#  define FASET_LONGJMP(b) _longjmp(b, 1)
#endif
/* La dirección de una variable 'volatile' escapa: el compilador no puede eliminar las escrituras
   que le lleguen por un puntero no volatile (ref/out) antes de un longjmp. */
#if defined(__GNUC__)
#  define FASET_ESCAPE(p) __asm__ __volatile__("" : : "r"((const volatile void*)(p)) : "memory")
#else
#  define FASET_ESCAPE(p) ((void)(p))
#endif
typedef struct faset_exc_type {
    const char* name;                    /* nombre de la clase */
    const struct faset_exc_type* base;   /* clase base (nulo en std.Exception) */
} faset_exc_type;
typedef struct faset_exc_frame {
    jmp_buf jb;
    struct faset_exc_frame* prev;
    void* obj;                  /* excepción atrapada (objeto de una clase de excepción) */
    const faset_exc_type* type; /* su tipo dinámico */
    const char* file;           /* dónde se lanzó */
    int32_t line;
} faset_exc_frame;
extern _Thread_local faset_exc_frame* faset_exc_top;
/* Entra en un try: FASET_TRY(marco) { cuerpo } else { la excepción está en marco.obj } */
#define FASET_TRY(f) (f).prev = faset_exc_top; faset_exc_top = &(f); if (FASET_SETJMP((f).jb) == 0)
FASET_NORETURN void faset_exc_throw(void* obj, const char* file, int32_t line, const char* where);
FASET_NORETURN void faset_exc_rethrow(faset_exc_frame* f);
FASET_NORETURN void faset_exc_rethrow_at(faset_exc_frame* f, const char* file, int32_t line, const char* where);
_Bool faset_exc_is(const faset_exc_type* t, const faset_exc_type* want);
void faset_exc_setup(const faset_exc_type* root, int64_t offType, int64_t offMsg, int64_t offInner, int64_t offTrace,
                     void* (*make)(int32_t kind, faset_string msg));
/* Errores del runtime: excepción si hay un 'try' en el hilo; si no, panic (igual que siempre). */
#define FASET_EXC_NULL 1     /* NullReferenceException */
#define FASET_EXC_INDEX 2    /* IndexOutOfRangeException */
#define FASET_EXC_DIVZERO 3  /* DivideByZeroException */
#define FASET_EXC_OVERFLOW 4 /* OverflowException */
FASET_NORETURN void faset_panic_rt(int32_t kind, const char* msg, const char* file, int32_t line);
)FASET";

const char* const kRuntimeExcSource = R"FASET(
/* ---- excepciones (ver faset_rt.h) */

_Thread_local faset_exc_frame* faset_exc_top;
static _Thread_local int faset_exc_main_thread;   /* el hilo que inicializó el programa */
static _Thread_local int faset_exc_reporting;     /* evita bucles si falla el informe */
static const faset_exc_type* faset_exc_root;
static int64_t fx_off_type, fx_off_msg, fx_off_inner, fx_off_trace;
static void* (*fx_make)(int32_t kind, faset_string msg);

#define FX_FIELD(o, off, T) (*(T*)((char*)(o) + (off)))

void faset_exc_setup(const faset_exc_type* root, int64_t offType, int64_t offMsg, int64_t offInner, int64_t offTrace,
                     void* (*make)(int32_t kind, faset_string msg)) {
    faset_exc_root = root;
    fx_off_type = offType;
    fx_off_msg = offMsg;
    fx_off_inner = offInner;
    fx_off_trace = offTrace;
    fx_make = make;
    faset_exc_main_thread = 1;
}

_Bool faset_exc_is(const faset_exc_type* t, const faset_exc_type* want) {
    /* Gancho de la jerarquía: hoy recorre las bases declaradas con [ExceptionBase]. */
    if (want == faset_exc_root) return 1;
    for (; t; t = t->base)
        if (t == want) return 1;
    return 0;
}

static const faset_exc_type* fx_type_of(void* obj) {
    const faset_exc_type* t = (const faset_exc_type*)(uintptr_t)FX_FIELD(obj, fx_off_type, uint64_t);
    return t ? t : faset_exc_root;
}

/* "   en Metodo (archivo.fst:12)" o "   en archivo.fst:12" */
static faset_string fx_where(const char* where, const char* file, int32_t line) {
    char buf[512];
    int n;
    if (where && *where) n = snprintf(buf, sizeof buf, "   en %s (%s:%d)", where, file ? file : "?", (int)line);
    else n = snprintf(buf, sizeof buf, "   en %s:%d", file ? file : "?", (int)line);
    if (n < 0) n = 0;
    if (n >= (int)sizeof buf) n = (int)sizeof buf - 1;
    return faset_str_copy(faset_str_make((const uint8_t*)buf, n));
}

static void fx_write(faset_string s) { if (s.len) fwrite(s.ptr, 1, (size_t)s.len, stderr); }

/* Excepción sin 'catch': informa y termina como un panic (código 101; FASET_PANIC_ABORT=1 aborta). */
static FASET_NORETURN void fx_uncaught(void* obj, const faset_exc_type* t, const char* file, int32_t line) {
    fflush(stdout);
    if (faset_exc_reporting++) faset_panic_exit();
    faset_string msg = FX_FIELD(obj, fx_off_msg, faset_string);
    fputs("Faset panic: ", stderr);
    fx_write(msg);
    fprintf(stderr, " at %s:%d\n", file ? file : "?", (int)line);
    fprintf(stderr, "Excepción no controlada%s: %s: ", faset_exc_main_thread ? "" : " en un hilo secundario", t->name);
    fx_write(msg);
    fputc('\n', stderr);
    void* inner = FX_FIELD(obj, fx_off_inner, void*);
    for (int depth = 0; inner && depth < 16; depth++) {
        fprintf(stderr, " ---> %s: ", fx_type_of(inner)->name);
        fx_write(FX_FIELD(inner, fx_off_msg, faset_string));
        fputc('\n', stderr);
        inner = FX_FIELD(inner, fx_off_inner, void*);
    }
    faset_string trace = FX_FIELD(obj, fx_off_trace, faset_string);
    if (trace.len) {
        fx_write(trace);
        fputc('\n', stderr);
    }
    faset_panic_exit();
}

/* Lleva la excepción al marco más cercano (o termina si no hay ninguno). */
static FASET_NORETURN void fx_unwind(void* obj, const faset_exc_type* t, const char* file, int32_t line) {
    faset_exc_frame* f = faset_exc_top;
    if (!f) fx_uncaught(obj, t, file, line);
    faset_exc_top = f->prev;
    f->obj = obj;
    f->type = t;
    f->file = file;
    f->line = line;
    FASET_LONGJMP(f->jb);
}

void faset_exc_throw(void* obj, const char* file, int32_t line, const char* where) {
    if (!obj) faset_panic_rt(FASET_EXC_NULL, "referencia nula (null): el objeto no existe", file, line);
    FX_FIELD(obj, fx_off_trace, faset_string) = fx_where(where, file, line);
    fx_unwind(obj, fx_type_of(obj), file, line);
}

void faset_exc_rethrow(faset_exc_frame* f) { fx_unwind(f->obj, f->type, f->file, f->line); }

/* throw; dentro de un catch: la misma excepción, con la línea del relanzamiento en StackTrace. */
void faset_exc_rethrow_at(faset_exc_frame* f, const char* file, int32_t line, const char* where) {
    faset_string* trace = &FX_FIELD(f->obj, fx_off_trace, faset_string);
    faset_string nl = { (const uint8_t*)"\n", 1 };
    *trace = faset_str_concat(trace->len ? faset_str_concat(*trace, nl) : *trace, fx_where(where, file, line));
    fx_unwind(f->obj, f->type, f->file, f->line);
}

/* Barrera: los destructores que ejecuta el recolector corren sin marcos 'try' visibles. */
void* faset_exc_barrier_enter(void) {
    faset_exc_frame* f = faset_exc_top;
    faset_exc_top = 0;
    return f;
}
void faset_exc_barrier_leave(void* saved) { faset_exc_top = (faset_exc_frame*)saved; }

void faset_panic_rt(int32_t kind, const char* msg, const char* file, int32_t line) {
    /* Solo si hay un 'try' en este hilo: sin él, el panic de siempre (y sin reservar memoria). */
    if (faset_exc_top && fx_make) {
        void* obj = fx_make(kind, faset_str_copy(faset_str_from_cstr((const uint8_t*)msg)));
        if (obj) faset_exc_throw(obj, file, line, 0);
    }
    faset_panic_msg(msg, file, line);
}
)FASET";
