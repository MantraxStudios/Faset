#include "Runtime.h"

// Runtime de async / await (ver Async.cpp y lib/std/task.fst): el contexto de sincronización
// actual de cada hilo, relanzar la excepción guardada en una tarea y despertar el bucle de eventos
// de std.ui desde otro hilo. Se añade al final de faset_rt.c.
const char* const kRuntimeAsyncSource = R"FASET(
/* ---- async / await */

/* SynchronizationContext.Current: un puntero por hilo (el objeto lo mantiene vivo quien lo instala). */
static _Thread_local void* faset_sync_ctx;
void* faset_sync_ctx_get(void) { return faset_sync_ctx; }
void faset_sync_ctx_set(void* c) { faset_sync_ctx = c; }

/* await / Task.Result de una tarea con error: la misma excepción, con su StackTrace original y la
   línea donde se esperó añadida (como 'throw;'). */
void faset_exc_rethrow_obj(void* obj) {
    faset_exc_frame f;
    f.obj = obj;
    f.type = fx_type_of(obj);
    f.file = 0;
    f.line = 0;
    fx_unwind(f.obj, f.type, f.file, f.line);
}

/* Un cerrojo y una variable de condición globales para el estado de todas las tareas (std.task).
   Son objetos estáticos de C: están listos antes de cualquier inicialización de Faset. */
#if defined(_WIN32)
static SRWLOCK faset_task_mx = SRWLOCK_INIT;
static CONDITION_VARIABLE faset_task_cv = CONDITION_VARIABLE_INIT;
void faset_task_lock(void) { AcquireSRWLockExclusive(&faset_task_mx); }
void faset_task_unlock(void) { ReleaseSRWLockExclusive(&faset_task_mx); }
void faset_task_notify(void) { WakeAllConditionVariable(&faset_task_cv); }
/* Con el cerrojo tomado: espera un aviso (ms < 0: sin plazo). */
void faset_task_wait(int64_t ms) {
    SleepConditionVariableSRW(&faset_task_cv, &faset_task_mx, ms < 0 ? INFINITE : (DWORD)ms, 0);
}
#else
#include <pthread.h>
static pthread_mutex_t faset_task_mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t faset_task_cv = PTHREAD_COND_INITIALIZER;
void faset_task_lock(void) { pthread_mutex_lock(&faset_task_mx); }
void faset_task_unlock(void) { pthread_mutex_unlock(&faset_task_mx); }
void faset_task_notify(void) { pthread_cond_broadcast(&faset_task_cv); }
void faset_task_wait(int64_t ms) {
    if (ms < 0) {
        pthread_cond_wait(&faset_task_cv, &faset_task_mx);
        return;
    }
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += (time_t)(ms / 1000);
    ts.tv_nsec += (long)(ms % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec++;
        ts.tv_nsec -= 1000000000L;
    }
    pthread_cond_timedwait(&faset_task_cv, &faset_task_mx, &ts);
}
#endif

/* ¿La excepción es de la clase 'name' o deriva de ella? (OperationCanceledException deja una tarea
   cancelada; las clases con [ExceptionBase] no admiten 'is' desde Exception). */
_Bool faset_exc_is_named(void* obj, faset_string name) {
    if (!obj) return 0;
    for (const faset_exc_type* t = fx_type_of(obj); t; t = t->base) {
        const char* n = t->name;
        int64_t k = 0;
        while (n[k] && k < name.len && (uint8_t)n[k] == name.ptr[k]) k++;
        if (k == name.len && !n[k]) return 1;
    }
    return 0;
}

/* Despertar el bucle de la interfaz (UiSynchronizationContext.Post desde otro hilo). POSIX: una
   tubería que el bucle espera junto al descriptor de la conexión con el servidor gráfico; Windows:
   un evento que MsgWaitForMultipleObjects espera junto a los mensajes. */
#if defined(_WIN32)
static HANDLE volatile faset_wake_ev;
static HANDLE faset_wake_event(void) {
    if (!faset_wake_ev) {
        HANDLE h = CreateEventW(NULL, FALSE, FALSE, NULL);
        if (InterlockedCompareExchangePointer((PVOID volatile*)&faset_wake_ev, h, NULL) != NULL) CloseHandle(h);
    }
    return faset_wake_ev;
}
void faset_loop_wake(void) { SetEvent(faset_wake_event()); }
/* Espera mensajes de la ventana, el evento de despertar o el plazo. */
void faset_loop_wait_msgs(int32_t ms) {
    HANDLE h = faset_wake_event();
    MsgWaitForMultipleObjects(1, &h, FALSE, (DWORD)(ms > 0 ? ms : 0), 0x04FF);
}
_Bool faset_wait_fd_wake(int32_t fd, int32_t ms) {
    (void)fd;
    return WaitForSingleObject(faset_wake_event(), (DWORD)(ms > 0 ? ms : 0)) == WAIT_OBJECT_0;
}
#else
static int faset_wake_fds[2] = { -1, -1 };
static int faset_wake_ready;  /* 0 sin crear, 1 creándose, 2 lista */
static void faset_wake_init(void) {
    int st = __atomic_load_n(&faset_wake_ready, __ATOMIC_ACQUIRE);
    if (st == 2) return;
    int expected = 0;
    if (__atomic_compare_exchange_n(&faset_wake_ready, &expected, 1, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
        int fds[2];
        if (pipe(fds) == 0) {
            for (int i = 0; i < 2; i++) {
                fcntl(fds[i], F_SETFL, fcntl(fds[i], F_GETFL) | O_NONBLOCK);
                fcntl(fds[i], F_SETFD, FD_CLOEXEC);
            }
            faset_wake_fds[0] = fds[0];
            faset_wake_fds[1] = fds[1];
        }
        __atomic_store_n(&faset_wake_ready, 2, __ATOMIC_RELEASE);
        return;
    }
    while (__atomic_load_n(&faset_wake_ready, __ATOMIC_ACQUIRE) != 2) { }
}
void faset_loop_wake(void) {
    faset_wake_init();
    if (faset_wake_fds[1] >= 0) {
        char c = 1;
        ssize_t n = write(faset_wake_fds[1], &c, 1);
        (void)n;
    }
}
void faset_loop_wait_msgs(int32_t ms) { (void)ms; }
/* Espera hasta 'ms' a que 'fd' (si es >= 0) tenga datos o a que alguien llame a faset_loop_wake. */
_Bool faset_wait_fd_wake(int32_t fd, int32_t ms) {
    faset_wake_init();
    struct pollfd p[2];
    int n = 0;
    if (fd >= 0) { p[n].fd = fd; p[n].events = POLLIN; p[n].revents = 0; n++; }
    int w = -1;
    if (faset_wake_fds[0] >= 0) { w = n; p[n].fd = faset_wake_fds[0]; p[n].events = POLLIN; p[n].revents = 0; n++; }
    int r = poll(p, (nfds_t)n, ms);
    if (w >= 0 && r > 0 && (p[w].revents & POLLIN)) {
        char buf[64];
        while (read(faset_wake_fds[0], buf, sizeof buf) > 0) { }
    }
    return r > 0;
}
#endif
)FASET";
