#include "Runtime.h"

// Capa POSIX de std.io y std.os (archivos, carpetas, entorno y procesos). Se añade al final
// de kRuntimeSource, en la misma unidad de compilación. En Windows esta parte no se compila:
// lib/std/io.fst y lib/std/os.fst usan directamente las API W de Win32 (UTF-16).
const char* const kRuntimeOsSource = R"FASET(
/* ---- std.io / std.os: capa POSIX */
#if !defined(_WIN32)
#include <pwd.h>
#include <sys/utsname.h>
#if defined(__linux__)
#  include <sys/inotify.h>
#endif
extern char** environ;

#if defined(__APPLE__)
#  define FASET_ST_MTIM(st) ((st).st_mtimespec)
#  define FASET_ST_ATIM(st) ((st).st_atimespec)
#  define FASET_ST_CTIM(st) ((st).st_ctimespec)
#else
#  define FASET_ST_MTIM(st) ((st).st_mtim)
#  define FASET_ST_ATIM(st) ((st).st_atim)
#  define FASET_ST_CTIM(st) ((st).st_ctim)
#endif

static int64_t faset_px_ms(struct timespec ts) { return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000; }

/* out[0] tipo (1 archivo, 2 carpeta, 3 otro), out[1] es enlace simbólico, out[2] tamaño,
   out[3..5] escritura/acceso/cambio en ms Unix, out[6] permisos, out[7] solo lectura. */
_Bool faset_px_stat(faset_string path, int64_t* out) {
    char* p = faset_cstr(path);
    struct stat ls, st;
    _Bool ok = lstat(p, &ls) == 0;
    if (ok) {
        _Bool link = S_ISLNK(ls.st_mode);
        _Bool target = !link || stat(p, &st) == 0;
        if (!link || !target) st = ls;
        out[0] = !target ? 3 : S_ISDIR(st.st_mode) ? 2 : S_ISREG(st.st_mode) ? 1 : 3;
        out[1] = link;
        out[2] = (int64_t)st.st_size;
        out[3] = faset_px_ms(FASET_ST_MTIM(st));
        out[4] = faset_px_ms(FASET_ST_ATIM(st));
        out[5] = faset_px_ms(FASET_ST_CTIM(st));
        out[6] = (int64_t)(st.st_mode & 07777);
        out[7] = access(p, W_OK) != 0;
    }
    free(p);
    return ok;
}

/* 0 creada, 1 ya existía, 2 error. */
int32_t faset_px_mkdir(faset_string path, int32_t mode) {
    char* p = faset_cstr(path);
    int r = mkdir(p, (mode_t)mode) == 0 ? 0 : errno == EEXIST ? 1 : 2;
    free(p);
    return r;
}

_Bool faset_px_rmdir(faset_string path) {
    char* p = faset_cstr(path);
    _Bool ok = rmdir(p) == 0;
    free(p);
    return ok;
}

_Bool faset_px_unlink(faset_string path) {
    char* p = faset_cstr(path);
    _Bool ok = unlink(p) == 0;
    free(p);
    return ok;
}

/* 1 hecho, 0 error, 2 distinto sistema de archivos (EXDEV). */
int32_t faset_px_rename(faset_string from, faset_string to, _Bool overwrite) {
    char* a = faset_cstr(from);
    char* b = faset_cstr(to);
    struct stat st;
    int r;
    if (!overwrite && lstat(b, &st) == 0) r = 0;
    else if (rename(a, b) == 0) r = 1;
    else r = errno == EXDEV ? 2 : 0;
    free(a);
    free(b);
    return r;
}

/* Copia un archivo conservando los permisos; nunca trunca el propio origen. */
_Bool faset_px_copy_file(faset_string from, faset_string to, _Bool overwrite) {
    char* a = faset_cstr(from);
    char* b = faset_cstr(to);
    _Bool ok = 0;
    int in = open(a, O_RDONLY | O_CLOEXEC), out = -1;
    struct stat st, dt;
    if (in < 0 || fstat(in, &st) != 0 || !S_ISREG(st.st_mode)) goto done;
    if (stat(b, &dt) == 0) {
        if (!overwrite || (dt.st_dev == st.st_dev && dt.st_ino == st.st_ino)) goto done;
    }
    out = open(b, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | (overwrite ? 0 : O_EXCL), st.st_mode & 0777);
    if (out < 0) goto done;
    {
        char buf[65536];
        ok = 1;
        for (;;) {
            ssize_t n = read(in, buf, sizeof buf);
            if (n < 0 && errno == EINTR) continue;
            if (n < 0) { ok = 0; break; }
            if (n == 0) break;
            for (ssize_t w = 0; w < n;) {
                ssize_t k = write(out, buf + w, (size_t)(n - w));
                if (k < 0 && errno == EINTR) continue;
                if (k <= 0) { ok = 0; break; }
                w += k;
            }
            if (!ok) break;
        }
    }
    if (fchmod(out, st.st_mode & 07777) != 0) { /* sin permisos para cambiarlos: no es un error */ }
    if (close(out) != 0) ok = 0;
    out = -1;
done:
    if (in >= 0) close(in);
    if (out >= 0) close(out);
    free(a);
    free(b);
    return ok;
}

_Bool faset_px_chmod(faset_string path, int32_t mode) {
    char* p = faset_cstr(path);
    _Bool ok = chmod(p, (mode_t)mode) == 0;
    free(p);
    return ok;
}

_Bool faset_px_set_mtime(faset_string path, int64_t ms) {
    char* p = faset_cstr(path);
    struct timespec ts[2];
    ts[0].tv_sec = 0;
    ts[0].tv_nsec = UTIME_OMIT;
    ts[1].tv_sec = (time_t)(ms >= 0 ? ms / 1000 : -((-ms + 999) / 1000));
    ts[1].tv_nsec = (long)((ms - (int64_t)ts[1].tv_sec * 1000) * 1000000);
    _Bool ok = utimensat(AT_FDCWD, p, ts, 0) == 0;
    free(p);
    return ok;
}

/* Banderas: 1 leer, 2 escribir, 4 crear, 8 truncar, 16 exclusivo, 32 añadir. */
int64_t faset_px_open(faset_string path, int32_t flags) {
    char* p = faset_cstr(path);
    int f = (flags & 3) == 3 ? O_RDWR : (flags & 2) ? O_WRONLY : O_RDONLY;
    if (flags & 4) f |= O_CREAT;
    if (flags & 8) f |= O_TRUNC;
    if (flags & 16) f |= O_EXCL;
    if (flags & 32) f |= O_APPEND;
    int fd;
    do fd = open(p, f | O_CLOEXEC, 0666); while (fd < 0 && errno == EINTR);
    free(p);
    if (fd >= 0) {
        struct stat st;
        if (fstat(fd, &st) == 0 && S_ISDIR(st.st_mode)) { close(fd); fd = -1; }
    }
    return fd;
}

int64_t faset_px_read(int64_t fd, uint8_t* buf, int64_t n) {
    ssize_t r;
    do r = read((int)fd, buf, (size_t)n); while (r < 0 && errno == EINTR);
    return (int64_t)r;
}

_Bool faset_px_write(int64_t fd, const uint8_t* buf, int64_t n) {
    while (n > 0) {
        ssize_t k = write((int)fd, buf, (size_t)n);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) return 0;
        buf += k;
        n -= k;
    }
    return 1;
}

int64_t faset_px_seek(int64_t fd, int64_t offset, int32_t whence) {
    return (int64_t)lseek((int)fd, (off_t)offset, whence == 1 ? SEEK_CUR : whence == 2 ? SEEK_END : SEEK_SET);
}

_Bool faset_px_truncate(int64_t fd, int64_t length) { return ftruncate((int)fd, (off_t)length) == 0; }
_Bool faset_px_fsync(int64_t fd) { return fsync((int)fd) == 0; }
void faset_px_close(int64_t fd) { if (fd >= 0) close((int)fd); }

/* Contenido de una carpeta: "<tipo><nombre>\0..." con tipo f/d/o (archivo, carpeta, otro)
   o F/D/L para enlaces simbólicos a archivo, a carpeta o rotos. */
faset_string faset_px_list_dir(faset_string path, _Bool* ok) {
    char* p = faset_cstr(path);
    size_t cap = 1024, len = 0, pl = strlen(p);
    char* out = (char*)faset_alloc((int64_t)cap);
    DIR* d = opendir(p);
    *ok = d != NULL;
    if (d) {
        struct dirent* e;
        while ((e = readdir(d)) != NULL) {
            const char* name = e->d_name;
            if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;
            size_t nl = strlen(name);
            char* full = (char*)faset_alloc((int64_t)(pl + nl + 2));
            memcpy(full, p, pl);
            full[pl] = '/';
            memcpy(full + pl + 1, name, nl + 1);
            struct stat st;
            char kind = 'o';
            if (lstat(full, &st) == 0) {
                if (S_ISLNK(st.st_mode)) kind = stat(full, &st) != 0 ? 'L' : S_ISDIR(st.st_mode) ? 'D' : 'F';
                else kind = S_ISDIR(st.st_mode) ? 'd' : S_ISREG(st.st_mode) ? 'f' : 'o';
            }
            free(full);
            while (len + nl + 3 > cap) { cap *= 2; out = (char*)faset_realloc(out, (int64_t)cap); }
            out[len++] = kind;
            memcpy(out + len, name, nl);
            len += nl;
            out[len++] = 0;
        }
        closedir(d);
    }
    free(p);
    out[len] = 0;
    faset_string r = { (const uint8_t*)out, (int64_t)len };
    return r;
}

_Bool faset_px_chdir(faset_string path) {
    char* p = faset_cstr(path);
    _Bool ok = chdir(p) == 0;
    free(p);
    return ok;
}

faset_string faset_px_temp_dir(void) {
    const char* t = getenv("TMPDIR");
#if defined(__ANDROID__)
    if (!t || !*t) t = "/data/local/tmp";
#else
    if (!t || !*t) t = "/tmp";
#endif
    size_t n = strlen(t);
    while (n > 1 && t[n - 1] == '/') n--;
    faset_string s = faset_str_alloc((int64_t)n);
    memcpy((void*)s.ptr, t, n);
    return s;
}

/* ---- entorno */

_Bool faset_px_setenv(faset_string name, faset_string value) {
    char* n = faset_cstr(name);
    char* v = faset_cstr(value);
    _Bool ok = name.len > 0 && setenv(n, v, 1) == 0;
    free(n);
    free(v);
    return ok;
}

_Bool faset_px_unsetenv(faset_string name) {
    char* n = faset_cstr(name);
    _Bool ok = name.len > 0 && unsetenv(n) == 0;
    free(n);
    return ok;
}

/* Todas las variables: "CLAVE=valor\0..." */
faset_string faset_px_environ(void) {
    size_t len = 0;
    for (char** e = environ; e && *e; e++) len += strlen(*e) + 1;
    faset_string s = faset_str_alloc((int64_t)len);
    size_t at = 0;
    for (char** e = environ; e && *e; e++) {
        size_t n = strlen(*e);
        memcpy((void*)(s.ptr + at), *e, n + 1);
        at += n + 1;
    }
    return s;
}

/* 0 nombre de máquina, 1 usuario, 2 carpeta personal, 3 versión del núcleo, 4 arquitectura. */
faset_string faset_px_sysinfo(int32_t what) {
    char buf[1024];
    buf[0] = 0;
    if (what == 0) {
        if (gethostname(buf, sizeof buf - 1) != 0) buf[0] = 0;
        buf[sizeof buf - 1] = 0;
    } else if (what == 1 || what == 2) {
        const char* env = what == 1 ? getenv("USER") : getenv("HOME");
        if (env && *env) {
            snprintf(buf, sizeof buf, "%s", env);
        } else {
            struct passwd pw, *res = NULL;
            char tmp[4096];
            if (getpwuid_r(geteuid(), &pw, tmp, sizeof tmp, &res) == 0 && res)
                snprintf(buf, sizeof buf, "%s", what == 1 ? pw.pw_name : pw.pw_dir);
        }
    } else if (what == 3 || what == 4) {
        struct utsname u;
        if (uname(&u) == 0) snprintf(buf, sizeof buf, "%s", what == 3 ? u.release : u.machine);
    }
    return faset_str_from_buf(buf);
}

int32_t faset_px_nprocs(void) {
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? (int32_t)n : 1;
}

int32_t faset_px_getpid(void) { return (int32_t)getpid(); }

/* ---- procesos: argv sin shell (fork + execvp) */

static void faset_px_cloexec(int fd) { if (fd >= 0) fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC); }
static void faset_px_nonblock(int fd) { if (fd >= 0) fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK); }
static void faset_px_close_pair(int* p) {
    if (p[0] >= 0) close(p[0]);
    if (p[1] >= 0) close(p[1]);
    p[0] = p[1] = -1;
}

/* Banderas: 1 redirigir stdin, 2 stdout, 4 stderr, 8 stderr a stdout, 16 grupo de procesos propio,
   32 entorno propio (env/envc). out = { pid, fd stdin, fd stdout, fd stderr } (-1 si no se redirige).
   Devuelve 0 o el errno del fallo (también si execvp falla en el hijo). */
int32_t faset_px_spawn(const faset_string* argv, int32_t argc, const faset_string* env, int32_t envc,
                       faset_string cwd, int32_t flags, int32_t* out) {
    if (argc < 1) return EINVAL;
    char** av = (char**)faset_alloc_zeroed((int64_t)sizeof(char*) * (argc + 1));
    for (int i = 0; i < argc; i++) av[i] = faset_cstr(argv[i]);
    char** ev = NULL;
    if (flags & 32) {
        ev = (char**)faset_alloc_zeroed((int64_t)sizeof(char*) * (envc + 1));
        for (int i = 0; i < envc; i++) ev[i] = faset_cstr(env[i]);
    }
    char* dir = cwd.len ? faset_cstr(cwd) : NULL;
    int pin[2] = {-1, -1}, pout[2] = {-1, -1}, perr[2] = {-1, -1}, pexec[2] = {-1, -1};
    int err = 0;
    if (((flags & 1) && pipe(pin) != 0) || ((flags & 2) && pipe(pout) != 0) ||
        ((flags & 4) && !(flags & 8) && pipe(perr) != 0) || pipe(pexec) != 0) {
        err = errno ? errno : EMFILE;
    } else {
        int all[8] = {pin[0], pin[1], pout[0], pout[1], perr[0], perr[1], pexec[0], pexec[1]};
        for (int i = 0; i < 8; i++) faset_px_cloexec(all[i]);
        if (flags & 1) {
            /* Escribir en un stdin cerrado no debe matar al padre (como en .NET). */
            struct sigaction old;
            if (sigaction(SIGPIPE, NULL, &old) == 0 && old.sa_handler == SIG_DFL) signal(SIGPIPE, SIG_IGN);
        }
        fflush(stdout);
        fflush(stderr);
        pid_t pid = fork();
        if (pid < 0) {
            err = errno;
        } else if (pid == 0) {
            /* Hijo: solo funciones seguras tras fork. */
            if (flags & 16) setpgid(0, 0);
            if (pin[0] >= 0) dup2(pin[0], 0);
            if (pout[1] >= 0) dup2(pout[1], 1);
            if (flags & 8) dup2(1, 2);
            else if (perr[1] >= 0) dup2(perr[1], 2);
            signal(SIGPIPE, SIG_DFL);
            sigset_t none;
            sigemptyset(&none);
            sigprocmask(SIG_SETMASK, &none, NULL);
            int e = 0;
            if (dir && chdir(dir) != 0) e = errno;
            else {
                if (ev) environ = ev;
                execvp(av[0], av);
                e = errno;
            }
            ssize_t w = write(pexec[1], &e, sizeof e);
            (void)w;
            _exit(127);
        } else {
            if (flags & 16) setpgid(pid, pid);
            close(pexec[1]);
            pexec[1] = -1;
            int childErr = 0;
            ssize_t n;
            do n = read(pexec[0], &childErr, sizeof childErr); while (n < 0 && errno == EINTR);
            if (n == (ssize_t)sizeof childErr) {
                int st;
                while (waitpid(pid, &st, 0) < 0 && errno == EINTR) { }
                err = childErr ? childErr : ENOEXEC;
            } else {
                if (pin[0] >= 0) { close(pin[0]); pin[0] = -1; }
                if (pout[1] >= 0) { close(pout[1]); pout[1] = -1; }
                if (perr[1] >= 0) { close(perr[1]); perr[1] = -1; }
                faset_px_nonblock(pin[1]);
                faset_px_nonblock(pout[0]);
                faset_px_nonblock(perr[0]);
                out[0] = (int32_t)pid;
                out[1] = pin[1];
                out[2] = pout[0];
                out[3] = perr[0];
                pin[1] = pout[0] = perr[0] = -1;
            }
        }
    }
    faset_px_close_pair(pin);
    faset_px_close_pair(pout);
    faset_px_close_pair(perr);
    faset_px_close_pair(pexec);
    for (int i = 0; i < argc; i++) free(av[i]);
    free(av);
    if (ev) {
        for (int i = 0; i < envc; i++) free(ev[i]);
        free(ev);
    }
    free(dir);
    return err;
}

/* -1 en ejecución, -2 error; si no, el código de salida (128 + señal si lo mató una señal). */
int32_t faset_px_wait(int32_t pid, _Bool block) {
    int status;
    pid_t r;
    do r = waitpid((pid_t)pid, &status, block ? 0 : WNOHANG); while (r < 0 && errno == EINTR);
    if (r == 0) return -1;
    if (r < 0) return -2;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return 128 + (WIFSIGNALED(status) ? WTERMSIG(status) : 0);
}

_Bool faset_px_kill(int32_t pid, _Bool group) {
    if (pid <= 0) return 0;
    if (group && kill(-(pid_t)pid, SIGKILL) == 0) return 1;
    return kill((pid_t)pid, SIGKILL) == 0;
}

/* Lectura sin bloqueo: bytes (>0), 0 si no hay datos ahora, -1 al final o con error. */
int32_t faset_px_read_nb(int32_t fd, uint8_t* buf, int32_t cap) {
    ssize_t n = read(fd, buf, (size_t)cap);
    if (n > 0) return (int32_t)n;
    if (n == 0) return -1;
    return (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) ? 0 : -1;
}

/* Escritura sin bloqueo: bytes escritos, 0 si la tubería está llena, -1 con error. */
int32_t faset_px_write_nb(int32_t fd, const uint8_t* buf, int32_t n) {
    ssize_t k = write(fd, buf, (size_t)n);
    if (k >= 0) return (int32_t)k;
    return (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) ? 0 : -1;
}

/* Espera hasta 'ms' a que algún descriptor tenga datos (o se cierre). 'writeFd' (>= 0) espera a
   que se pueda escribir. Devuelve true si hay algo listo. */
_Bool faset_px_poll(const int32_t* fds, int32_t n, int32_t writeFd, int32_t ms) {
    struct pollfd p[8];
    int k = 0;
    for (int i = 0; i < n && k < 7; i++)
        if (fds[i] >= 0) { p[k].fd = fds[i]; p[k].events = POLLIN; p[k].revents = 0; k++; }
    if (writeFd >= 0) { p[k].fd = writeFd; p[k].events = POLLOUT; p[k].revents = 0; k++; }
    if (k == 0) { faset_sleep_ms(ms); return 0; }
    int r;
    do r = poll(p, (nfds_t)k, ms); while (r < 0 && errno == EINTR);
    return r > 0;
}

/* ---- vigilancia de archivos (inotify en Linux; -1 en otros sistemas: se usa sondeo) */

int32_t faset_px_watch_init(void) {
#if defined(__linux__)
    return inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
#else
    return -1;
#endif
}

int32_t faset_px_watch_add(int32_t fd, faset_string path) {
#if defined(__linux__)
    char* p = faset_cstr(path);
    int wd = inotify_add_watch(fd, p, IN_CREATE | IN_DELETE | IN_MODIFY | IN_CLOSE_WRITE | IN_ATTRIB |
                                          IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF);
    free(p);
    return wd;
#else
    (void)fd; (void)path;
    return -1;
#endif
}

/* Eventos pendientes: "<tipo><carpeta?><wd>:<nombre>\0..." con tipo c (creado), d (borrado),
   m (modificado), x (la carpeta vigilada desapareció) y carpeta '1' o '0'. */
faset_string faset_px_watch_read(int32_t fd) {
    size_t cap = 256, len = 0;
    char* out = (char*)faset_alloc((int64_t)cap);
#if defined(__linux__)
    char buf[16384] __attribute__((aligned(__alignof__(struct inotify_event))));
    for (;;) {
        ssize_t n = read(fd, buf, sizeof buf);
        if (n <= 0) break;
        for (char* q = buf; q < buf + n;) {
            struct inotify_event* e = (struct inotify_event*)q;
            q += sizeof(struct inotify_event) + e->len;
            char kind = 0;
            if (e->mask & (IN_CREATE | IN_MOVED_TO)) kind = 'c';
            else if (e->mask & (IN_DELETE | IN_MOVED_FROM)) kind = 'd';
            else if (e->mask & (IN_MODIFY | IN_CLOSE_WRITE | IN_ATTRIB)) kind = 'm';
            else if (e->mask & (IN_DELETE_SELF | IN_MOVE_SELF | IN_IGNORED)) kind = 'x';
            if (!kind) continue;
            const char* name = e->len ? e->name : "";
            size_t nl = strlen(name);
            char head[32];
            int hl = snprintf(head, sizeof head, "%c%c%d:", kind, (e->mask & IN_ISDIR) ? '1' : '0', e->wd);
            while (len + (size_t)hl + nl + 2 > cap) { cap *= 2; out = (char*)faset_realloc(out, (int64_t)cap); }
            memcpy(out + len, head, (size_t)hl);
            len += (size_t)hl;
            memcpy(out + len, name, nl);
            len += nl;
            out[len++] = 0;
        }
    }
#else
    (void)fd;
#endif
    out[len] = 0;
    faset_string r = { (const uint8_t*)out, (int64_t)len };
    return r;
}
#endif /* !_WIN32 */
)FASET";
