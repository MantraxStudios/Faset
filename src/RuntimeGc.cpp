#include "Runtime.h"

// Recolector de basura de Faset: marcado y barrido conservador, con soporte de hilos.
// Se compila como faset_gc.c junto al programa (ver compileC en main.cpp).
const char* const kRuntimeGcSource = R"FASET(
/* Recolector de basura de Faset.

   - Montón propio en páginas de 64 KB por clases de tamaño (hasta 32 KB) y bloques grandes
     aparte, todos alineados a 64 KB; un mapa de dos niveles dice si una dirección es del montón.
   - Marcado conservador: cualquier palabra de las pilas, de los registros, de los datos
     globales del módulo o de un bloque vivo que apunte (aunque sea al interior) a un bloque lo
     mantiene vivo. Los bloques "atómicos" (cadenas, arrays sin punteros) no se recorren.
   - Hilos: cada hilo que ejecuta código Faset se registra; para recolectar se detienen todos
     (señales en POSIX, SuspendThread en Windows) y se recorren sus pilas.
   - Objetos con destructor: si dejan de ser alcanzables sin 'delete', el destructor se ejecuta
     después de la recolección (como un finalizador de C#) y el bloque se libera en la siguiente.
   - 'delete', String.Free y Memory.Free no liberan memoria del montón: nunca puede quedar
     una referencia colgando. La memoria se recupera cuando ya nadie la alcanza.

   Variables de entorno: FASET_GC_STATS=1 (una línea por recolección en stderr),
   FASET_GC=off (no recolectar nunca), FASET_GC_MIN_MB=N (umbral inicial, 16 por defecto). */
#if !defined(_WIN32)
#  define _GNU_SOURCE 1
#endif
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <setjmp.h>
#include <errno.h>
#include <time.h>
#if defined(_WIN32)
#  include <windows.h>
#else
#  include <sys/mman.h>
#  include <pthread.h>
#  include <signal.h>
#  include <semaphore.h>
#  include <unistd.h>
#  include <link.h>
#endif

#define GC_PAGE_SHIFT 16
#define GC_PAGE ((uintptr_t)1 << GC_PAGE_SHIFT)
#define GC_SMALL_MAX 32768
#define GC_BITS (GC_PAGE / 16 / 64)   /* palabras de 64 bits por mapa de bits de una página */
#define GC_NCLASS 36
#define GC_MAX_THREADS 1024
#define GC_NOINLINE __attribute__((noinline))

static const uint32_t gc_class_size[GC_NCLASS] = {
    16, 32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 640, 768,
    896, 1024, 1280, 1536, 1792, 2048, 2560, 3072, 3584, 4096, 5456, 6544, 8192, 10912,
    13104, 16384, 21840, 32768 };
static uint8_t gc_class_of[GC_SMALL_MAX / 16 + 1];

typedef struct gc_page {
    uintptr_t base;            /* primer byte de los bloques */
    uintptr_t size;            /* tamaño de bloque (pequeños) o del bloque grande */
    uintptr_t span;            /* bytes reservados (múltiplo de GC_PAGE) */
    uint32_t nblocks;
    uint32_t nfree;
    uint8_t cls, atomic, large, queued;
    void* freelist;
    struct gc_page* next;      /* todas las páginas */
    struct gc_page* next_free; /* páginas de su clase con bloques libres */
    uint64_t alloc[GC_BITS], mark[GC_BITS], fin[GC_BITS];
} gc_page;

typedef struct gc_thread {
    int active;
    uintptr_t stack_top;
    volatile uintptr_t sp;
#if defined(_WIN32)
    HANDLE handle;
    DWORD id;
#else
    pthread_t id;
#endif
} gc_thread;

typedef struct gc_range { uintptr_t lo, hi; } gc_range;

/* ---- estado (todo lo que apunta al montón vive fuera de él o es raíz explícita) */
static int gc_ready;
static int gc_disabled;
static int gc_stats;
static gc_page** gc_map;                 /* nivel 1: dirección >> 32 (65536 entradas) */
static uintptr_t gc_lo = ~(uintptr_t)0, gc_hi;
static gc_page* gc_pages;
static gc_page* gc_free_pages[2][GC_NCLASS];
static gc_page* gc_spare_desc;           /* descriptores reutilizables */
static uintptr_t gc_spare_pages[256];    /* páginas pequeñas vacías para reutilizar */
static int gc_spare_count;
static size_t gc_since, gc_threshold, gc_live, gc_heap_bytes, gc_min_threshold;
static uint64_t gc_count;
static gc_range gc_roots[64];
static int gc_nroots;
static gc_thread gc_threads[GC_MAX_THREADS];
static int gc_nthreads;
static uintptr_t* gc_stack;              /* pila de marcado: pares (inicio, fin) */
static size_t gc_stack_len, gc_stack_cap;
static void** gc_finq;                   /* objetos con destructor pendiente */
static size_t gc_finq_len, gc_finq_cap;
static void* volatile gc_pinned[64];     /* raíces temporales (argumentos de hilos nuevos) */
static int gc_in_collect;

#if defined(_WIN32)
static SRWLOCK gc_lock_ = SRWLOCK_INIT;
static void gc_lock(void) { AcquireSRWLockExclusive(&gc_lock_); }
static void gc_unlock(void) { ReleaseSRWLockExclusive(&gc_lock_); }
static DWORD gc_tls = TLS_OUT_OF_INDEXES;
static DWORD gc_fls = FLS_OUT_OF_INDEXES;
static gc_thread* gc_self_get(void) { return gc_tls == TLS_OUT_OF_INDEXES ? NULL : (gc_thread*)TlsGetValue(gc_tls); }
static void gc_self_set(gc_thread* t) { TlsSetValue(gc_tls, t); if (gc_fls != FLS_OUT_OF_INDEXES) FlsSetValue(gc_fls, t); }
#else
static pthread_mutex_t gc_lock_ = PTHREAD_MUTEX_INITIALIZER;
static void gc_lock(void) { pthread_mutex_lock(&gc_lock_); }
static void gc_unlock(void) { pthread_mutex_unlock(&gc_lock_); }
static __thread gc_thread* gc_self;
static gc_thread* gc_self_get(void) { return gc_self; }
static void gc_self_set(gc_thread* t) { gc_self = t; }
static pthread_key_t gc_key;
static sem_t gc_ack;
static volatile int gc_world_stopped;
static int gc_sig_suspend, gc_sig_resume;
#endif
static __thread int gc_running_finalizers;

static void gc_die(const char* msg) {
    fputs("faset: ", stderr);
    fputs(msg, stderr);
    fputc('\n', stderr);
    abort();
}

/* ---- memoria del sistema */

static void* gc_os_map(size_t n) {
#if defined(_WIN32)
    void* p = VirtualAlloc(NULL, n, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    return p;
#else
    void* p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return p == MAP_FAILED ? NULL : p;
#endif
}

static void gc_os_unmap(void* p, size_t n) {
#if defined(_WIN32)
    (void)n;
    VirtualFree(p, 0, MEM_RELEASE);
#else
    munmap(p, n);
#endif
}

/* n bytes (múltiplo de GC_PAGE) alineados a GC_PAGE. */
static void* gc_os_map_aligned(size_t n) {
#if defined(_WIN32)
    return gc_os_map(n); /* VirtualAlloc ya alinea a 64 KB */
#else
    uint8_t* p = (uint8_t*)gc_os_map(n + GC_PAGE);
    if (!p) return NULL;
    uintptr_t a = ((uintptr_t)p + GC_PAGE - 1) & ~(GC_PAGE - 1);
    size_t head = a - (uintptr_t)p, tail = GC_PAGE - head;
    if (head) munmap(p, head);
    if (tail) munmap((void*)(a + n), tail);
    return (void*)a;
#endif
}

/* ---- descriptores y mapa de páginas */

static gc_page* gc_desc_new(void) {
    if (!gc_spare_desc) {
        size_t n = 256;
        gc_page* d = (gc_page*)gc_os_map(sizeof(gc_page) * n);
        if (!d) gc_die("sin memoria");
        for (size_t i = 0; i < n; i++) { d[i].next = gc_spare_desc; gc_spare_desc = &d[i]; }
    }
    gc_page* d = gc_spare_desc;
    gc_spare_desc = d->next;
    memset(d, 0, sizeof *d);
    return d;
}

static void gc_desc_free(gc_page* d) { d->next = gc_spare_desc; gc_spare_desc = d; }

static gc_page** gc_map_slot(uintptr_t a, int create) {
#if UINTPTR_MAX > 0xFFFFFFFFu
    if (a >> 48) return NULL;
    uintptr_t i1 = a >> 32;
#else
    uintptr_t i1 = 0;
#endif
    gc_page** l2 = (gc_page**)gc_map[i1];
    if (!l2) {
        if (!create) return NULL;
        l2 = (gc_page**)gc_os_map(sizeof(gc_page*) * 65536);
        if (!l2) gc_die("sin memoria");
        gc_map[i1] = (gc_page*)l2;
    }
    return &l2[(a >> GC_PAGE_SHIFT) & 0xFFFF];
}

static void gc_map_set(uintptr_t base, uintptr_t span, gc_page* d) {
    for (uintptr_t a = base; a < base + span; a += GC_PAGE) *gc_map_slot(a, 1) = d;
    if (d) {
        if (base < gc_lo) gc_lo = base;
        if (base + span > gc_hi) gc_hi = base + span;
    }
}

static inline gc_page* gc_lookup(uintptr_t a) {
    if (a < gc_lo || a >= gc_hi) return NULL;
    gc_page** s = gc_map_slot(a, 0);
    return s ? *s : NULL;
}

#define GC_BIT(m, i) (((m)[(i) >> 6] >> ((i) & 63)) & 1)
#define GC_SET(m, i) ((m)[(i) >> 6] |= (uint64_t)1 << ((i) & 63))
#define GC_CLR(m, i) ((m)[(i) >> 6] &= ~((uint64_t)1 << ((i) & 63)))

/* ---- marcado */

static void gc_push(uintptr_t lo, uintptr_t hi) {
    if (gc_stack_len + 2 > gc_stack_cap) {
        size_t cap = gc_stack_cap ? gc_stack_cap * 2 : 65536;
        uintptr_t* s = (uintptr_t*)gc_os_map(cap * sizeof(uintptr_t));
        if (!s) gc_die("sin memoria para marcar");
        if (gc_stack) {
            memcpy(s, gc_stack, gc_stack_len * sizeof(uintptr_t));
            gc_os_unmap(gc_stack, gc_stack_cap * sizeof(uintptr_t));
        }
        gc_stack = s;
        gc_stack_cap = cap;
    }
    gc_stack[gc_stack_len++] = lo;
    gc_stack[gc_stack_len++] = hi;
}

static inline void gc_mark_word(uintptr_t a) {
    gc_page* d = gc_lookup(a);
    if (!d) return;
    if (a < d->base) return;
    uintptr_t i = d->large ? 0 : (a - d->base) / d->size;
    if (i >= d->nblocks || !GC_BIT(d->alloc, i) || GC_BIT(d->mark, i)) return;
    GC_SET(d->mark, i);
    if (!d->atomic) {
        uintptr_t lo = d->base + i * d->size;
        gc_push(lo, lo + d->size);
    }
}

static void gc_scan(uintptr_t lo, uintptr_t hi) {
    lo = (lo + sizeof(void*) - 1) & ~(uintptr_t)(sizeof(void*) - 1);
    for (uintptr_t p = lo; p + sizeof(void*) <= hi; p += sizeof(void*)) gc_mark_word(*(uintptr_t*)p);
}

static void gc_drain(void) {
    while (gc_stack_len) {
        uintptr_t hi = gc_stack[--gc_stack_len];
        uintptr_t lo = gc_stack[--gc_stack_len];
        gc_scan(lo, hi);
    }
}

/* ---- raíces globales: segmentos de datos escribibles de este módulo */

static int gc_module_marker;

#if defined(_WIN32)
static void gc_add_module_roots(void) {
    HMODULE m = NULL;
    if (!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            (LPCSTR)&gc_module_marker, &m) || !m) return;
    uint8_t* base = (uint8_t*)m;
    IMAGE_DOS_HEADER* dos = (IMAGE_DOS_HEADER*)base;
    IMAGE_NT_HEADERS* nt = (IMAGE_NT_HEADERS*)(base + dos->e_lfanew);
    IMAGE_SECTION_HEADER* sec = IMAGE_FIRST_SECTION(nt);
    for (int i = 0; i < nt->FileHeader.NumberOfSections && gc_nroots < 64; i++) {
        if (!(sec[i].Characteristics & IMAGE_SCN_MEM_WRITE)) continue;
        uintptr_t lo = (uintptr_t)base + sec[i].VirtualAddress;
        uintptr_t n = sec[i].Misc.VirtualSize;
        gc_roots[gc_nroots].lo = lo;
        gc_roots[gc_nroots].hi = lo + n;
        gc_nroots++;
    }
}
#else
static int gc_phdr_cb(struct dl_phdr_info* info, size_t size, void* data) {
    (void)size;
    (void)data;
    uintptr_t marker = (uintptr_t)&gc_module_marker;
    int mine = 0;
    for (int i = 0; i < info->dlpi_phnum; i++) {
        const ElfW(Phdr)* ph = &info->dlpi_phdr[i];
        if (ph->p_type != PT_LOAD) continue;
        uintptr_t lo = info->dlpi_addr + ph->p_vaddr;
        if (marker >= lo && marker < lo + ph->p_memsz) mine = 1;
    }
    if (!mine) return 0;
    for (int i = 0; i < info->dlpi_phnum && gc_nroots < 64; i++) {
        const ElfW(Phdr)* ph = &info->dlpi_phdr[i];
        if (ph->p_type != PT_LOAD || !(ph->p_flags & PF_W)) continue;
        uintptr_t lo = info->dlpi_addr + ph->p_vaddr;
        gc_roots[gc_nroots].lo = lo;
        gc_roots[gc_nroots].hi = lo + ph->p_memsz;
        gc_nroots++;
    }
    return 1;
}
static void gc_add_module_roots(void) { dl_iterate_phdr(gc_phdr_cb, NULL); }
#endif

/* ---- hilos */

static void gc_init(void);

#if defined(_WIN32)
static uintptr_t gc_current_stack_top(void) { return (uintptr_t)((NT_TIB*)NtCurrentTeb())->StackBase; }
static void WINAPI gc_fls_cb(void* p);
#else
static uintptr_t gc_current_stack_top(void) {
    pthread_attr_t attr;
    void* addr = NULL;
    size_t size = 0;
    if (pthread_getattr_np(pthread_self(), &attr) == 0) {
        pthread_attr_getstack(&attr, &addr, &size);
        pthread_attr_destroy(&attr);
    }
    if (addr) return (uintptr_t)addr + size;
    /* Sin información: el marco actual, redondeado hacia arriba (aproximado, pero conservador). */
    volatile int here;
    return ((uintptr_t)&here + 4 * GC_PAGE) & ~(GC_PAGE - 1);
}
static void gc_key_cb(void* p);
#endif

/* Registra el hilo actual (idempotente). Se llama con el cerrojo tomado. */
static gc_thread* gc_register_locked(void) {
    gc_thread* t = gc_self_get();
    if (t) return t;
    int slot = -1;
    for (int i = 0; i < gc_nthreads; i++)
        if (!gc_threads[i].active) { slot = i; break; }
    if (slot < 0) {
        if (gc_nthreads == GC_MAX_THREADS) gc_die("demasiados hilos registrados en el recolector");
        slot = gc_nthreads++;
    }
    t = &gc_threads[slot];
    memset(t, 0, sizeof *t);
    t->stack_top = gc_current_stack_top();
#if defined(_WIN32)
    t->id = GetCurrentThreadId();
    DuplicateHandle(GetCurrentProcess(), GetCurrentThread(), GetCurrentProcess(), &t->handle,
                    THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, 0);
#else
    t->id = pthread_self();
#endif
    t->active = 1;
    gc_self_set(t);
#if !defined(_WIN32)
    pthread_setspecific(gc_key, t);
#endif
    return t;
}

static void gc_unregister(gc_thread* t) {
    if (!t) return;
    gc_lock();
    if (t->active) {
#if defined(_WIN32)
        if (t->handle) CloseHandle(t->handle);
#endif
        t->active = 0;
    }
    gc_unlock();
}

#if defined(_WIN32)
static void WINAPI gc_fls_cb(void* p) { gc_unregister((gc_thread*)p); }
#else
static void gc_key_cb(void* p) { gc_unregister((gc_thread*)p); }
#endif

void faset_gc_register_thread(void) {
    gc_init();
    gc_lock();
    gc_register_locked();
    gc_unlock();
}

void faset_gc_unregister_thread(void) {
    gc_thread* t = gc_self_get();
    gc_self_set(NULL);
#if !defined(_WIN32)
    if (gc_ready) pthread_setspecific(gc_key, NULL);
#endif
    gc_unregister(t);
}

/* Raíces temporales: mantienen vivo un puntero mientras solo lo conoce el sistema. */
void faset_gc_pin(void* p) {
    if (!p) return;
    gc_lock();
    for (int i = 0; i < 64; i++)
        if (!gc_pinned[i]) { gc_pinned[i] = p; gc_unlock(); return; }
    gc_unlock();
    gc_die("demasiadas raíces temporales en el recolector");
}

void faset_gc_unpin(void* p) {
    if (!p) return;
    gc_lock();
    for (int i = 0; i < 64; i++)
        if (gc_pinned[i] == p) { gc_pinned[i] = NULL; break; }
    gc_unlock();
}

#if !defined(_WIN32)
static void gc_suspend_handler(int sig, siginfo_t* info, void* ctx) {
    (void)sig;
    (void)info;
    (void)ctx;
    int saved = errno;
    gc_thread* t = gc_self;
    /* Los registros del hilo están en el marco de la señal, por encima de este marco. */
    volatile uintptr_t here = 0;
    if (t) t->sp = (uintptr_t)&here;
    sem_post(&gc_ack);
    sigset_t mask;
    sigfillset(&mask);
    sigdelset(&mask, gc_sig_resume);
    sigdelset(&mask, SIGINT);
    sigdelset(&mask, SIGTERM);
    sigdelset(&mask, SIGQUIT);
    sigdelset(&mask, SIGABRT);
    do sigsuspend(&mask);
    while (__atomic_load_n(&gc_world_stopped, __ATOMIC_ACQUIRE));
    sem_post(&gc_ack);
    errno = saved;
}

static void gc_resume_handler(int sig) { (void)sig; }
#endif

/* Detiene los demás hilos registrados. Se llama con el cerrojo tomado. */
static void gc_stop_world(gc_thread* me) {
#if defined(_WIN32)
    for (int i = 0; i < gc_nthreads; i++) {
        gc_thread* t = &gc_threads[i];
        if (!t->active || t == me) continue;
        if (SuspendThread(t->handle) == (DWORD)-1) { t->sp = 0; continue; }
        CONTEXT c;
        memset(&c, 0, sizeof c);
        c.ContextFlags = CONTEXT_FULL;
        if (!GetThreadContext(t->handle, &c)) { t->sp = 0; continue; }
#  if defined(_M_X64) || defined(__x86_64__)
        t->sp = (uintptr_t)c.Rsp;
#  elif defined(_M_ARM64) || defined(__aarch64__)
        t->sp = (uintptr_t)c.Sp;
#  else
        t->sp = (uintptr_t)c.Esp;
#  endif
        /* Los registros guardados también son raíces. */
        gc_scan((uintptr_t)&c, (uintptr_t)&c + sizeof c);
    }
#else
    __atomic_store_n(&gc_world_stopped, 1, __ATOMIC_RELEASE);
    int sent = 0;
    for (int i = 0; i < gc_nthreads; i++) {
        gc_thread* t = &gc_threads[i];
        if (!t->active || t == me) continue;
        t->sp = 0;
        if (pthread_kill(t->id, gc_sig_suspend) == 0) sent++;
        else t->active = 0;  /* el hilo ya no existe */
    }
    for (int i = 0; i < sent; i++)
        while (sem_wait(&gc_ack) != 0 && errno == EINTR) {}
#endif
}

static void gc_start_world(gc_thread* me) {
#if defined(_WIN32)
    for (int i = 0; i < gc_nthreads; i++) {
        gc_thread* t = &gc_threads[i];
        if (t->active && t != me) ResumeThread(t->handle);
    }
#else
    __atomic_store_n(&gc_world_stopped, 0, __ATOMIC_RELEASE);
    int sent = 0;
    for (int i = 0; i < gc_nthreads; i++) {
        gc_thread* t = &gc_threads[i];
        if (!t->active || t == me || !t->sp) continue;
        if (pthread_kill(t->id, gc_sig_resume) == 0) sent++;
    }
    for (int i = 0; i < sent; i++)
        while (sem_wait(&gc_ack) != 0 && errno == EINTR) {}
#endif
}

/* ---- inicialización */

static void gc_init(void) {
    if (__atomic_load_n(&gc_ready, __ATOMIC_ACQUIRE)) return;
    gc_lock();
    if (gc_ready) { gc_unlock(); return; }
    gc_map = (gc_page**)gc_os_map(sizeof(gc_page*) * 65536);
    if (!gc_map) gc_die("sin memoria");
    for (int c = 0, s = 0; s <= GC_SMALL_MAX / 16; s++) {
        while (gc_class_size[c] < (uint32_t)s * 16) c++;
        gc_class_of[s] = (uint8_t)c;
    }
    const char* e = getenv("FASET_GC");
    gc_disabled = e && (strcmp(e, "off") == 0 || strcmp(e, "0") == 0);
    e = getenv("FASET_GC_STATS");
    gc_stats = e && *e && *e != '0';
    e = getenv("FASET_GC_MIN_MB");
    gc_min_threshold = (size_t)(e && atoi(e) > 0 ? atoi(e) : 16) << 20;
    gc_threshold = gc_min_threshold;
    gc_add_module_roots();
#if defined(_WIN32)
    gc_tls = TlsAlloc();
    gc_fls = FlsAlloc(gc_fls_cb);
#else
    pthread_key_create(&gc_key, gc_key_cb);
    sem_init(&gc_ack, 0, 0);
    gc_sig_suspend = SIGRTMIN + 6;
    gc_sig_resume = SIGRTMIN + 7;
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_flags = SA_RESTART | SA_SIGINFO;
    sa.sa_sigaction = gc_suspend_handler;
    sigfillset(&sa.sa_mask);
    sigaction(gc_sig_suspend, &sa, NULL);
    struct sigaction sr;
    memset(&sr, 0, sizeof sr);
    sr.sa_flags = SA_RESTART;
    sr.sa_handler = gc_resume_handler;
    sigfillset(&sr.sa_mask);
    sigaction(gc_sig_resume, &sr, NULL);
#endif
    __atomic_store_n(&gc_ready, 1, __ATOMIC_RELEASE);
    gc_unlock();
}

/* ---- recolección */

static double gc_now_ms(void) {
#if defined(_WIN32)
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1000.0 / (double)f.QuadPart;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
#endif
}

static void gc_finq_push(void* p) {
    if (gc_finq_len == gc_finq_cap) {
        size_t cap = gc_finq_cap ? gc_finq_cap * 2 : 4096;
        void** q = (void**)gc_os_map(cap * sizeof(void*));
        if (!q) gc_die("sin memoria");
        if (gc_finq) {
            memcpy(q, gc_finq, gc_finq_len * sizeof(void*));
            gc_os_unmap(gc_finq, gc_finq_cap * sizeof(void*));
        }
        gc_finq = q;
        gc_finq_cap = cap;
    }
    gc_finq[gc_finq_len++] = p;
}

static void gc_page_release(gc_page* d);

static GC_NOINLINE void gc_mark_from_here(gc_thread* me) {
    volatile uintptr_t here = 0;
    uintptr_t sp = (uintptr_t)&here;
    if (me) gc_scan(sp, me->stack_top);
}

static GC_NOINLINE void gc_collect_locked(void) {
    if (gc_in_collect) return;
    gc_in_collect = 1;
    double t0 = gc_stats ? gc_now_ms() : 0;
    gc_thread* me = gc_register_locked();
    /* Antes de detener a los demás: en Windows, gc_stop_world ya marca desde sus registros. */
    for (gc_page* d = gc_pages; d; d = d->next) memset(d->mark, 0, sizeof d->mark);
    gc_stop_world(me);

    /* Raíces: registros y pila del hilo actual, pilas de los demás, globales, fijadas y cola. */
    jmp_buf regs;
    setjmp(regs);
    gc_scan((uintptr_t)&regs, (uintptr_t)&regs + sizeof regs);
    gc_mark_from_here(me);
    gc_drain();
    for (int i = 0; i < gc_nthreads; i++) {
        gc_thread* t = &gc_threads[i];
        if (!t->active || t == me || !t->sp) continue;
        gc_scan(t->sp, t->stack_top);
        gc_drain();
    }
    for (int i = 0; i < gc_nroots; i++) {
        gc_scan(gc_roots[i].lo, gc_roots[i].hi);
        gc_drain();
    }
    for (int i = 0; i < 64; i++)
        if (gc_pinned[i]) gc_mark_word((uintptr_t)gc_pinned[i]);
    for (size_t i = 0; i < gc_finq_len; i++) gc_mark_word((uintptr_t)gc_finq[i]);
    gc_drain();

    /* Objetos con destructor que ya no se alcanzan: a la cola, y se conservan (con todo lo que
       alcanzan) hasta que se ejecute su destructor. */
    for (gc_page* d = gc_pages; d; d = d->next)
        for (uint32_t i = 0; i < d->nblocks; i++)
            if (GC_BIT(d->fin, i) && GC_BIT(d->alloc, i) && !GC_BIT(d->mark, i)) {
                GC_CLR(d->fin, i);
                uintptr_t obj = d->base + i * d->size;
                gc_finq_push((void*)obj);
                gc_mark_word(obj);
            }
    gc_drain();

    /* Barrido. */
    size_t live = 0, freed = 0;
    for (int a = 0; a < 2; a++)
        for (int c = 0; c < GC_NCLASS; c++) gc_free_pages[a][c] = NULL;
    gc_page** link = &gc_pages;
    while (*link) {
        gc_page* d = *link;
        if (d->large) {
            if (!GC_BIT(d->mark, 0)) {
                *link = d->next;
                freed += d->size;
                gc_page_release(d);
                continue;
            }
            live += d->size;
            link = &d->next;
            continue;
        }
        uint32_t used = 0;
        void* fl = NULL;
        for (uint32_t w = 0; w < GC_BITS; w++) d->alloc[w] &= d->mark[w];
        for (uint32_t i = d->nblocks; i-- > 0;) {
            if (GC_BIT(d->alloc, i)) { used++; continue; }
            void* b = (void*)(d->base + i * d->size);
            *(void**)b = fl;
            fl = b;
        }
        freed += (size_t)(d->nblocks - used - d->nfree) * d->size;
        d->freelist = fl;
        d->nfree = d->nblocks - used;
        if (used == 0) {
            *link = d->next;
            gc_page_release(d);
            continue;
        }
        live += (size_t)used * d->size;
        if (d->nfree) {
            d->next_free = gc_free_pages[d->atomic][d->cls];
            gc_free_pages[d->atomic][d->cls] = d;
        }
        link = &d->next;
    }
    gc_live = live;
    gc_since = 0;
    gc_threshold = live > gc_min_threshold ? live : gc_min_threshold;
    gc_count++;

    gc_start_world(me);
    gc_in_collect = 0;
    if (gc_stats)
        fprintf(stderr, "[gc] #%llu  %.2f ms  vivos %.1f MB  liberados %.1f MB  montón %.1f MB  destructores %llu\n",
                (unsigned long long)gc_count, gc_now_ms() - t0, live / 1048576.0, freed / 1048576.0,
                gc_heap_bytes / 1048576.0, (unsigned long long)gc_finq_len);
}

/* ---- destructores pendientes */

typedef struct faset_gc_obj_hdr { uint64_t magic; void (*dtor)(void*); } faset_gc_obj_hdr;
#define GC_OBJ_LIVE 0x4A424F5445534146ULL /* "FASETOBJ" */
#define GC_OBJ_DEAD 0xDEADDEADFA5E7DEDULL

static void gc_run_finalizers(void) {
    if (gc_running_finalizers) return;
    gc_running_finalizers = 1;
    for (;;) {
        gc_lock();
        void* p = gc_finq_len ? gc_finq[--gc_finq_len] : NULL;
        gc_unlock();
        if (!p) break;
        faset_gc_obj_hdr* h = (faset_gc_obj_hdr*)p;
        if (h->magic == GC_OBJ_LIVE && h->dtor) {
            void (*dtor)(void*) = h->dtor;
            h->dtor = NULL;
            dtor(h + 1);
        }
        h->magic = GC_OBJ_DEAD;
    }
    gc_running_finalizers = 0;
}

/* ---- reserva */

static void gc_page_release(gc_page* d) {
    gc_map_set(d->base, d->span, NULL);
    gc_heap_bytes -= d->span;
    if (!d->large && gc_spare_count < 256) {
        gc_spare_pages[gc_spare_count++] = d->base;
#if !defined(_WIN32)
        if (gc_spare_count > 32) madvise((void*)d->base, GC_PAGE, MADV_DONTNEED);
#endif
    } else {
        gc_os_unmap((void*)d->base, d->span);
    }
    gc_desc_free(d);
}

static gc_page* gc_page_new(int cls, int atomic) {
    uintptr_t base;
    if (gc_spare_count) base = gc_spare_pages[--gc_spare_count];
    else {
        /* De 16 en 16 páginas para no pedir memoria al sistema por cada una. */
        uint8_t* chunk = (uint8_t*)gc_os_map_aligned(GC_PAGE * 16);
        if (!chunk) gc_die("sin memoria");
        for (int i = 15; i >= 1 && gc_spare_count < 256; i--) gc_spare_pages[gc_spare_count++] = (uintptr_t)chunk + i * GC_PAGE;
        base = (uintptr_t)chunk;
    }
    gc_page* d = gc_desc_new();
    d->base = base;
    d->size = gc_class_size[cls];
    d->span = GC_PAGE;
    d->nblocks = (uint32_t)(GC_PAGE / d->size);
    d->cls = (uint8_t)cls;
    d->atomic = (uint8_t)atomic;
    void* fl = NULL;
    for (uint32_t i = d->nblocks; i-- > 0;) {
        void* b = (void*)(base + i * d->size);
        *(void**)b = fl;
        fl = b;
    }
    d->freelist = fl;
    d->nfree = d->nblocks;
    d->next = gc_pages;
    gc_pages = d;
    d->next_free = gc_free_pages[atomic][cls];
    gc_free_pages[atomic][cls] = d;
    gc_map_set(base, GC_PAGE, d);
    gc_heap_bytes += GC_PAGE;
    return d;
}

static void* gc_alloc_large_locked(size_t n, int atomic) {
    size_t span = (n + GC_PAGE - 1) & ~(GC_PAGE - 1);
    void* p = gc_os_map_aligned(span);
    if (!p) gc_die("sin memoria");
    gc_page* d = gc_desc_new();
    d->base = (uintptr_t)p;
    d->size = n;
    d->span = span;
    d->nblocks = 1;
    d->large = 1;
    d->atomic = (uint8_t)atomic;
    GC_SET(d->alloc, 0);
    d->next = gc_pages;
    gc_pages = d;
    gc_map_set(d->base, span, d);
    gc_heap_bytes += span;
    return p; /* mmap ya la entrega a cero */
}

static void* gc_alloc(int64_t size, int atomic, int zero, int finalizable) {
    if (!gc_ready) gc_init();
    /* Un byte extra: un puntero "uno después del final" sigue apuntando a este bloque. */
    size_t n = (size_t)(size > 0 ? size : 1) + 1;
    gc_lock();
    if (!gc_self_get()) gc_register_locked();
    int collected = 0;
    if (!gc_disabled && gc_since >= gc_threshold) {
        gc_collect_locked();
        collected = 1;
    }
    void* p;
    if (n > GC_SMALL_MAX) {
        p = gc_alloc_large_locked(n, atomic);
        gc_since += n;
        if (finalizable) GC_SET(gc_lookup((uintptr_t)p)->fin, 0);
        gc_unlock();
    } else {
        int cls = gc_class_of[(n + 15) / 16];
        gc_page* d = gc_free_pages[atomic][cls];
        while (d && !d->freelist) {
            d = d->next_free;
            gc_free_pages[atomic][cls] = d;
        }
        if (!d) d = gc_page_new(cls, atomic);
        p = d->freelist;
        d->freelist = *(void**)p;
        d->nfree--;
        uint32_t i = (uint32_t)(((uintptr_t)p - d->base) / d->size);
        GC_SET(d->alloc, i);
        if (finalizable) GC_SET(d->fin, i);
        gc_since += d->size;
        if (zero || !atomic) memset(p, 0, d->size);
        else *(void**)p = NULL;
        gc_unlock();
    }
    if (collected && gc_finq_len) gc_run_finalizers();
    return p;
}

/* ---- API para el runtime y los programas */

void* faset_gc_alloc(int64_t size) { return gc_alloc(size, 0, 1, 0); }
void* faset_gc_alloc_atomic(int64_t size) { return gc_alloc(size, 1, 0, 0); }
void* faset_gc_alloc_atomic_zeroed(int64_t size) { return gc_alloc(size, 1, 1, 0); }

/* Objeto de clase: cabecera {mágico, destructor} delante de los campos. */
void* faset_gc_obj_alloc(int64_t size, void (*dtor)(void*)) {
    faset_gc_obj_hdr* h = (faset_gc_obj_hdr*)gc_alloc((int64_t)sizeof(faset_gc_obj_hdr) + (size > 0 ? size : 1), 0, 1, dtor != NULL);
    h->magic = GC_OBJ_LIVE;
    h->dtor = dtor;
    return h + 1;
}

/* ¿Es un bloque del montón? (para no pasar a free() memoria del recolector) */
_Bool faset_gc_owns(const void* p) {
    if (!gc_ready || !p) return 0;
    return gc_lookup((uintptr_t)p) != NULL;
}

/* Tamaño útil del bloque que contiene p a partir de p (0 si no es del montón). */
int64_t faset_gc_usable(const void* p) {
    if (!gc_ready || !p) return 0;
    gc_lock();
    gc_page* d = gc_lookup((uintptr_t)p);
    int64_t r = 0;
    if (d && (uintptr_t)p >= d->base) {
        uintptr_t i = d->large ? 0 : ((uintptr_t)p - d->base) / d->size;
        if (i < d->nblocks) r = (int64_t)(d->base + i * d->size + d->size - (uintptr_t)p) - 1;
    }
    gc_unlock();
    return r;
}

_Bool faset_gc_is_atomic(const void* p) {
    gc_page* d = gc_ready && p ? gc_lookup((uintptr_t)p) : NULL;
    return d && d->atomic;
}

void faset_gc_collect(void) {
    if (!gc_ready) gc_init();
    gc_lock();
    gc_collect_locked();
    gc_unlock();
    gc_run_finalizers();
}

int64_t faset_gc_heap_bytes(void) { return (int64_t)gc_heap_bytes; }
int64_t faset_gc_live_bytes(void) { return (int64_t)(gc_live + gc_since); }
int64_t faset_gc_count(void) { return (int64_t)gc_count; }

/* Programa: registra el hilo principal. Biblioteca (argv nulo): el hilo que la carga no tiene
   por qué ejecutar código Faset; cada hilo se registra solo al reservar memoria por primera vez. */
void faset_gc_init(void) { gc_init(); }
void faset_gc_init_main(void) {
    gc_init();
    faset_gc_register_thread();
}

/* ---- hilos creados por la biblioteca estándar */

typedef struct gc_start { void (*fn)(void*); void* arg; } gc_start;

#if defined(_WIN32)
static DWORD WINAPI gc_thread_main(void* p) {
#else
static void* gc_thread_main(void* p) {
#endif
    faset_gc_register_thread();
    gc_start s = *(gc_start*)p;
    free(p);
    volatile void* keep = s.arg;  /* el argumento queda en la pila de este hilo */
    faset_gc_unpin(s.arg);
    s.fn(s.arg);
    (void)keep;
    faset_gc_unregister_thread();
#if defined(_WIN32)
    return 0;
#else
    return NULL;
#endif
}

/* Lanza un hilo registrado en el recolector; devuelve 0 si falla.
   'handle' recibe el pthread_t o el HANDLE. */
_Bool faset_thread_spawn(void (*fn)(void*), void* arg, uint64_t* handle) {
    gc_init();
    gc_start* s = (gc_start*)malloc(sizeof *s);
    if (!s) return 0;
    s->fn = fn;
    s->arg = arg;
    faset_gc_pin(arg);
#if defined(_WIN32)
    HANDLE h = CreateThread(NULL, 0, gc_thread_main, s, 0, NULL);
    if (!h) { faset_gc_unpin(arg); free(s); return 0; }
    *handle = (uint64_t)(uintptr_t)h;
#else
    pthread_t id;
    if (pthread_create(&id, NULL, gc_thread_main, s) != 0) { faset_gc_unpin(arg); free(s); return 0; }
    *handle = (uint64_t)id;
#endif
    return 1;
}
)FASET";
