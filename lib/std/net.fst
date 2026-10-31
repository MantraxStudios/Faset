// =============================================================================
//  std.net  —  redes: direcciones IP, DNS, sockets TCP/UDP, URL y HTTP/1.1.
//
//    IPAddress / IPEndPoint      direcciones IPv4 e IPv6 (analizar y formatear)
//    Dns                         resolución de nombres (getaddrinfo)
//    Socket                      socket de bajo nivel: bloqueante o no, Poll, tiempos de espera
//    TcpClient / TcpListener     conexiones TCP
//    UdpClient                   datagramas UDP
//    Uri                         análisis de URL y codificación por porcentajes
//    TlsStream                   conexión cifrada con TLS 1.2/1.3 (cliente y servidor)
//    HttpClient                  cliente HTTP/1.1 para http:// y https:// (GET, POST, cabeceras, chunked)
//
//      auto http = new HttpClient;
//      HttpResponse r = http.Get("http://example.com/");
//      if (r != null) println(r.Body);
//      else println(http.ErrorMessage);
//      delete r;
//      delete http;
//
//  Convención de errores (std.net no lanza excepciones, salvo IPAddress.Parse con texto no válido):
//    - las operaciones devuelven bool (true = éxito), un número de bytes (-1 = error)
//      o un objeto (null = error);
//    - el motivo queda en la propiedad 'Error' (SocketError) del objeto que falló y en
//      'ErrorMessage' (texto constante: no hay que liberarlo). Las funciones estáticas de
//      Dns usan Dns.LastError. 'NativeError' guarda el código de errno / WSAGetLastError.
//
//  Memoria: los objetos se liberan con delete (cierra el socket). Las cadenas que devuelve
//  una función 'string ... // copia' se liberan con String.Free; las propiedades de Uri,
//  HttpHeaders y HttpResponse son vistas válidas mientras viva el objeto.
//
//  Plataformas: Linux y Android (sockets BSD de libc) y Windows (Winsock2; el compilador
//  enlaza ws2_32 automáticamente). En Windows las funciones de Winsock son __stdcall,
//  que solo coincide con la convención de C en x86-64 (no en Windows x86 de 32 bits).
//  TLS (lib/net/faset_tls.c): OpenSSL 3 cargado con dlopen en Linux (solo hace falta al usar
//  TLS), Schannel en Windows y BearSSL (solo TLS 1.2) en Android.
//  Limitaciones: sin proxies, sin compresión, sin keep-alive (cada petición abre una conexión
//  con 'Connection: close').
// =============================================================================
using std.collections;
using std.task;
using std.text;

namespace std.net
{
    public enum AddressFamily { Unspecified, InterNetwork, InterNetworkV6 }
    public enum SocketType { Stream, Datagram }
    public enum SelectMode { Read, Write, Error }
    public enum SocketShutdown { Receive, Send, Both }

    public enum SocketError
    {
        Success,
        WouldBlock,          // operación no bloqueante que aún no puede completarse
        InProgress,          // conexión no bloqueante en curso
        TimedOut,
        ConnectionRefused,
        ConnectionReset,
        ConnectionAborted,
        NotConnected,
        Shutdown,
        AddressInUse,
        AddressNotAvailable,
        NetworkUnreachable,
        HostUnreachable,
        HostNotFound,
        AccessDenied,
        InvalidArgument,
        Interrupted,
        InvalidSocket,
        Unsupported,
        InvalidUrl,
        ProtocolError,       // respuesta HTTP mal formada o incompleta
        TlsError,            // fallo del protocolo TLS (negociación, alerta, datos dañados)
        CertificateError,    // el certificado del otro extremo no supera la verificación
        TlsUnavailable,      // no hay motor TLS (Linux sin OpenSSL) o la función no existe en esta plataforma
        Other
    }

    // ======================================================================= constantes del sistema
#if WINDOWS
    memory_unsafe static class K
    {
        public const int AF_UNSPEC = 0;
        public const int AF_INET = 2;
        public const int AF_INET6 = 23;
        public const int SOCK_STREAM = 1;
        public const int SOCK_DGRAM = 2;
        public const int IPPROTO_TCP = 6;
        public const int IPPROTO_UDP = 17;
        public const int IPPROTO_IPV6 = 41;
        public const int SOL_SOCKET = 0xffff;
        public const int SO_REUSEADDR = 4;
        public const int SO_KEEPALIVE = 8;
        public const int SO_BROADCAST = 0x20;
        public const int SO_ERROR = 0x1007;
        public const int TCP_NODELAY = 1;
        public const int IPV6_V6ONLY = 27;
        public const uint FIONBIO = 0x8004667e;
        public const uint FIONREAD = 0x4004667f;
        public const uint WSA_FLAG_OVERLAPPED = 1;
        public const uint WSA_FLAG_NO_HANDLE_INHERIT = 0x80;
        // En Windows SO_REUSEADDR permite robar un puerto en uso: no se activa al escuchar.
        public const bool ReuseOnListen = false;

        public const int EINTR = 10004;
        public const int EBADF = 10009;
        public const int EACCES = 10013;
        public const int EINVAL = 10022;
        public const int EWOULDBLOCK = 10035;
        public const int EAGAIN = 10035;
        public const int EINPROGRESS = 10036;
        public const int EALREADY = 10037;
        public const int ENOTSOCK = 10038;
        public const int EMSGSIZE = 10040;
        public const int EAFNOSUPPORT = 10047;
        public const int EADDRINUSE = 10048;
        public const int EADDRNOTAVAIL = 10049;
        public const int ENETUNREACH = 10051;
        public const int ECONNABORTED = 10053;
        public const int ECONNRESET = 10054;
        public const int ENOTCONN = 10057;
        public const int ESHUTDOWN = 10058;
        public const int ETIMEDOUT = 10060;
        public const int ECONNREFUSED = 10061;
        public const int EHOSTUNREACH = 10065;
        public const int EPIPE = 10058;
        public const int EPERM = 10013;
        public const int HOST_NOT_FOUND = 11001;
        public const int TRY_AGAIN = 11002;
        public const int NO_RECOVERY = 11003;
        public const int NO_DATA = 11004;

        // struct addrinfo: ai_flags, ai_family, ai_socktype, ai_protocol, size_t ai_addrlen,
        // char* ai_canonname, sockaddr* ai_addr, addrinfo* ai_next.
        public static prop AiAddr: int => 16 + 2 * sizeof(void*);
        public static prop AiNext: int => 16 + 3 * sizeof(void*);
    }
#else
    memory_unsafe static class K
    {
        public const int AF_UNSPEC = 0;
        public const int AF_INET = 2;
        public const int AF_INET6 = 10;
        public const int SOCK_STREAM = 1;
        public const int SOCK_DGRAM = 2;
        public const int SOCK_CLOEXEC = 0x80000;
        public const int IPPROTO_TCP = 6;
        public const int IPPROTO_UDP = 17;
        public const int IPPROTO_IPV6 = 41;
        public const int SOL_SOCKET = 1;
        public const int SO_REUSEADDR = 2;
        public const int SO_ERROR = 4;
        public const int SO_BROADCAST = 6;
        public const int SO_KEEPALIVE = 9;
        public const int TCP_NODELAY = 1;
        public const int IPV6_V6ONLY = 26;
        public const int MSG_NOSIGNAL = 0x4000;
        public const int F_GETFL = 3;
        public const int F_SETFL = 4;
        public const int O_NONBLOCK = 0x800;
        public const int FIONREAD = 0x541b;
        public const int POLLIN = 1;
        public const int POLLPRI = 2;
        public const int POLLOUT = 4;
        public const bool ReuseOnListen = true;

        public const int EPERM = 1;
        public const int EINTR = 4;
        public const int EBADF = 9;
        public const int EAGAIN = 11;
        public const int EWOULDBLOCK = 11;
        public const int EACCES = 13;
        public const int EINVAL = 22;
        public const int EPIPE = 32;
        public const int ENOTSOCK = 88;
        public const int EMSGSIZE = 90;
        public const int EAFNOSUPPORT = 97;
        public const int EADDRINUSE = 98;
        public const int EADDRNOTAVAIL = 99;
        public const int ENETUNREACH = 101;
        public const int ECONNABORTED = 103;
        public const int ECONNRESET = 104;
        public const int ENOTCONN = 107;
        public const int ESHUTDOWN = 108;
        public const int ETIMEDOUT = 110;
        public const int ECONNREFUSED = 111;
        public const int EHOSTUNREACH = 113;
        public const int EALREADY = 114;
        public const int EINPROGRESS = 115;
        public const int HOST_NOT_FOUND = -2;   // EAI_NONAME
        public const int TRY_AGAIN = -3;        // EAI_AGAIN
        public const int NO_RECOVERY = -4;      // EAI_FAIL
        public const int NO_DATA = -5;          // EAI_NODATA

#if ANDROID
        // struct addrinfo de bionic (orden BSD): 4 int, socklen_t ai_addrlen, char* ai_canonname,
        // sockaddr* ai_addr, addrinfo* ai_next (los punteros van alineados a su tamaño).
        public static prop AiAddr: int => sizeof(void*) == 8 ? 32 : 24;
        public static prop AiNext: int => AiAddr + sizeof(void*);
#else
        // struct addrinfo de glibc: 4 int, socklen_t ai_addrlen, sockaddr* ai_addr, char* ai_canonname,
        // addrinfo* ai_next (el puntero ai_addr va alineado al tamaño de puntero).
        public static prop AiAddr: int => sizeof(void*) == 8 ? 24 : 20;
        public static prop AiNext: int => AiAddr + 2 * sizeof(void*);
#endif
    }
#endif

    // ======================================================================= llamadas al sistema
    //  Sys da la misma interfaz en todas las plataformas: el socket es un 'long' (-1 = inválido).
#if WINDOWS
    memory_unsafe static class Sys
    {
        static extern int WSAStartup(ushort version, byte* data);
        static extern int WSAGetLastError();
        static extern ulong WSASocketW(int af, int type, int protocol, void* info, uint group, uint flags);
        static extern int closesocket(ulong s);
        static extern int connect(ulong s, byte* addr, int len);
        static extern int bind(ulong s, byte* addr, int len);
        static extern int listen(ulong s, int backlog);
        static extern ulong accept(ulong s, byte* addr, int* len);
        static extern int send(ulong s, byte* buf, int len, int flags);
        static extern int recv(ulong s, byte* buf, int len, int flags);
        static extern int sendto(ulong s, byte* buf, int len, int flags, byte* to, int tolen);
        static extern int recvfrom(ulong s, byte* buf, int len, int flags, byte* from, int* fromlen);
        static extern int shutdown(ulong s, int how);
        static extern int setsockopt(ulong s, int level, int name, byte* value, int len);
        static extern int getsockopt(ulong s, int level, int name, byte* value, int* len);
        static extern int getsockname(ulong s, byte* addr, int* len);
        static extern int getpeername(ulong s, byte* addr, int* len);
        static extern int ioctlsocket(ulong s, uint cmd, uint* arg);
        static extern int select(int n, byte* readfds, byte* writefds, byte* exceptfds, byte* timeout);
        static extern int getaddrinfo(byte* node, byte* service, byte* hints, byte** result);
        static extern void freeaddrinfo(byte* ai);
        static extern int gethostname(byte* name, int len);

        static var started: bool;

        public static func Startup()
        {
            if (started) return;
            byte* data = (byte*)Memory.AllocZeroed(512);   // WSADATA
            WSAStartup((ushort)0x0202, data);
            Memory.Free(data);
            started = true;
        }

        public static func LastError() -> int => WSAGetLastError();

        public static func Open(af: int, type: int, proto: int) -> long
        {
            ulong s = WSASocketW(af, type, proto, null, 0, K.WSA_FLAG_OVERLAPPED | K.WSA_FLAG_NO_HANDLE_INHERIT);
            return s == 0xffffffffffffffff ? -1 : (long)s;
        }

        public static func Close(h: long) -> int => closesocket((ulong)h);
        public static func Connect(h: long, a: byte*, len: int) -> int => connect((ulong)h, a, len);
        public static func Bind(h: long, a: byte*, len: int) -> int => bind((ulong)h, a, len);
        public static func Listen(h: long, backlog: int) -> int => listen((ulong)h, backlog);

        public static func Accept(h: long, a: byte*, len: int*) -> long
        {
            ulong s = accept((ulong)h, a, len);
            return s == 0xffffffffffffffff ? -1 : (long)s;
        }

        public static func Send(h: long, b: byte*, n: int) -> int => send((ulong)h, b, n, 0);
        public static func Recv(h: long, b: byte*, n: int) -> int => recv((ulong)h, b, n, 0);
        public static func SendTo(h: long, b: byte*, n: int, a: byte*, alen: int) -> int => sendto((ulong)h, b, n, 0, a, alen);

        public static func RecvFrom(h: long, b: byte*, n: int, a: byte*, alen: int*) -> int
        {
            int r = recvfrom((ulong)h, b, n, 0, a, alen);
            if (r < 0 && WSAGetLastError() == K.EMSGSIZE) return n;   // datagrama truncado (como en Linux)
            return r;
        }

        public static func Shutdown(h: long, how: int) -> int => shutdown((ulong)h, how);
        public static func SetOption(h: long, level: int, name: int, value: int) -> int => setsockopt((ulong)h, level, name, (byte*)&value, 4);

        public static func GetOption(h: long, level: int, name: int, out value: int) -> int
        {
            int v = 0;
            int len = 4;
            int r = getsockopt((ulong)h, level, name, (byte*)&v, &len);
            value = v;
            return r;
        }

        public static func LocalName(h: long, a: byte*, len: int*) -> int => getsockname((ulong)h, a, len);
        public static func PeerName(h: long, a: byte*, len: int*) -> int => getpeername((ulong)h, a, len);

        public static func SetBlocking(h: long, on: bool) -> bool
        {
            uint arg = on ? (uint)0 : (uint)1;
            return ioctlsocket((ulong)h, K.FIONBIO, &arg) == 0;
        }

        public static func Available(h: long) -> int
        {
            uint n = 0;
            if (ioctlsocket((ulong)h, K.FIONREAD, &n) != 0) return -1;
            return (int)n;
        }

        // 1 = listo, 0 = tiempo agotado, -1 = error. mode: 0 leer, 1 escribir, 2 error.
        // Se usa select (WSAPoll no informa de los connect fallidos).
        public static func Wait(h: long, mode: int, timeoutMs: int) -> int
        {
            byte* rs = (byte*)Memory.AllocZeroed(16);   // fd_set { u_int fd_count; SOCKET fd_array[]; }
            byte* ws = (byte*)Memory.AllocZeroed(16);
            byte* es = (byte*)Memory.AllocZeroed(16);
            byte* tv = (byte*)Memory.AllocZeroed(8);    // timeval { long tv_sec; long tv_usec; }
            *(uint*)rs = 1;
            *(ulong*)(rs + 8) = (ulong)h;
            Memory.Copy(ws, rs, 16);
            Memory.Copy(es, rs, 16);
            if (timeoutMs >= 0)
            {
                *(int*)tv = timeoutMs / 1000;
                *(int*)(tv + 4) = (timeoutMs % 1000) * 1000;
            }
            int r = select(0, mode == 0 ? rs : null, mode == 1 ? ws : null, mode >= 1 ? es : null, timeoutMs >= 0 ? tv : null);
            Memory.Free(rs);
            Memory.Free(ws);
            Memory.Free(es);
            Memory.Free(tv);
            return r > 0 ? 1 : r;
        }

        public static func GetAddrInfo(node: byte*, hints: byte*, result: byte**) -> int => getaddrinfo(node, null, hints, result);
        public static func FreeAddrInfo(ai: byte*) { freeaddrinfo(ai); }
        public static func HostName(buf: byte*, len: int) -> int => gethostname(buf, len);
    }
#else
    memory_unsafe static class Sys
    {
        // size_t, ssize_t, nfds_t y unsigned long se declaran como void*: tienen el tamaño de
        // un puntero tanto en 32 como en 64 bits (ARMv7 y ARM64, x86 y x86-64).
#if ANDROID
        static extern int* __errno();
#else
        static extern int* __errno_location();
#endif
        static extern int socket(int domain, int type, int protocol);
        static extern int close(int fd);
        static extern int connect(int fd, byte* addr, uint len);
        static extern int bind(int fd, byte* addr, uint len);
        static extern int listen(int fd, int backlog);
        static extern int accept4(int fd, byte* addr, uint* len, int flags);
        static extern void* send(int fd, byte* buf, void* len, int flags);
        static extern void* recv(int fd, byte* buf, void* len, int flags);
        static extern void* sendto(int fd, byte* buf, void* len, int flags, byte* to, uint tolen);
        static extern void* recvfrom(int fd, byte* buf, void* len, int flags, byte* from, uint* fromlen);
        static extern int shutdown(int fd, int how);
        static extern int setsockopt(int fd, int level, int name, byte* value, uint len);
        static extern int getsockopt(int fd, int level, int name, byte* value, uint* len);
        static extern int getsockname(int fd, byte* addr, uint* len);
        static extern int getpeername(int fd, byte* addr, uint* len);
        static extern int fcntl(int fd, int cmd, ...);
        static extern int ioctl(int fd, void* request, ...);
        static extern int poll(byte* fds, void* count, int timeout);
        static extern int getaddrinfo(byte* node, byte* service, byte* hints, byte** result);
        static extern void freeaddrinfo(byte* ai);
        static extern int gethostname(byte* name, void* len);

        public static func Startup() { }

#if ANDROID
        public static func LastError() -> int => *__errno();
#else
        public static func LastError() -> int => *__errno_location();
#endif

        public static func Open(af: int, type: int, proto: int) -> long => socket(af, type | K.SOCK_CLOEXEC, proto);
        public static func Close(h: long) -> int => close((int)h);
        public static func Connect(h: long, a: byte*, len: int) -> int => connect((int)h, a, (uint)len);
        public static func Bind(h: long, a: byte*, len: int) -> int => bind((int)h, a, (uint)len);
        public static func Listen(h: long, backlog: int) -> int => listen((int)h, backlog);
        public static func Accept(h: long, a: byte*, len: int*) -> long => accept4((int)h, a, (uint*)len, K.SOCK_CLOEXEC);
        public static func Send(h: long, b: byte*, n: int) -> int => (int)(long)send((int)h, b, (void*)(long)n, K.MSG_NOSIGNAL);
        public static func Recv(h: long, b: byte*, n: int) -> int => (int)(long)recv((int)h, b, (void*)(long)n, 0);

        public static func SendTo(h: long, b: byte*, n: int, a: byte*, alen: int) -> int =>
            (int)(long)sendto((int)h, b, (void*)(long)n, K.MSG_NOSIGNAL, a, (uint)alen);

        public static func RecvFrom(h: long, b: byte*, n: int, a: byte*, alen: int*) -> int =>
            (int)(long)recvfrom((int)h, b, (void*)(long)n, 0, a, (uint*)alen);

        public static func Shutdown(h: long, how: int) -> int => shutdown((int)h, how);
        public static func SetOption(h: long, level: int, name: int, value: int) -> int => setsockopt((int)h, level, name, (byte*)&value, 4);

        public static func GetOption(h: long, level: int, name: int, out value: int) -> int
        {
            int v = 0;
            uint len = 4;
            int r = getsockopt((int)h, level, name, (byte*)&v, &len);
            value = v;
            return r;
        }

        public static func LocalName(h: long, a: byte*, len: int*) -> int => getsockname((int)h, a, (uint*)len);
        public static func PeerName(h: long, a: byte*, len: int*) -> int => getpeername((int)h, a, (uint*)len);

        public static func SetBlocking(h: long, on: bool) -> bool
        {
            int flags = fcntl((int)h, K.F_GETFL);
            if (flags < 0) return false;
            flags = on ? flags & ~K.O_NONBLOCK : flags | K.O_NONBLOCK;
            return fcntl((int)h, K.F_SETFL, flags) == 0;
        }

        public static func Available(h: long) -> int
        {
            int n = 0;
            if (ioctl((int)h, (void*)(long)K.FIONREAD, &n) != 0) return -1;
            return n;
        }

        // 1 = listo, 0 = tiempo agotado, -1 = error. mode: 0 leer, 1 escribir, 2 error.
        public static func Wait(h: long, mode: int, timeoutMs: int) -> int
        {
            byte* pfd = (byte*)Memory.AllocZeroed(8);   // struct pollfd { int fd; short events; short revents; }
            *(int*)pfd = (int)h;
            *(short*)(pfd + 4) = (short)(mode == 0 ? K.POLLIN : (mode == 1 ? K.POLLOUT : K.POLLPRI));
            long deadline = Environment.TickCount64() + timeoutMs;
            int r;
            for (;;)
            {
                int t = timeoutMs;
                if (timeoutMs >= 0)
                {
                    long left = deadline - Environment.TickCount64();
                    t = left > 0 ? (int)left : 0;
                }
                r = poll(pfd, (void*)(long)1, t);
                if (r >= 0 || LastError() != K.EINTR) break;
            }
            Memory.Free(pfd);
            return r > 0 ? 1 : r;
        }

        public static func GetAddrInfo(node: byte*, hints: byte*, result: byte**) -> int => getaddrinfo(node, null, hints, result);
        public static func FreeAddrInfo(ai: byte*) { freeaddrinfo(ai); }
        public static func HostName(buf: byte*, len: int) -> int => gethostname(buf, (void*)(long)len);
    }
#endif

    // ======================================================================= errores

    public static class Net
    {
        // Traduce un código de errno / WSAGetLastError / getaddrinfo.
        public static func FromNative(code: int) -> SocketError
        {
            if (code == 0) return SocketError.Success;
            if (code == K.EWOULDBLOCK || code == K.EAGAIN) return SocketError.WouldBlock;
            if (code == K.EINPROGRESS || code == K.EALREADY) return SocketError.InProgress;
            if (code == K.ETIMEDOUT) return SocketError.TimedOut;
            if (code == K.ECONNREFUSED) return SocketError.ConnectionRefused;
            if (code == K.ECONNRESET) return SocketError.ConnectionReset;
            if (code == K.ECONNABORTED) return SocketError.ConnectionAborted;
            if (code == K.ENOTCONN) return SocketError.NotConnected;
            if (code == K.ESHUTDOWN || code == K.EPIPE) return SocketError.Shutdown;
            if (code == K.EADDRINUSE) return SocketError.AddressInUse;
            if (code == K.EADDRNOTAVAIL) return SocketError.AddressNotAvailable;
            if (code == K.ENETUNREACH) return SocketError.NetworkUnreachable;
            if (code == K.EHOSTUNREACH) return SocketError.HostUnreachable;
            if (code == K.EACCES || code == K.EPERM) return SocketError.AccessDenied;
            if (code == K.EINVAL) return SocketError.InvalidArgument;
            if (code == K.EINTR) return SocketError.Interrupted;
            if (code == K.EBADF || code == K.ENOTSOCK) return SocketError.InvalidSocket;
            if (code == K.EAFNOSUPPORT) return SocketError.Unsupported;
            if (code == K.HOST_NOT_FOUND || code == K.TRY_AGAIN || code == K.NO_RECOVERY || code == K.NO_DATA)
                return SocketError.HostNotFound;
            return SocketError.Other;
        }

        // Descripción en español (cadena constante: no se libera).
        public static func Describe(e: SocketError) -> string
        {
            switch (e)
            {
                case SocketError.Success: return "sin error";
                case SocketError.WouldBlock: return "la operación se bloquearía";
                case SocketError.InProgress: return "operación en curso";
                case SocketError.TimedOut: return "tiempo de espera agotado";
                case SocketError.ConnectionRefused: return "conexión rechazada";
                case SocketError.ConnectionReset: return "el otro extremo reinició la conexión";
                case SocketError.ConnectionAborted: return "conexión abortada";
                case SocketError.NotConnected: return "el socket no está conectado";
                case SocketError.Shutdown: return "el socket está cerrado para esta operación";
                case SocketError.AddressInUse: return "la dirección ya está en uso";
                case SocketError.AddressNotAvailable: return "dirección no disponible";
                case SocketError.NetworkUnreachable: return "red inalcanzable";
                case SocketError.HostUnreachable: return "equipo inalcanzable";
                case SocketError.HostNotFound: return "no se encontró el equipo";
                case SocketError.AccessDenied: return "permiso denegado";
                case SocketError.InvalidArgument: return "argumento no válido";
                case SocketError.Interrupted: return "llamada interrumpida";
                case SocketError.InvalidSocket: return "socket no válido";
                case SocketError.Unsupported: return "familia de direcciones no soportada";
                case SocketError.InvalidUrl: return "URL no válida";
                case SocketError.ProtocolError: return "respuesta del servidor no válida";
                case SocketError.TlsError: return "error de TLS";
                case SocketError.CertificateError: return "certificado no válido";
                case SocketError.TlsUnavailable: return "TLS no disponible";
                default: return "error de red";
            }
        }

        // Inicializa la red (WSAStartup en Windows). Se llama sola al crear sockets o resolver nombres.
        public static func Startup() { Sys.Startup(); }

        // Valor de un dígito hexadecimal (-1 si no lo es).
        public static func Hex(c: byte) -> int
        {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            return -1;
        }

        // Entero decimal sin signo (solo dígitos). false si está vacío, tiene otros caracteres o supera 'max'.
        public static func ParseDecimal(s: string, max: long, out value: long) -> bool
        {
            value = 0;
            if (s.Length == 0 || s.Length > 18) return false;
            long v = 0;
            for (int i = 0; i < s.Length; i++)
            {
                if (s[i] < '0' || s[i] > '9') return false;
                v = v * 10 + (s[i] - '0');
            }
            if (v > max) return false;
            value = v;
            return true;
        }
    }

    // ======================================================================= direcciones

    // Dirección IPv4 o IPv6 (tipo valor). Los 16 bytes se guardan en orden de red en hi/lo;
    // una IPv4 ocupa los 4 primeros.
    public memory_unsafe struct IPAddress
    {
        private var family: AddressFamily;
        private var hi: ulong;
        private var lo: ulong;
        private var scope: uint;

        public prop Family: AddressFamily => family;
        public prop IsIPv4: bool => family == AddressFamily.InterNetwork;
        public prop IsIPv6: bool => family == AddressFamily.InterNetworkV6;
        public prop IsValid: bool => family != AddressFamily.Unspecified;
        // Índice de interfaz de IPv6 (la parte '%n' de "fe80::1%2").
        public prop ScopeId: uint => scope;
        public prop ByteCount: int => family == AddressFamily.InterNetworkV6 ? 16 : (family == AddressFamily.InterNetwork ? 4 : 0);

        public static func V4(a: int, b: int, c: int, d: int) -> IPAddress
        {
            IPAddress r = new IPAddress();
            r.family = AddressFamily.InterNetwork;
            r.hi = ((ulong)(a & 255) << 56) | ((ulong)(b & 255) << 48) | ((ulong)(c & 255) << 40) | ((ulong)(d & 255) << 32);
            return r;
        }

        // IPv6 a partir de sus dos mitades de 64 bits (orden de red).
        public static func V6(high: ulong, low: ulong) -> IPAddress
        {
            IPAddress r = new IPAddress();
            r.family = AddressFamily.InterNetworkV6;
            r.hi = high;
            r.lo = low;
            return r;
        }

        // 4 bytes = IPv4, 16 bytes = IPv6 (orden de red). Otro tamaño devuelve una dirección no válida.
        public static func FromBytes(bytes: byte*, count: int) -> IPAddress
        {
            IPAddress r = new IPAddress();
            if (count != 4 && count != 16) return r;
            r.family = count == 4 ? AddressFamily.InterNetwork : AddressFamily.InterNetworkV6;
            for (int i = 0; i < count; i++)
            {
                if (i < 8) r.hi |= (ulong)bytes[i] << ((7 - i) * 8);
                else r.lo |= (ulong)bytes[i] << ((15 - i) * 8);
            }
            return r;
        }

        public static prop Any: IPAddress => V4(0, 0, 0, 0);
        public static prop Loopback: IPAddress => V4(127, 0, 0, 1);
        public static prop Broadcast: IPAddress => V4(255, 255, 255, 255);
        public static prop IPv6Any: IPAddress => V6(0, 0);
        public static prop IPv6Loopback: IPAddress => V6(0, 1);
        public static prop None: IPAddress => new IPAddress();

        // Byte 'i' en orden de red (0..ByteCount-1).
        public func GetByte(i: int) -> int
        {
            if (i < 0 || i >= 16) return 0;
            return i < 8 ? (int)((hi >> ((7 - i) * 8)) & 255) : (int)((lo >> ((15 - i) * 8)) & 255);
        }

        // Copia los bytes en 'dst' (ByteCount bytes).
        public func CopyTo(dst: byte*)
        {
            int n = ByteCount;
            for (int i = 0; i < n; i++) dst[i] = (byte)GetByte(i);
        }

        public func WithScope(scopeId: uint) -> IPAddress
        {
            IPAddress r = this;
            r.scope = scopeId;
            return r;
        }

        public prop IsLoopback: bool => (family == AddressFamily.InterNetwork && (hi >> 56) == 127) ||
                                  (family == AddressFamily.InterNetworkV6 && hi == 0 && lo == 1) ||
                                  (IsIPv4MappedToIPv6 && ((lo >> 24) & 255) == 127);
        public prop IsAny: bool => family != AddressFamily.Unspecified && hi == 0 && lo == 0;
        public prop IsIPv4MappedToIPv6: bool => family == AddressFamily.InterNetworkV6 && hi == 0 && (lo >> 32) == 0xffff;
        public prop IsIPv6LinkLocal: bool => family == AddressFamily.InterNetworkV6 && (hi >> 54) == 0x3fa;

        // ::ffff:a.b.c.d -> a.b.c.d (las demás direcciones se devuelven igual).
        public func MapToIPv4() -> IPAddress
        {
            if (!IsIPv4MappedToIPv6) return this;
            IPAddress r = new IPAddress();
            r.family = AddressFamily.InterNetwork;
            r.hi = (lo & 0xffffffff) << 32;
            return r;
        }

        // a.b.c.d -> ::ffff:a.b.c.d
        public func MapToIPv6() -> IPAddress
        {
            if (family != AddressFamily.InterNetwork) return this;
            return V6(0, (ulong)0xffff00000000 | (hi >> 32));
        }

        public operator ==(a: IPAddress, b: IPAddress) -> bool => a.family == b.family && a.hi == b.hi && a.lo == b.lo && a.scope == b.scope;
        public operator !=(a: IPAddress, b: IPAddress) -> bool => !(a == b);
        public func Equals(other: IPAddress) -> bool => this == other;

        // ---------------------------------------------------------------- análisis

        // Acepta "a.b.c.d", IPv6 ("::1", "fe80::1%3", "::ffff:1.2.3.4") y IPv6 entre corchetes.
        public static func TryParse(text: string, out address: IPAddress) -> bool
        {
            address = new IPAddress();
            string s = text;
            bool bracket = false;
            if (s.Length >= 2 && s[0] == '[' && s[s.Length - 1] == ']')
            {
                s = s.Substring(1, s.Length - 2);
                bracket = true;
            }
            if (!s.Contains(":"))
            {
                if (bracket) return false;
                ulong v4 = 0;
                if (!ParseV4(s, out v4)) return false;
                address.family = AddressFamily.InterNetwork;
                address.hi = v4 << 32;
                return true;
            }
            uint scopeId = 0;
            int pct = s.IndexOf("%");
            if (pct >= 0)
            {
                long sc = 0;
                if (!Net.ParseDecimal(s.Substring(pct + 1), 0xffffffff, out sc)) return false;
                scopeId = (uint)sc;
                s = s.Substring(0, pct);
            }
            ulong h = 0, l = 0;
            if (!ParseV6(s, out h, out l)) return false;
            address.family = AddressFamily.InterNetworkV6;
            address.hi = h;
            address.lo = l;
            address.scope = scopeId;
            return true;
        }

        // Como TryParse, pero lanza FormatException si el texto no es una dirección.
        public static func Parse(text: string) -> IPAddress
        {
            IPAddress a;
            if (!TryParse(text, out a)) throw new FormatException("IPAddress.Parse: dirección no válida");
            return a;
        }

        // IPv4 decimal estricta: cuatro partes 0..255 sin ceros a la izquierda. Resultado en 32 bits.
        static func ParseV4(s: string, out bits: ulong) -> bool
        {
            bits = 0;
            ulong v = 0;
            int parts = 0, digits = 0, value = 0, first = 0;
            for (int i = 0; i <= s.Length; i++)
            {
                if (i == s.Length || s[i] == '.')
                {
                    if (digits == 0 || (digits > 1 && first == 0)) return false;
                    v = (v << 8) | (ulong)value;
                    parts++;
                    digits = 0;
                    value = 0;
                    continue;
                }
                if (s[i] < '0' || s[i] > '9') return false;
                int d = s[i] - '0';
                if (digits == 0) first = d;
                value = value * 10 + d;
                digits++;
                if (value > 255) return false;
            }
            if (parts != 4) return false;
            bits = v;
            return true;
        }

        // Grupos hexadecimales separados por ':' (sin '::'). Devuelve cuántas palabras escribió o -1.
        static func ParseGroups(part: string, words: int*, allowV4: bool) -> int
        {
            if (part.Length == 0) return 0;
            int n = 0, start = 0;
            for (int i = 0; i <= part.Length; i++)
            {
                if (i < part.Length && part[i] != ':') continue;
                string g = part.Substring(start, i - start);
                start = i + 1;
                if (g.Contains("."))
                {
                    ulong v4 = 0;
                    if (!allowV4 || i != part.Length || n > 6 || !ParseV4(g, out v4)) return -1;
                    words[n++] = (int)(v4 >> 16);
                    words[n++] = (int)(v4 & 0xffff);
                    continue;
                }
                if (g.Length == 0 || g.Length > 4 || n >= 8) return -1;
                int v = 0;
                for (int j = 0; j < g.Length; j++)
                {
                    int d = Net.Hex(g[j]);
                    if (d < 0) return -1;
                    v = v * 16 + d;
                }
                words[n++] = v;
            }
            return n;
        }

        static func ParseV6(s: string, out high: ulong, out low: ulong) -> bool
        {
            high = 0;
            low = 0;
            int* w = Memory.New<int>(8);
            int* tail = Memory.New<int>(8);
            bool ok;
            int dbl = s.IndexOf("::");
            if (dbl < 0)
            {
                ok = ParseGroups(s, w, true) == 8;
            }
            else
            {
                int nh = s.IndexOf("::", dbl + 1) >= 0 ? -1 : ParseGroups(s.Substring(0, dbl), w, false);
                int nt = nh < 0 ? -1 : ParseGroups(s.Substring(dbl + 2), tail, true);
                ok = nh >= 0 && nt >= 0 && nh + nt <= 7;
                if (ok)
                    for (int i = 0; i < nt; i++) w[8 - nt + i] = tail[i];
            }
            if (ok)
                for (int i = 0; i < 4; i++)
                {
                    high = (high << 16) | (ulong)w[i];
                    low = (low << 16) | (ulong)w[i + 4];
                }
            Memory.Free(w);
            Memory.Free(tail);
            return ok;
        }

        // ---------------------------------------------------------------- formato

        // Texto de la dirección (copia). IPv6 en forma canónica (RFC 5952).
        public func ToString() -> string
        {
            StringBuilder sb = new StringBuilder();
            AppendTo(sb);
            string r = sb.ToString();
            delete sb;
            return r;
        }

        public func AppendTo(sb: StringBuilder)
        {
            if (family == AddressFamily.InterNetwork)
            {
                AppendV4(sb, (uint)(hi >> 32));
                return;
            }
            if (family != AddressFamily.InterNetworkV6)
            {
                sb.Append("(ninguna)");
                return;
            }
            if (IsIPv4MappedToIPv6)
            {
                sb.Append("::ffff:");
                AppendV4(sb, (uint)(lo & 0xffffffff));
            }
            else
            {
                int* w = Memory.New<int>(8);
                for (int i = 0; i < 4; i++)
                {
                    w[i] = (int)((hi >> ((3 - i) * 16)) & 0xffff);
                    w[i + 4] = (int)((lo >> ((3 - i) * 16)) & 0xffff);
                }
                // El tramo de ceros más largo (de al menos 2 grupos) se abrevia con "::".
                int bestStart = -1, bestLen = 0;
                for (int i = 0; i < 8;)
                {
                    if (w[i] != 0)
                    {
                        i++;
                        continue;
                    }
                    int j = i;
                    while (j < 8 && w[j] == 0) j++;
                    if (j - i > bestLen && j - i >= 2)
                    {
                        bestStart = i;
                        bestLen = j - i;
                    }
                    i = j;
                }
                for (int i = 0; i < 8; i++)
                {
                    if (i == bestStart)
                    {
                        sb.Append("::");
                        i += bestLen - 1;
                        continue;
                    }
                    if (i > 0 && i != bestStart + bestLen) sb.Append(":");
                    AppendHex(sb, w[i]);
                }
                Memory.Free(w);
            }
            if (scope != 0)
            {
                sb.Append("%");
                sb.Append((ulong)scope);
            }
        }

        static func AppendV4(sb: StringBuilder, v: uint)
        {
            sb.Append((long)((v >> 24) & 255)).Append(".").Append((long)((v >> 16) & 255)).Append(".");
            sb.Append((long)((v >> 8) & 255)).Append(".").Append((long)(v & 255));
        }

        static func AppendHex(sb: StringBuilder, v: int)
        {
            string digits = "0123456789abcdef";
            bool started = false;
            for (int shift = 12; shift >= 0; shift -= 4)
            {
                int d = (v >> shift) & 15;
                if (d == 0 && !started && shift > 0) continue;
                started = true;
                sb.Append(digits.Substring(d, 1));
            }
        }
    }

    // Dirección + puerto.
    public struct IPEndPoint
    {
        public var Address: IPAddress;
        public var Port: int;

        public init(address: IPAddress, port: int)
        {
            Address = address;
            Port = port;
        }

        public prop Family: AddressFamily => Address.Family;

        public operator ==(a: IPEndPoint, b: IPEndPoint) -> bool => a.Address == b.Address && a.Port == b.Port;
        public operator !=(a: IPEndPoint, b: IPEndPoint) -> bool => !(a == b);

        // "1.2.3.4:80" o "[::1]:80" (copia).
        public func ToString() -> string
        {
            StringBuilder sb = new StringBuilder();
            if (Address.IsIPv6) sb.Append("[");
            Address.AppendTo(sb);
            if (Address.IsIPv6) sb.Append("]");
            sb.Append(":").Append((long)Port);
            string r = sb.ToString();
            delete sb;
            return r;
        }

        // Acepta "1.2.3.4:80" y "[::1]:80" (solo direcciones numéricas).
        public static func TryParse(text: string, out endPoint: IPEndPoint) -> bool
        {
            endPoint = new IPEndPoint(IPAddress.None, 0);
            int colon = text.LastIndexOf(":");
            if (colon <= 0) return false;
            string host = text.Substring(0, colon);
            if (host.Contains(":") && !(host.StartsWith("[") && host.EndsWith("]"))) return false;
            long port = 0;
            IPAddress a;
            if (!Net.ParseDecimal(text.Substring(colon + 1), 65535, out port) || !IPAddress.TryParse(host, out a)) return false;
            endPoint = new IPEndPoint(a, (int)port);
            return true;
        }
    }

    // Conversión entre IPEndPoint y sockaddr_in / sockaddr_in6 (misma disposición en Linux y Windows).
    memory_unsafe static class SockAddr
    {
        public const int Size = 128;   // sockaddr_storage

        public static func Write(ep: IPEndPoint, p: byte*) -> int
        {
            Memory.Set(p, 0, Size);
            p[2] = (byte)((ep.Port >> 8) & 255);
            p[3] = (byte)(ep.Port & 255);
            if (ep.Address.IsIPv6)
            {
                *(ushort*)p = (ushort)K.AF_INET6;
                ep.Address.CopyTo(p + 8);
                *(uint*)(p + 24) = ep.Address.ScopeId;
                return 28;
            }
            *(ushort*)p = (ushort)K.AF_INET;
            ep.Address.CopyTo(p + 4);
            return 16;
        }

        public static func Read(p: byte*, out ep: IPEndPoint) -> bool
        {
            int family = *(ushort*)p;
            int port = (p[2] << 8) | p[3];
            if (family == K.AF_INET)
            {
                ep = new IPEndPoint(IPAddress.FromBytes(p + 4, 4), port);
                return true;
            }
            if (family == K.AF_INET6)
            {
                ep = new IPEndPoint(IPAddress.FromBytes(p + 8, 16).WithScope(*(uint*)(p + 24)), port);
                return true;
            }
            ep = new IPEndPoint(IPAddress.None, 0);
            return false;
        }

        public static func FamilyCode(f: AddressFamily) -> int => f == AddressFamily.InterNetworkV6 ? K.AF_INET6 : K.AF_INET;
    }

    // ======================================================================= DNS

    public memory_unsafe static class Dns
    {
        static var lastError: SocketError;
        static var lastNative: int;

        public static prop LastError: SocketError => lastError;
        public static prop NativeError: int => lastNative;
        public static prop ErrorMessage: string => Net.Describe(lastError);

        // Añade a 'results' todas las direcciones de 'host' (IPv4 e IPv6, sin repetir, en el orden
        // del sistema). Una dirección numérica se devuelve tal cual sin consultar el DNS.
        public static func GetHostAddresses(host: string, results: List<IPAddress>) -> bool
        {
            lastError = SocketError.Success;
            lastNative = 0;
            IPAddress literal;
            if (IPAddress.TryParse(host, out literal))
            {
                results.Add(literal);
                return true;
            }
            if (host.Length == 0)
            {
                lastError = SocketError.HostNotFound;
                return false;
            }
            Sys.Startup();
            string name = host.ToCString();
            byte* hints = (byte*)Memory.AllocZeroed(64);
            *(int*)(hints + 4) = K.AF_UNSPEC;
            *(int*)(hints + 8) = K.SOCK_STREAM;     // una entrada por dirección (no por protocolo)
            byte* list = null;
            int r = Sys.GetAddrInfo(name.Ptr, hints, &list);
            Memory.Free(hints);
            String.Free(name);
            if (r != 0)
            {
                // Los códigos EAI_* de bionic (Android) coinciden con valores de errno: no se traducen.
                lastNative = r;
                lastError = SocketError.HostNotFound;
                return false;
            }
            int found = 0;
            for (byte* ai = list; ai != null; ai = *(byte**)(ai + K.AiNext))
            {
                byte* sa = *(byte**)(ai + K.AiAddr);
                IPEndPoint ep;
                if (sa == null || !SockAddr.Read(sa, out ep)) continue;
                bool dup = false;
                for (int i = 0; i < results.Count; i++)
                    if (results[i] == ep.Address) dup = true;
                if (!dup) results.Add(ep.Address);
                found++;
            }
            if (list != null) Sys.FreeAddrInfo(list);
            if (found == 0)
            {
                lastError = SocketError.HostNotFound;
                return false;
            }
            return true;
        }

        // Primera dirección de 'host', preferentemente IPv4.
        public static func TryResolve(host: string, out address: IPAddress) -> bool => TryResolve(host, AddressFamily.Unspecified, out address);

        // Primera dirección de la familia pedida (Unspecified = IPv4 si hay, si no IPv6).
        public static func TryResolve(host: string, family: AddressFamily, out address: IPAddress) -> bool
        {
            address = IPAddress.None;
            List<IPAddress> all = new List<IPAddress>();
            bool ok = GetHostAddresses(host, all);
            if (ok)
            {
                ok = false;
                AddressFamily want = family == AddressFamily.Unspecified ? AddressFamily.InterNetwork : family;
                for (int i = 0; i < all.Count && !ok; i++)
                    if (all[i].Family == want)
                    {
                        address = all[i];
                        ok = true;
                    }
                if (!ok && family == AddressFamily.Unspecified && all.Count > 0)
                {
                    address = all[0];
                    ok = true;
                }
                if (!ok) lastError = SocketError.HostNotFound;
            }
            delete all;
            return ok;
        }

        // Nombre de este equipo (copia).
        public static func GetHostName() -> string
        {
            Sys.Startup();
            byte* buf = (byte*)Memory.AllocZeroed(257);
            if (Sys.HostName(buf, 256) != 0) buf[0] = 0;
            string r = String.Copy(String.FromCString(buf));
            Memory.Free(buf);
            return r;
        }
    }

    // ======================================================================= Socket

    // Socket de bajo nivel. Por defecto es bloqueante y sin tiempos de espera (-1 = infinito).
    // Con ReceiveTimeout / SendTimeout (ms), las operaciones bloqueantes esperan como mucho ese
    // tiempo y fallan con SocketError.TimedOut. Con Blocking = false, las operaciones que no pueden
    // completarse fallan con SocketError.WouldBlock (o InProgress en Connect): usa Poll para esperar.
    public memory_unsafe class Socket
    {
        var handle: long = -1;
        var family: AddressFamily;
        var type: SocketType;
        var blocking: bool = true;
        var receiveTimeout: int = -1;
        var sendTimeout: int = -1;
        var error: SocketError;
        var nativeError: int;

        public init(addressFamily: AddressFamily, socketType: SocketType)
        {
            family = addressFamily == AddressFamily.InterNetworkV6 ? AddressFamily.InterNetworkV6 : AddressFamily.InterNetwork;
            type = socketType;
            Sys.Startup();
            bool dgram = type == SocketType.Datagram;
            handle = Sys.Open(SockAddr.FamilyCode(family), dgram ? K.SOCK_DGRAM : K.SOCK_STREAM, dgram ? K.IPPROTO_UDP : K.IPPROTO_TCP);
            if (handle == -1) FailNative();
        }

        init(acceptedHandle: long, addressFamily: AddressFamily, socketType: SocketType)
        {
            handle = acceptedHandle;
            family = addressFamily;
            type = socketType;
        }

        deinit { Close(); }

        public prop IsValid: bool => handle != -1;
        // Descriptor (Linux) o SOCKET (Windows); -1 si está cerrado.
        public prop Handle: long => handle;
        public prop Family: AddressFamily => family;
        public prop Type: SocketType => type;
        public prop Error: SocketError => error;
        public prop NativeError: int => nativeError;
        public prop ErrorMessage: string => Net.Describe(error);

        // Tiempos de espera en milisegundos (-1 = sin límite).
        public prop ReceiveTimeout: int { get => receiveTimeout; set { receiveTimeout = value; } }
        public prop SendTimeout: int { get => sendTimeout; set { sendTimeout = value; } }

        public prop Blocking: bool
        {
            get => blocking;
            set
            {
                if (handle == -1) return;
                if (Sys.SetBlocking(handle, value)) blocking = value;
                else FailNative();
            }
        }

        func Fail(e: SocketError, native: int)
        {
            error = e;
            nativeError = native;
        }

        func FailNative()
        {
            int code = Sys.LastError();
            Fail(Net.FromNative(code), code);
        }

        func Check() -> bool
        {
            if (handle != -1) return true;
            Fail(SocketError.InvalidSocket, 0);
            return false;
        }

        func WaitFor(mode: SelectMode, timeoutMs: int) -> bool
        {
            int r = Sys.Wait(handle, (int)mode, timeoutMs);
            if (r > 0) return true;
            if (r == 0) Fail(SocketError.TimedOut, 0);
            else FailNative();
            return false;
        }

        // Espera hasta 'timeoutMs' (-1 = sin límite, 0 = consultar) a que el socket esté listo:
        // Read = hay datos, una conexión que aceptar o el otro extremo cerró; Write = se puede
        // enviar o terminó un Connect no bloqueante; Error = hay una condición de error o datos urgentes.
        public func Poll(timeoutMs: int, mode: SelectMode) -> bool
        {
            if (!Check()) return false;
            int r = Sys.Wait(handle, (int)mode, timeoutMs);
            if (r < 0)
            {
                FailNative();
                return false;
            }
            error = SocketError.Success;
            return r > 0;
        }

        public func Connect(remote: IPEndPoint) -> bool => Connect(remote, -1);

        // Conecta esperando como mucho 'timeoutMs' (-1 = lo que tarde el sistema). En modo no bloqueante
        // y sin tiempo de espera devuelve false con SocketError.InProgress: espera con Poll(.., Write)
        // y consulta el resultado con FinishConnect. Tras un fallo, cierra el socket.
        public func Connect(remote: IPEndPoint, timeoutMs: int) -> bool
        {
            if (!Check()) return false;
            byte* sa = (byte*)Memory.Alloc(SockAddr.Size);
            int len = SockAddr.Write(remote, sa);
            bool wait = timeoutMs >= 0;
            if (wait && blocking && !Sys.SetBlocking(handle, false))
            {
                Memory.Free(sa);
                FailNative();
                return false;
            }
            int r = Sys.Connect(handle, sa, len);
            int code = r == 0 ? 0 : Sys.LastError();
            Memory.Free(sa);
            bool ok = r == 0;
            if (!ok)
            {
                SocketError e = Net.FromNative(code);
                if ((e == SocketError.InProgress || e == SocketError.WouldBlock) && wait)
                    ok = WaitFor(SelectMode.Write, timeoutMs) && FinishConnect();
                else
                    Fail(e == SocketError.WouldBlock ? SocketError.InProgress : e, code);
            }
            if (wait && blocking) Sys.SetBlocking(handle, true);
            if (ok) error = SocketError.Success;
            return ok;
        }

        // Resultado de un Connect no bloqueante después de que Poll(.., Write) devolviera true.
        public func FinishConnect() -> bool
        {
            if (!Check()) return false;
            int so = 0;
            if (Sys.GetOption(handle, K.SOL_SOCKET, K.SO_ERROR, out so) != 0)
            {
                FailNative();
                return false;
            }
            if (so != 0)
            {
                Fail(Net.FromNative(so), so);
                return false;
            }
            error = SocketError.Success;
            return true;
        }

        public func Bind(local: IPEndPoint) -> bool
        {
            if (!Check()) return false;
            byte* sa = (byte*)Memory.Alloc(SockAddr.Size);
            int len = SockAddr.Write(local, sa);
            int r = Sys.Bind(handle, sa, len);
            Memory.Free(sa);
            if (r != 0)
            {
                FailNative();
                return false;
            }
            error = SocketError.Success;
            return true;
        }

        public func Listen(backlog: int) -> bool
        {
            if (!Check()) return false;
            if (Sys.Listen(handle, backlog) != 0)
            {
                FailNative();
                return false;
            }
            error = SocketError.Success;
            return true;
        }

        // Acepta una conexión entrante (null si falla). El socket devuelto es bloqueante.
        public func Accept() -> Socket
        {
            if (!Check()) return null;
            if (blocking && receiveTimeout >= 0 && !WaitFor(SelectMode.Read, receiveTimeout)) return null;
            byte* sa = (byte*)Memory.Alloc(SockAddr.Size);
            long h;
            for (;;)
            {
                int len = SockAddr.Size;
                h = Sys.Accept(handle, sa, &len);
                if (h != -1) break;
                int code = Sys.LastError();
                if (code == K.EINTR) continue;
                Memory.Free(sa);
                Fail(Net.FromNative(code), code);
                return null;
            }
            Memory.Free(sa);
            Sys.SetBlocking(h, true);   // en Windows hereda el modo del socket que escucha
            error = SocketError.Success;
            return new Socket(h, family, type);
        }

        // Envía hasta 'length' bytes; devuelve cuántos se enviaron o -1.
        public func Send(data: byte*, length: int) -> int
        {
            if (!Check()) return -1;
            if (blocking && sendTimeout >= 0 && !WaitFor(SelectMode.Write, sendTimeout)) return -1;
            for (;;)
            {
                int n = Sys.Send(handle, data, length);
                if (n >= 0)
                {
                    error = SocketError.Success;
                    return n;
                }
                int code = Sys.LastError();
                if (code == K.EINTR) continue;
                Fail(Net.FromNative(code), code);
                return -1;
            }
        }

        // Envía todos los bytes (en modo no bloqueante espera con Poll lo que haga falta).
        public func SendAll(data: byte*, length: int) -> bool
        {
            int sent = 0;
            while (sent < length)
            {
                int n = Send(data + sent, length - sent);
                if (n < 0)
                {
                    if (error == SocketError.WouldBlock && WaitFor(SelectMode.Write, sendTimeout)) continue;
                    return false;
                }
                sent += n;
            }
            return true;
        }

        public func SendAll(text: string) -> bool => SendAll(text.Ptr, (int)text.Length);

        // Recibe hasta 'capacity' bytes. Devuelve cuántos llegaron, 0 si el otro extremo cerró
        // la conexión o -1 si hubo un error (WouldBlock en modo no bloqueante, TimedOut...).
        public func Receive(buffer: byte*, capacity: int) -> int
        {
            if (!Check()) return -1;
            if (blocking && receiveTimeout >= 0 && !WaitFor(SelectMode.Read, receiveTimeout)) return -1;
            for (;;)
            {
                int n = Sys.Recv(handle, buffer, capacity);
                if (n >= 0)
                {
                    error = SocketError.Success;
                    return n;
                }
                int code = Sys.LastError();
                if (code == K.EINTR) continue;
                Fail(Net.FromNative(code), code);
                return -1;
            }
        }

        // Datagramas (UDP).
        public func SendTo(data: byte*, length: int, remote: IPEndPoint) -> int
        {
            if (!Check()) return -1;
            if (blocking && sendTimeout >= 0 && !WaitFor(SelectMode.Write, sendTimeout)) return -1;
            byte* sa = (byte*)Memory.Alloc(SockAddr.Size);
            int alen = SockAddr.Write(remote, sa);
            int n;
            for (;;)
            {
                n = Sys.SendTo(handle, data, length, sa, alen);
                if (n >= 0 || Sys.LastError() != K.EINTR) break;
            }
            if (n < 0) FailNative();
            else error = SocketError.Success;
            Memory.Free(sa);
            return n;
        }

        // Recibe un datagrama (si no cabe, se trunca a 'capacity'). -1 si hay error.
        public func ReceiveFrom(buffer: byte*, capacity: int, out remote: IPEndPoint) -> int
        {
            remote = new IPEndPoint(IPAddress.None, 0);
            if (!Check()) return -1;
            if (blocking && receiveTimeout >= 0 && !WaitFor(SelectMode.Read, receiveTimeout)) return -1;
            byte* sa = (byte*)Memory.AllocZeroed(SockAddr.Size);
            int n;
            for (;;)
            {
                int alen = SockAddr.Size;
                n = Sys.RecvFrom(handle, buffer, capacity, sa, &alen);
                if (n >= 0 || Sys.LastError() != K.EINTR) break;
            }
            if (n < 0) FailNative();
            else
            {
                error = SocketError.Success;
                SockAddr.Read(sa, out remote);
            }
            Memory.Free(sa);
            return n;
        }

        // Bytes que se pueden leer sin bloquear (-1 si hay error).
        public prop Available: int
        {
            get
            {
                if (!Check()) return -1;
                int n = Sys.Available(handle);
                if (n < 0) FailNative();
                return n;
            }
        }

        func SetFlag(level: int, name: int, on: bool) -> bool
        {
            if (!Check()) return false;
            if (Sys.SetOption(handle, level, name, on ? 1 : 0) != 0)
            {
                FailNative();
                return false;
            }
            return true;
        }

        // Desactiva el algoritmo de Nagle (envía los paquetes pequeños sin esperar).
        public func SetNoDelay(on: bool) -> bool => SetFlag(K.IPPROTO_TCP, K.TCP_NODELAY, on);
        public func SetReuseAddress(on: bool) -> bool => SetFlag(K.SOL_SOCKET, K.SO_REUSEADDR, on);
        public func SetBroadcast(on: bool) -> bool => SetFlag(K.SOL_SOCKET, K.SO_BROADCAST, on);
        public func SetKeepAlive(on: bool) -> bool => SetFlag(K.SOL_SOCKET, K.SO_KEEPALIVE, on);
        // Socket IPv6 que también acepta IPv4 (::ffff:a.b.c.d). Llamar antes de Bind.
        public func SetDualMode(on: bool) -> bool => SetFlag(K.IPPROTO_IPV6, K.IPV6_V6ONLY, !on);

        func Name(peer: bool) -> IPEndPoint
        {
            IPEndPoint ep = new IPEndPoint(IPAddress.None, 0);
            if (!Check()) return ep;
            byte* sa = (byte*)Memory.AllocZeroed(SockAddr.Size);
            int len = SockAddr.Size;
            int r = peer ? Sys.PeerName(handle, sa, &len) : Sys.LocalName(handle, sa, &len);
            if (r == 0) SockAddr.Read(sa, out ep);
            else FailNative();
            Memory.Free(sa);
            return ep;
        }

        // Dirección local (tras Bind con puerto 0, contiene el puerto asignado) y remota.
        public prop LocalEndPoint: IPEndPoint => Name(false);
        public prop RemoteEndPoint: IPEndPoint => Name(true);

        public func Shutdown(how: SocketShutdown) -> bool
        {
            if (!Check()) return false;
            if (Sys.Shutdown(handle, (int)how) != 0)
            {
                FailNative();
                return false;
            }
            return true;
        }

        public func Close()
        {
            if (handle == -1) return;
            Sys.Close(handle);
            handle = -1;
        }
    }

    // ======================================================================= TCP

    // Conexión TCP con lectura por líneas o hasta el final.
    public memory_unsafe class TcpClient
    {
        var socket: Socket;
        var receiveTimeout: int = -1;
        var sendTimeout: int = -1;
        var error: SocketError;
        var nativeError: int;
        var pending: byte*;       // bytes recibidos y aún no entregados (ReadLine)
        var pendingStart: int;
        var pendingEnd: int;
        var pendingCap: int;

        public init() { }

        // Envuelve un socket ya conectado (por ejemplo, el de Socket.Accept); pasa a ser su dueño.
        public init(connected: Socket)
        {
            socket = connected;
            receiveTimeout = connected.ReceiveTimeout;
            sendTimeout = connected.SendTimeout;
        }

        deinit
        {
            Close();
            Memory.Free(pending);
        }

        public prop Client: Socket => socket;
        public prop Connected: bool => socket != null && socket.IsValid;
        public prop Error: SocketError => error;
        public prop NativeError: int => nativeError;
        public prop ErrorMessage: string => Net.Describe(error);

        public prop ReceiveTimeout: int
        {
            get => receiveTimeout;
            set
            {
                receiveTimeout = value;
                if (socket != null) socket.ReceiveTimeout = value;
            }
        }

        public prop SendTimeout: int
        {
            get => sendTimeout;
            set
            {
                sendTimeout = value;
                if (socket != null) socket.SendTimeout = value;
            }
        }

        public prop RemoteEndPoint: IPEndPoint => socket != null ? socket.RemoteEndPoint : new IPEndPoint(IPAddress.None, 0);
        public prop LocalEndPoint: IPEndPoint => socket != null ? socket.LocalEndPoint : new IPEndPoint(IPAddress.None, 0);

        func TakeError(s: Socket)
        {
            error = s.Error;
            nativeError = s.NativeError;
        }

        func FailWith(e: SocketError) -> bool
        {
            error = e;
            nativeError = 0;
            return false;
        }

        public func Connect(host: string, port: int) -> bool => Connect(host, port, -1);

        // Resuelve 'host' y prueba sus direcciones en orden; 'timeoutMs' se aplica a cada intento.
        public func Connect(host: string, port: int, timeoutMs: int) -> bool
        {
            Close();
            List<IPAddress> addresses = new List<IPAddress>();
            if (!Dns.GetHostAddresses(host, addresses))
            {
                delete addresses;
                error = Dns.LastError;
                nativeError = Dns.NativeError;
                return false;
            }
            bool ok = false;
            for (int i = 0; i < addresses.Count && !ok; i++)
                ok = Connect(new IPEndPoint(addresses[i], port), timeoutMs);
            delete addresses;
            return ok;
        }

        public func Connect(remote: IPEndPoint) -> bool => Connect(remote, -1);

        public func Connect(remote: IPEndPoint, timeoutMs: int) -> bool
        {
            Close();
            if (remote.Port <= 0 || remote.Port > 65535 || !remote.Address.IsValid) return FailWith(SocketError.InvalidArgument);
            Socket s = new Socket(remote.Address.Family, SocketType.Stream);
            if (!s.IsValid || !s.Connect(remote, timeoutMs))
            {
                TakeError(s);
                delete s;
                return false;
            }
            s.ReceiveTimeout = receiveTimeout;
            s.SendTimeout = sendTimeout;
            socket = s;
            error = SocketError.Success;
            return true;
        }

        public func SetNoDelay(on: bool) -> bool
        {
            if (socket == null) return FailWith(SocketError.NotConnected);
            if (socket.SetNoDelay(on)) return true;
            TakeError(socket);
            return false;
        }

        // Envía hasta 'length' bytes; devuelve cuántos o -1.
        public func Send(data: byte*, length: int) -> int
        {
            if (socket == null)
            {
                FailWith(SocketError.NotConnected);
                return -1;
            }
            int n = socket.Send(data, length);
            if (n < 0) TakeError(socket);
            return n;
        }

        // Envía todos los bytes o el texto completo.
        public func Write(data: byte*, length: int) -> bool
        {
            if (socket == null) return FailWith(SocketError.NotConnected);
            if (socket.SendAll(data, length)) return true;
            TakeError(socket);
            return false;
        }

        public func Write(text: string) -> bool => Write(text.Ptr, (int)text.Length);

        public func WriteLine(text: string) -> bool => Write(text) && Write("\r\n");

        // Recibe hasta 'capacity' bytes: >0 bytes recibidos, 0 = conexión cerrada, -1 = error.
        public func Receive(buffer: byte*, capacity: int) -> int
        {
            if (pendingEnd > pendingStart)
            {
                int n = Math.Min(capacity, pendingEnd - pendingStart);
                Memory.Copy(buffer, pending + pendingStart, n);
                pendingStart += n;
                return n;
            }
            if (socket == null)
            {
                FailWith(SocketError.NotConnected);
                return -1;
            }
            int r = socket.Receive(buffer, capacity);
            if (r < 0) TakeError(socket);
            else error = SocketError.Success;
            return r;
        }

        // Una lectura: añade a 'output' lo recibido. Devuelve los bytes añadidos (0 = cerrada, -1 = error).
        public func Read(output: StringBuilder) -> int
        {
            byte* buf = (byte*)Memory.Alloc(8192);
            int n = Receive(buf, 8192);
            if (n > 0) output.Append(String.FromBytes(buf, n));
            Memory.Free(buf);
            return n;
        }

        // Lee hasta que el otro extremo cierre la conexión (copia).
        // Si se corta por un error, devuelve lo leído y Error lo indica.
        public func ReadToEnd() -> string
        {
            StringBuilder sb = new StringBuilder();
            while (Read(sb) > 0) { }
            string r = sb.ToString();
            delete sb;
            return r;
        }

        // ---- async (std.task). Implementación con hilos: cada operación bloqueante corre en un hilo
        // del grupo de tareas y 'await' no bloquea a quien espera. No uses el mismo TcpClient desde
        // dos operaciones a la vez (como en C#, una lectura y una escritura simultáneas sí valen).
        public func ConnectAsync(host: string, port: int) -> Task<bool>
        {
            TcpClient self = this;
            return Task.Run(() => self.Connect(host, port));
        }

        // Una lectura: añade a 'output' lo recibido (bytes añadidos; 0 = cerrada, -1 = error).
        public func ReadAsync(output: StringBuilder) -> Task<int>
        {
            TcpClient self = this;
            return Task.Run(() => self.Read(output));
        }

        public func ReadToEndAsync() -> Task<string>
        {
            TcpClient self = this;
            return Task.Run(() => self.ReadToEnd());
        }

        public func WriteAsync(text: string) -> Task<bool>
        {
            TcpClient self = this;
            return Task.Run(() => self.Write(text));
        }

        // Lee una línea terminada en "\n" o "\r\n" (sin el terminador; copia).
        // Devuelve false si la conexión se cerró sin más datos o hubo un error.
        public func ReadLine(out line: string) -> bool
        {
            int scanFrom = pendingStart;
            for (;;)
            {
                for (int i = scanFrom; i < pendingEnd; i++)
                {
                    if (pending[i] != '\n') continue;
                    int end = i;
                    if (end > pendingStart && pending[end - 1] == '\r') end--;
                    line = String.Copy(String.FromBytes(pending + pendingStart, end - pendingStart));
                    pendingStart = i + 1;
                    return true;
                }
                scanFrom = pendingEnd;
                if (socket == null)
                {
                    line = String.Copy("");
                    return FailWith(SocketError.NotConnected);
                }
                // Compacta y hace sitio para leer más.
                if (pendingStart > 0)
                {
                    Memory.Copy(pending, pending + pendingStart, pendingEnd - pendingStart);
                    pendingEnd -= pendingStart;
                    scanFrom -= pendingStart;
                    pendingStart = 0;
                }
                if (pendingCap - pendingEnd < 1024)
                {
                    pendingCap = pendingCap < 4096 ? 4096 : pendingCap * 2;
                    pending = (byte*)Memory.Realloc(pending, pendingCap);
                }
                int n = socket.Receive(pending + pendingEnd, pendingCap - pendingEnd);
                if (n <= 0)
                {
                    if (n < 0) TakeError(socket);
                    if (pendingEnd > pendingStart && n == 0)
                    {
                        line = String.Copy(String.FromBytes(pending + pendingStart, pendingEnd - pendingStart));
                        pendingStart = pendingEnd;
                        return true;
                    }
                    line = String.Copy("");
                    return false;
                }
                pendingEnd += n;
            }
        }

        // Bytes listos para leer sin bloquear (incluye los que ya están en el búfer de ReadLine).
        public prop Available: int
        {
            get
            {
                if (socket == null) return pendingEnd - pendingStart;
                int n = socket.Available;
                return (n < 0 ? 0 : n) + pendingEnd - pendingStart;
            }
        }

        // Cierra el envío (el otro extremo verá el final de los datos) o la recepción.
        public func Shutdown(how: SocketShutdown) -> bool
        {
            if (socket == null) return FailWith(SocketError.NotConnected);
            if (socket.Shutdown(how)) return true;
            TakeError(socket);
            return false;
        }

        public func Close()
        {
            if (socket != null) delete socket;
            socket = null;
            pendingStart = 0;
            pendingEnd = 0;
        }
    }

    // Servidor TCP: escucha en una dirección y acepta conexiones.
    public class TcpListener
    {
        var socket: Socket;
        var endpoint: IPEndPoint;
        var error: SocketError;
        var nativeError: int;

        public init(local: IPEndPoint) { endpoint = local; }
        public init(address: IPAddress, port: int) { endpoint = new IPEndPoint(address, port); }
        // Todas las interfaces IPv4.
        public init(port: int) { endpoint = new IPEndPoint(IPAddress.Any, port); }

        deinit { Stop(); }

        public prop Server: Socket => socket;
        public prop Active: bool => socket != null;
        // Tras Start, el puerto real (útil con el puerto 0 = cualquiera libre).
        public prop LocalEndPoint: IPEndPoint => endpoint;
        public prop Error: SocketError => error;
        public prop NativeError: int => nativeError;
        public prop ErrorMessage: string => Net.Describe(error);

        func Fail(s: Socket) -> bool
        {
            error = s.Error;
            nativeError = s.NativeError;
            return false;
        }

        public func Start() -> bool => Start(128);

        public func Start(backlog: int) -> bool
        {
            Stop();
            Socket s = new Socket(endpoint.Address.Family, SocketType.Stream);
            if (!s.IsValid)
            {
                Fail(s);
                delete s;
                return false;
            }
            if (K.ReuseOnListen) s.SetReuseAddress(true);
            if (!s.Bind(endpoint) || !s.Listen(backlog))
            {
                Fail(s);
                delete s;
                return false;
            }
            endpoint = s.LocalEndPoint;
            socket = s;
            error = SocketError.Success;
            return true;
        }

        // true si hay una conexión esperando (sin bloquear, o esperando hasta 'timeoutMs').
        public func Pending() -> bool => Pending(0);

        public func Pending(timeoutMs: int) -> bool
        {
            if (socket == null) return false;
            return socket.Poll(timeoutMs, SelectMode.Read);
        }

        // Acepta un socket (bloquea; null si falla).
        public func AcceptSocket() -> Socket => AcceptSocket(-1);

        // Espera como mucho 'timeoutMs' (-1 = sin límite). null con Error = TimedOut si no llega nadie.
        public func AcceptSocket(timeoutMs: int) -> Socket
        {
            if (socket == null)
            {
                error = SocketError.NotConnected;
                return null;
            }
            if (timeoutMs >= 0 && !socket.Poll(timeoutMs, SelectMode.Read))
            {
                error = socket.Error == SocketError.Success ? SocketError.TimedOut : socket.Error;
                nativeError = socket.NativeError;
                return null;
            }
            Socket s = socket.Accept();
            if (s == null) Fail(socket);
            else error = SocketError.Success;
            return s;
        }

        public func AcceptTcpClient() -> TcpClient => AcceptTcpClient(-1);

        public func AcceptTcpClient(timeoutMs: int) -> TcpClient
        {
            Socket s = AcceptSocket(timeoutMs);
            return s == null ? null : new TcpClient(s);
        }

        public func Stop()
        {
            if (socket != null) delete socket;
            socket = null;
        }
    }

    // ======================================================================= UDP

    public memory_unsafe class UdpClient
    {
        var socket: Socket;
        var error: SocketError;
        var nativeError: int;

        // Socket IPv4 sin enlazar (el sistema elige el puerto al enviar).
        public init() { socket = new Socket(AddressFamily.InterNetwork, SocketType.Datagram); }
        public init(family: AddressFamily) { socket = new Socket(family, SocketType.Datagram); }

        deinit { delete socket; }

        public prop Client: Socket => socket;
        public prop Error: SocketError => error;
        public prop NativeError: int => nativeError;
        public prop ErrorMessage: string => Net.Describe(error);
        public prop LocalEndPoint: IPEndPoint => socket.LocalEndPoint;

        public prop ReceiveTimeout: int { get => socket.ReceiveTimeout; set { socket.ReceiveTimeout = value; } }
        public prop SendTimeout: int { get => socket.SendTimeout; set { socket.SendTimeout = value; } }

        func Result(ok: bool) -> bool
        {
            error = socket.Error;
            nativeError = socket.NativeError;
            if (ok) error = SocketError.Success;
            return ok;
        }

        func Count(n: int) -> int
        {
            Result(n >= 0);
            return n;
        }

        public func Bind(local: IPEndPoint) -> bool => Result(socket.Bind(local));
        public func Bind(port: int) -> bool => Result(socket.Bind(new IPEndPoint(socket.Family == AddressFamily.InterNetworkV6 ? IPAddress.IPv6Any : IPAddress.Any, port)));
        public func SetBroadcast(on: bool) -> bool => Result(socket.SetBroadcast(on));

        // Fija el destino por defecto: Send sin dirección y solo se reciben datagramas de él.
        public func Connect(remote: IPEndPoint) -> bool => Result(socket.Connect(remote));

        public func Send(data: byte*, length: int, remote: IPEndPoint) -> int => Count(socket.SendTo(data, length, remote));
        public func Send(text: string, remote: IPEndPoint) -> int => Count(socket.SendTo(text.Ptr, (int)text.Length, remote));
        public func Send(data: byte*, length: int) -> int => Count(socket.Send(data, length));
        public func Send(text: string) -> int => Count(socket.Send(text.Ptr, (int)text.Length));

        // Recibe un datagrama en 'buffer'; -1 si hay error (TimedOut si vence ReceiveTimeout).
        public func Receive(buffer: byte*, capacity: int, out remote: IPEndPoint) -> int => Count(socket.ReceiveFrom(buffer, capacity, out remote));

        // Recibe un datagrama como texto (copia.Free; "" si falla).
        public func Receive(out text: string, out remote: IPEndPoint) -> bool
        {
            byte* buf = (byte*)Memory.Alloc(65536);
            int n = socket.ReceiveFrom(buf, 65536, out remote);
            text = String.Copy(String.FromBytes(buf, n > 0 ? n : 0));
            Memory.Free(buf);
            return Result(n >= 0);
        }

        public func Close() { socket.Close(); }
    }

    // ======================================================================= TLS

    // Funciones de lib/net/faset_tls.c (OpenSSL con dlopen en Linux, Schannel en Windows,
    // BearSSL en Android). El estado es memoria de C: Faset solo guarda el puntero.
    memory_unsafe static class TlsNative
    {
        public static extern void* faset_tls_new(long sock);
        public static extern void faset_tls_free(void* t);
        public static extern int faset_tls_client(void* t, string host, int verify, string caFile, int timeoutMs);
        public static extern int faset_tls_server(void* t, string certFile, string keyFile, int timeoutMs);
        public static extern int faset_tls_send(void* t, byte* data, int length, int timeoutMs);
        public static extern int faset_tls_recv(void* t, byte* buffer, int capacity, int timeoutMs);
        public static extern int faset_tls_pending(void* t);
        public static extern void faset_tls_shutdown(void* t, int timeoutMs);
        public static extern int faset_tls_error_kind(void* t);
        public static extern int faset_tls_native_error(void* t);
        public static extern byte* faset_tls_error_text(void* t);
        public static extern byte* faset_tls_protocol(void* t);
        public static extern byte* faset_tls_cipher(void* t);
        public static extern byte* faset_tls_backend();
        public static extern int faset_tls_available();
    }

    // Conexión cifrada con TLS (1.2 o 1.3) sobre TCP: lo que usa HttpClient para https://.
    //
    //   auto tls = new TlsStream();
    //   tls.ReceiveTimeout = 10000;
    //   if (tls.Connect("example.com", 443))
    //   {
    //       tls.Write("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n");
    //       string r = tls.ReadToEnd();
    //       println(r);
    //       String.Free(r);
    //   }
    //   else println(tls.ErrorMessage);
    //   delete tls;
    //
    // Como cliente envía el nombre del equipo (SNI) y verifica el certificado del servidor:
    // que lo firme una autoridad de confianza del sistema, que esté en fecha y que sea de ese
    // nombre. Si falla, Error = CertificateError y ErrorMessage dice por qué. Desactivar la
    // verificación (ValidateCertificate = false) deja la conexión expuesta a cualquiera que se
    // ponga en medio: úsalo solo en pruebas, nunca con datos reales.
    //
    // Como servidor (AuthenticateAsServer) usa un certificado y su clave privada en PEM
    // (Linux y Android; en Windows no está disponible).
    public memory_unsafe class TlsStream
    {
        var tcp: TcpClient;          // propio: se cierra al cerrar el TlsStream
        var native: void*;           // estado de C (faset_tls.c)
        var validate: bool = true;
        var caFile: string;          // copias propias
        var message: string;
        var protocol: string;
        var cipher: string;
        var receiveTimeout: int = -1;
        var sendTimeout: int = -1;
        var authenticated: bool;
        var server: bool;
        var error: SocketError;
        var nativeError: int;
        var pending: byte*;          // texto descifrado aún no entregado (ReadLine)
        var pendingStart: int;
        var pendingEnd: int;
        var pendingCap: int;

        // Sin conexión: usa Connect.
        public init() { Init(); }

        // Sobre una conexión TCP ya abierta (por ejemplo, la de TcpListener.AcceptTcpClient):
        // el TlsStream pasa a ser su dueño. Después llama a AuthenticateAsClient o AuthenticateAsServer.
        public init(connected: TcpClient)
        {
            Init();
            tcp = connected;
            receiveTimeout = connected.ReceiveTimeout;
            sendTimeout = connected.SendTimeout;
        }

        func Init()
        {
            caFile = String.Copy("");
            message = String.Copy("");
            protocol = String.Copy("");
            cipher = String.Copy("");
        }

        deinit
        {
            Close();
            String.Free(caFile);
            String.Free(message);
            String.Free(protocol);
            String.Free(cipher);
            Memory.Free(pending);
        }

        // Motor TLS de esta plataforma: "OpenSSL (libssl.so.3)", "Schannel" o "BearSSL".
        public static prop Backend: string => String.FromCString(TlsNative.faset_tls_backend());
        // false si no hay motor (Linux sin OpenSSL instalado).
        public static prop IsSupported: bool => TlsNative.faset_tls_available() != 0;

        // Verificar el certificado del otro extremo (true por defecto). Ponerlo a false acepta
        // CUALQUIER certificado, incluso el de un atacante: solo para pruebas.
        public prop ValidateCertificate: bool { get => validate; set { validate = value; } }

        // Archivo PEM con autoridades de confianza adicionales (además de las del sistema), por
        // ejemplo la de una red interna o la de unas pruebas. "" = solo las del sistema. No disponible en Windows.
        public prop CertificateAuthorityFile: string
        {
            get => caFile;
            set { SetText(ref caFile, value); }
        }

        // Milisegundos de espera de cada lectura o escritura, también durante la negociación (-1 = sin límite).
        public prop ReceiveTimeout: int
        {
            get => receiveTimeout;
            set
            {
                receiveTimeout = value;
                if (tcp != null) tcp.ReceiveTimeout = value;
            }
        }

        public prop SendTimeout: int
        {
            get => sendTimeout;
            set
            {
                sendTimeout = value;
                if (tcp != null) tcp.SendTimeout = value;
            }
        }

        public prop Client: TcpClient => tcp;
        public prop IsAuthenticated: bool => authenticated;
        public prop IsServer: bool => server;
        // Versión negociada ("TLSv1.3", "TLSv1.2") y suite de cifrado (nombre del motor); "" antes de negociar.
        public prop Protocol: string => protocol;
        public prop CipherSuite: string => cipher;
        public prop Error: SocketError => error;
        public prop NativeError: int => nativeError;
        // Motivo del último fallo, en español (vista: no la liberes).
        public prop ErrorMessage: string => message;

        static func SetText(ref field: string, value: string)
        {
            string v = String.Copy(value);
            String.Free(field);
            field = v;
        }

        func FailWith(e: SocketError, code: int, text: string) -> bool
        {
            error = e;
            nativeError = code;
            SetText(ref message, text);
            return false;
        }

        // Toma el error de la última llamada a faset_tls_*.
        func FailNative() -> bool
        {
            int kind = TlsNative.faset_tls_error_kind(native);
            int code = TlsNative.faset_tls_native_error(native);
            SocketError e = SocketError.TlsError;
            if (kind == 1) e = code != 0 ? Net.FromNative(code) : SocketError.ConnectionReset;
            else if (kind == 2) e = SocketError.TimedOut;
            else if (kind == 3) e = SocketError.ConnectionAborted;
            else if (kind == 5) e = SocketError.CertificateError;
            else if (kind == 6) e = SocketError.TlsUnavailable;
            else if (kind == 7) e = SocketError.InvalidArgument;
            return FailWith(e, code, String.FromCString(TlsNative.faset_tls_error_text(native)));
        }

        func Ok() -> bool
        {
            error = SocketError.Success;
            nativeError = 0;
            return true;
        }

        // Conecta por TCP con 'host' y negocia TLS como cliente con ese nombre.
        public func Connect(host: string, port: int) -> bool => Connect(host, port, receiveTimeout);

        // 'timeoutMs' se aplica a la conexión TCP (cada dirección); la negociación usa ReceiveTimeout.
        public func Connect(host: string, port: int, timeoutMs: int) -> bool
        {
            Close();
            TcpClient c = new TcpClient();
            c.ReceiveTimeout = receiveTimeout;
            c.SendTimeout = sendTimeout;
            if (!c.Connect(host, port, timeoutMs))
            {
                FailWith(c.Error, c.NativeError, Net.Describe(c.Error));
                delete c;
                return false;
            }
            tcp = c;
            return AuthenticateAsClient(host);
        }

        func Prepare() -> bool
        {
            if (tcp == null || !tcp.Connected) return FailWith(SocketError.NotConnected, 0, Net.Describe(SocketError.NotConnected));
            if (authenticated || native != null) return FailWith(SocketError.InvalidArgument, 0, "la conexión TLS ya está negociada");
            native = TlsNative.faset_tls_new(tcp.Client.Handle);
            if (native == null) return FailWith(SocketError.Other, 0, "sin memoria para TLS");
            return true;
        }

        func Negotiated()
        {
            authenticated = true;
            SetText(ref protocol, String.FromCString(TlsNative.faset_tls_protocol(native)));
            SetText(ref cipher, String.FromCString(TlsNative.faset_tls_cipher(native)));
        }

        // Negocia TLS como cliente. 'host' es el nombre que se envía (SNI) y con el que se
        // compara el certificado (puede ser una dirección IP).
        public func AuthenticateAsClient(host: string) -> bool
        {
            if (!Prepare()) return false;
            server = false;
            if (TlsNative.faset_tls_client(native, host, validate ? 1 : 0, caFile, receiveTimeout) != 0)
            {
                FailNative();
                Close();
                return false;
            }
            Negotiated();
            return Ok();
        }

        // Negocia TLS como servidor con un certificado (PEM; puede traer detrás la cadena de
        // autoridades intermedias) y su clave privada (PEM, RSA o EC).
        public func AuthenticateAsServer(certificateFile: string, privateKeyFile: string) -> bool
        {
            if (!Prepare()) return false;
            server = true;
            if (TlsNative.faset_tls_server(native, certificateFile, privateKeyFile, receiveTimeout) != 0)
            {
                FailNative();
                Close();
                return false;
            }
            Negotiated();
            return Ok();
        }

        func Check() -> bool
        {
            if (authenticated) return true;
            return FailWith(SocketError.NotConnected, 0, "la conexión TLS no está negociada");
        }

        // Cifra y envía todos los bytes; devuelve 'length' o -1.
        public func Send(data: byte*, length: int) -> int
        {
            if (!Check()) return -1;
            int n = TlsNative.faset_tls_send(native, data, length, sendTimeout);
            if (n < 0)
            {
                FailNative();
                return -1;
            }
            Ok();
            return n;
        }

        public func Write(data: byte*, length: int) -> bool => Send(data, length) >= 0;
        public func Write(text: string) -> bool => Send(text.Ptr, (int)text.Length) >= 0;
        public func WriteLine(text: string) -> bool => Write(text) && Write("\r\n");

        func RecvRaw(buffer: byte*, capacity: int) -> int
        {
            int n = TlsNative.faset_tls_recv(native, buffer, capacity, receiveTimeout);
            if (n < 0) FailNative();
            else Ok();
            return n;
        }

        // Recibe hasta 'capacity' bytes descifrados: >0 bytes, 0 = el otro extremo cerró, -1 = error.
        public func Receive(buffer: byte*, capacity: int) -> int
        {
            if (pendingEnd > pendingStart)
            {
                int n = Math.Min(capacity, pendingEnd - pendingStart);
                Memory.Copy(buffer, pending + pendingStart, n);
                pendingStart += n;
                return n;
            }
            if (!Check()) return -1;
            return RecvRaw(buffer, capacity);
        }

        // Una lectura: añade a 'output' lo recibido. Devuelve los bytes añadidos (0 = cerrada, -1 = error).
        public func Read(output: StringBuilder) -> int
        {
            byte* buf = (byte*)Memory.Alloc(16384);
            int n = Receive(buf, 16384);
            if (n > 0) output.Append(String.FromBytes(buf, n));
            Memory.Free(buf);
            return n;
        }

        // Lee hasta que el otro extremo cierre (copia). Si se corta por un error, devuelve lo leído y Error lo indica.
        public func ReadToEnd() -> string
        {
            StringBuilder sb = new StringBuilder();
            while (Read(sb) > 0) { }
            string r = sb.ToString();
            delete sb;
            return r;
        }

        // Lee una línea terminada en "\n" o "\r\n" (sin el terminador; copia).
        // Devuelve false si la conexión se cerró sin más datos o hubo un error.
        public func ReadLine(out line: string) -> bool
        {
            int scanFrom = pendingStart;
            for (;;)
            {
                for (int i = scanFrom; i < pendingEnd; i++)
                {
                    if (pending[i] != '\n') continue;
                    int end = i;
                    if (end > pendingStart && pending[end - 1] == '\r') end--;
                    line = String.Copy(String.FromBytes(pending + pendingStart, end - pendingStart));
                    pendingStart = i + 1;
                    return true;
                }
                scanFrom = pendingEnd;
                if (!Check())
                {
                    line = String.Copy("");
                    return false;
                }
                if (pendingStart > 0)
                {
                    Memory.Copy(pending, pending + pendingStart, pendingEnd - pendingStart);
                    pendingEnd -= pendingStart;
                    scanFrom -= pendingStart;
                    pendingStart = 0;
                }
                if (pendingCap - pendingEnd < 1024)
                {
                    pendingCap = pendingCap < 4096 ? 4096 : pendingCap * 2;
                    pending = (byte*)Memory.Realloc(pending, pendingCap);
                }
                int n = RecvRaw(pending + pendingEnd, pendingCap - pendingEnd);
                if (n <= 0)
                {
                    if (pendingEnd > pendingStart && n == 0)
                    {
                        line = String.Copy(String.FromBytes(pending + pendingStart, pendingEnd - pendingStart));
                        pendingStart = pendingEnd;
                        return true;
                    }
                    line = String.Copy("");
                    return false;
                }
                pendingEnd += n;
            }
        }

        // Bytes descifrados que se pueden leer sin esperar.
        public prop Available: int => pendingEnd - pendingStart + (native != null ? TlsNative.faset_tls_pending(native) : 0);

        // Avisa al otro extremo (close_notify) y cierra la conexión TCP.
        public func Close()
        {
            if (native != null)
            {
                if (authenticated) TlsNative.faset_tls_shutdown(native, 1000);
                TlsNative.faset_tls_free(native);
                native = null;
            }
            authenticated = false;
            if (tcp != null) delete tcp;
            tcp = null;
            pendingStart = 0;
            pendingEnd = 0;
        }
    }

    // ======================================================================= URI

    // URL analizada: esquema://usuario@equipo:puerto/ruta?consulta#fragmento.
    // Las propiedades son vistas de una copia interna (válidas mientras viva el objeto).
    public memory_unsafe class Uri
    {
        var original: string;     // copia propia
        var scheme: string;       // copia propia, en minúsculas
        var userInfo: string;
        var host: string;
        var path: string;
        var query: string;
        var fragment: string;
        var port: int = -1;
        var explicitPort: bool;
        var hasAuthority: bool;
        var hasQuery: bool;
        var hasFragment: bool;
        var ipv6Host: bool;

        init() { }

        deinit
        {
            String.Free(original);
            String.Free(scheme);
        }

        public prop OriginalString: string => original;
        public prop Scheme: string => scheme;
        public prop UserInfo: string => userInfo;
        // Sin corchetes en IPv6 ("::1").
        public prop Host: string => host;
        // Puerto explícito o el de su esquema (80 en http, 443 en https...); -1 si no se conoce.
        public prop Port: int => port;
        public prop IsDefaultPort: bool => !explicitPort || port == DefaultPort(scheme);
        public prop Path: string => path;
        // Sin el '?' inicial.
        public prop Query: string => query;
        // Sin el '#' inicial.
        public prop Fragment: string => fragment;
        public prop HasAuthority: bool => hasAuthority;
        public prop HostIsIPv6: bool => ipv6Host;

        public static func DefaultPort(scheme: string) -> int
        {
            if (scheme == "http" || scheme == "ws") return 80;
            if (scheme == "https" || scheme == "wss") return 443;
            if (scheme == "ftp") return 21;
            return -1;
        }

        // Analiza una URL absoluta. null si no es válida. Libera el resultado con delete.
        public static func Parse(text: string) -> Uri
        {
            Uri u = new Uri();
            if (!u.Init(text))
            {
                delete u;
                return null;
            }
            return u;
        }

        public static func TryCreate(text: string, out uri: Uri) -> bool
        {
            uri = Parse(text);
            return uri != null;
        }

        func Init(text: string) -> bool
        {
            for (int i = 0; i < text.Length; i++)
                if (text[i] <= ' ' || text[i] == 127) return false;
            original = String.Copy(text);
            string s = original;
            int colon = s.IndexOf(":");
            if (colon <= 0 || !Char.IsLetter((char)s[0]) || s[0] >= 128) return false;
            for (int i = 1; i < colon; i++)
            {
                byte c = s[i];
                bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.';
                if (!ok) return false;
            }
            scheme = s.Substring(0, colon).ToLower();
            string rest = s.Substring(colon + 1);
            userInfo = "";
            host = "";
            query = "";
            fragment = "";
            int hash = rest.IndexOf("#");
            if (hash >= 0)
            {
                fragment = rest.Substring(hash + 1);
                hasFragment = true;
                rest = rest.Substring(0, hash);
            }
            int q = rest.IndexOf("?");
            if (q >= 0)
            {
                query = rest.Substring(q + 1);
                hasQuery = true;
                rest = rest.Substring(0, q);
            }
            if (!rest.StartsWith("//"))
            {
                path = rest;
                return true;
            }
            hasAuthority = true;
            rest = rest.Substring(2);
            int slash = rest.IndexOf("/");
            string auth = slash < 0 ? rest : rest.Substring(0, slash);
            path = slash < 0 ? "" : rest.Substring(slash);
            int at = auth.LastIndexOf("@");
            if (at >= 0)
            {
                userInfo = auth.Substring(0, at);
                auth = auth.Substring(at + 1);
            }
            string portText = "";
            bool hasPort = false;
            if (auth.StartsWith("["))
            {
                int close = auth.IndexOf("]");
                if (close < 0) return false;
                host = auth.Substring(1, close - 1);
                IPAddress a;
                if (!IPAddress.TryParse(host, out a) || !a.IsIPv6) return false;
                ipv6Host = true;
                string after = auth.Substring(close + 1);
                if (after.Length > 0)
                {
                    if (after[0] != ':') return false;
                    hasPort = true;
                    portText = after.Substring(1);
                }
            }
            else
            {
                int pc = auth.IndexOf(":");
                if (pc >= 0)
                {
                    hasPort = true;
                    portText = auth.Substring(pc + 1);
                    host = auth.Substring(0, pc);
                }
                else host = auth;
                if (host.Contains("[") || host.Contains("]")) return false;
            }
            port = DefaultPort(scheme);
            if (hasPort && portText.Length > 0)
            {
                long p = 0;
                if (!Net.ParseDecimal(portText, 65535, out p)) return false;
                port = (int)p;
                explicitPort = true;
            }
            if (host.Length == 0 && DefaultPort(scheme) > 0) return false;
            return true;
        }

        // Ruta y consulta para la línea de petición HTTP ("/" si la ruta está vacía).
        // Copia
        public func PathAndQuery() -> string
        {
            StringBuilder sb = new StringBuilder();
            sb.Append(path.Length == 0 ? "/" : path);
            if (hasQuery) sb.Append("?").Append(query);
            string r = sb.ToString();
            delete sb;
            return r;
        }

        // "equipo[:puerto]" con corchetes en IPv6 y el puerto solo si no es el del esquema
        // (es el valor de la cabecera Host). Copia
        public func Authority() -> string
        {
            StringBuilder sb = new StringBuilder();
            AppendAuthority(sb);
            string r = sb.ToString();
            delete sb;
            return r;
        }

        func AppendAuthority(sb: StringBuilder)
        {
            if (ipv6Host) sb.Append("[").Append(host).Append("]");
            else sb.Append(host);
            if (explicitPort && !IsDefaultPort) sb.Append(":").Append((long)port);
        }

        // Resuelve una referencia (como la cabecera Location) respecto a esta URL.
        // Copia. No elimina los segmentos '.' y '..'.
        public func Resolve(reference: string) -> string
        {
            int i = 0;
            while (i < reference.Length && reference[i] != ':' && reference[i] != '/' && reference[i] != '?' && reference[i] != '#') i++;
            if (i > 0 && i < reference.Length && reference[i] == ':') return String.Copy(reference);
            StringBuilder sb = new StringBuilder();
            sb.Append(scheme).Append(":");
            if (reference.StartsWith("//"))
            {
                sb.Append(reference);
            }
            else
            {
                if (hasAuthority)
                {
                    sb.Append("//");
                    if (userInfo.Length > 0) sb.Append(userInfo).Append("@");
                    AppendAuthority(sb);
                }
                if (reference.StartsWith("/"))
                {
                    sb.Append(reference);
                }
                else if (reference.Length == 0 || reference.StartsWith("?") || reference.StartsWith("#"))
                {
                    sb.Append(path);
                    if (reference.StartsWith("#") && hasQuery) sb.Append("?").Append(query);
                    sb.Append(reference);
                }
                else
                {
                    int last = path.LastIndexOf("/");
                    sb.Append(last < 0 ? "/" : path.Substring(0, last + 1));
                    sb.Append(reference);
                }
            }
            string r = sb.ToString();
            delete sb;
            return r;
        }

        // ---------------------------------------------------------------- codificación por porcentajes

        static func Unreserved(c: byte) -> bool =>
            (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~';

        // Codifica todo salvo A-Z a-z 0-9 - . _ ~ (como encodeURIComponent). Copia: String.Free.
        public static func Escape(s: string) -> string
        {
            string digits = "0123456789ABCDEF";
            StringBuilder sb = new StringBuilder(s.Length);
            for (int i = 0; i < s.Length; i++)
            {
                byte c = s[i];
                if (Unreserved(c))
                {
                    sb.Append(s.Substring(i, 1));
                    continue;
                }
                sb.Append("%").Append(digits.Substring(c >> 4, 1)).Append(digits.Substring(c & 15, 1));
            }
            string r = sb.ToString();
            delete sb;
            return r;
        }

        // Decodifica %XX (las secuencias no válidas se dejan igual). Copia: String.Free.
        public static func Unescape(s: string) -> string => Decode(s, false);

        // Como Unescape, y además '+' significa espacio (formularios y consultas).
        public static func UnescapeForm(s: string) -> string => Decode(s, true);

        static func Decode(s: string, plusIsSpace: bool) -> string
        {
            byte* p = (byte*)Memory.Alloc(s.Length + 1);
            int n = 0;
            for (int i = 0; i < s.Length; i++)
            {
                byte c = s[i];
                if (c == '%' && i + 2 < s.Length && Net.Hex(s[i + 1]) >= 0 && Net.Hex(s[i + 2]) >= 0)
                {
                    p[n++] = (byte)(Net.Hex(s[i + 1]) * 16 + Net.Hex(s[i + 2]));
                    i += 2;
                }
                else if (c == '+' && plusIsSpace) p[n++] = (byte)' ';
                else p[n++] = c;
            }
            p[n] = 0;
            return String.FromBytes(p, n);
        }

        // Busca 'name' en una consulta "a=1&b=2" (nombres y valores decodificados como formulario).
        // 'value' es siempre una copia.
        public static func GetQueryParameter(query: string, name: string, out value: string) -> bool
        {
            int start = 0;
            while (start <= query.Length)
            {
                int amp = query.IndexOf("&", start);
                int end = amp < 0 ? query.Length : amp;
                string pair = query.Substring(start, end - start);
                int eq = pair.IndexOf("=");
                string key = UnescapeForm(eq < 0 ? pair : pair.Substring(0, eq));
                bool match = pair.Length > 0 && key == name;
                String.Free(key);
                if (match)
                {
                    value = UnescapeForm(eq < 0 ? "" : pair.Substring(eq + 1));
                    return true;
                }
                if (amp < 0) break;
                start = amp + 1;
            }
            value = String.Copy("");
            return false;
        }
    }

    // ======================================================================= HTTP

    // Lista de cabeceras (nombre y valor). Los nombres no distinguen mayúsculas.
    public class HttpHeaders
    {
        var names: List<string> = new List<string>();     // copias propias
        var values: List<string> = new List<string>();

        public init() { }

        deinit
        {
            Clear();
            delete names;
            delete values;
        }

        public prop Count: int => names.Count;
        public func NameAt(i: int) -> string => names[i];
        public func ValueAt(i: int) -> string => values[i];

        public func IndexOf(name: string) -> int
        {
            for (int i = 0; i < names.Count; i++)
                if (names[i].EqualsIgnoreCase(name)) return i;
            return -1;
        }

        public func Contains(name: string) -> bool => IndexOf(name) >= 0;

        // Valor de la primera cabecera con ese nombre ("" si no existe). Vista: no la liberes.
        public func Get(name: string) -> string
        {
            int i = IndexOf(name);
            return i < 0 ? "" : values[i];
        }

        public func TryGet(name: string, out value: string) -> bool
        {
            int i = IndexOf(name);
            value = i < 0 ? "" : values[i];
            return i >= 0;
        }

        // Añade (permite repetidas, como Set-Cookie).
        public func Add(name: string, value: string)
        {
            names.Add(String.Copy(name));
            values.Add(String.Copy(value));
        }

        // Sustituye todas las cabeceras con ese nombre por una sola.
        public func Set(name: string, value: string)
        {
            Remove(name);
            Add(name, value);
        }

        public func Remove(name: string) -> bool
        {
            bool any = false;
            for (int i = names.Count - 1; i >= 0; i--)
            {
                if (!names[i].EqualsIgnoreCase(name)) continue;
                String.Free(names[i]);
                String.Free(values[i]);
                names.RemoveAt(i);
                values.RemoveAt(i);
                any = true;
            }
            return any;
        }

        public func Clear()
        {
            for (int i = 0; i < names.Count; i++)
            {
                String.Free(names[i]);
                String.Free(values[i]);
            }
            names.Clear();
            values.Clear();
        }

        // Une una línea de continuación (obs-fold) a la última cabecera.
        public func AppendToLast(more: string)
        {
            if (names.Count == 0) return;
            int i = names.Count - 1;
            string v = String.Concat(values[i], " ", more);
            String.Free(values[i]);
            values[i] = v;
        }

        // Escribe "Nombre: valor\r\n" por cada cabecera.
        public func WriteTo(sb: StringBuilder)
        {
            for (int i = 0; i < names.Count; i++) sb.Append(names[i]).Append(": ").Append(values[i]).Append("\r\n");
        }
    }

    public class HttpRequest
    {
        var method: string;      // copias propias
        var url: string;
        var body: string;
        var headers: HttpHeaders = new HttpHeaders();

        public init(requestMethod: string, requestUrl: string)
        {
            method = String.Copy(requestMethod);
            url = String.Copy(requestUrl);
            body = String.Copy("");
        }

        deinit
        {
            String.Free(method);
            String.Free(url);
            String.Free(body);
            delete headers;
        }

        public prop Method: string => method;
        public prop Url: string => url;
        public prop Body: string => body;
        public prop Headers: HttpHeaders => headers;

        // Cuerpo de la petición; 'contentType' vacío no añade la cabecera Content-Type.
        public func SetBody(content: string, contentType: string)
        {
            String.Free(body);
            body = String.Copy(content);
            if (contentType.Length > 0) headers.Set("Content-Type", contentType);
        }
    }

    public class HttpResponse
    {
        var statusCode: int;
        var version: string;     // copias propias
        var reason: string;
        var body: string;
        var headers: HttpHeaders = new HttpHeaders();

        public init()
        {
            version = String.Copy("");
            reason = String.Copy("");
            body = String.Copy("");
        }

        deinit
        {
            String.Free(version);
            String.Free(reason);
            String.Free(body);
            delete headers;
        }

        public prop StatusCode: int => statusCode;
        // "HTTP/1.1"
        public prop Version: string => version;
        // "OK", "Not Found"...
        public prop ReasonPhrase: string => reason;
        // Cuerpo ya decodificado (sin el formato chunked). Puede contener bytes binarios.
        public prop Body: string => body;
        public prop Headers: HttpHeaders => headers;
        public prop IsSuccess: bool => statusCode >= 200 && statusCode <= 299;
        public prop IsRedirect: bool => statusCode == 301 || statusCode == 302 || statusCode == 303 || statusCode == 307 || statusCode == 308;
        public prop ContentType: string => headers.Get("Content-Type");

        public func SetBody(content: string)
        {
            String.Free(body);
            body = String.Copy(content);
        }

        // Analiza una respuesta HTTP completa (línea de estado, cabeceras y cuerpo con
        // Content-Length, chunked o hasta el final del texto). null si no es válida o está incompleta.
        public static func Parse(raw: string) -> HttpResponse => Parse(raw, false);

        // 'headRequest': la respuesta es a una petición HEAD (no tiene cuerpo).
        public static func Parse(raw: string, headRequest: bool) -> HttpResponse
        {
            HttpResponseReader reader = new HttpResponseReader(headRequest);
            int r = reader.Feed(raw);
            if (r == 0) r = reader.Finish();
            HttpResponse resp = r == 1 ? reader.Take() : null;
            delete reader;
            return resp;
        }

        // Analiza la línea de estado y las cabeceras (texto hasta la línea vacía, incluida).
        public func ParseHead(head: string) -> bool
        {
            int start = 0;
            bool first = true;
            while (start < head.Length)
            {
                int nl = head.IndexOf("\n", start);
                int end = nl < 0 ? head.Length : nl;
                string line = head.Substring(start, end - start);
                start = end + 1;
                if (line.EndsWith("\r")) line = line.Substring(0, line.Length - 1);
                if (first)
                {
                    first = false;
                    if (!ParseStatusLine(line)) return false;
                    continue;
                }
                if (line.Length == 0) break;
                if (line[0] == ' ' || line[0] == '\t')
                {
                    if (headers.Count == 0) return false;
                    headers.AppendToLast(line.Trim());
                    continue;
                }
                int colon = line.IndexOf(":");
                if (colon <= 0) return false;
                string name = line.Substring(0, colon);
                if (name.Contains(" ") || name.Contains("\t")) return false;
                headers.Add(name, line.Substring(colon + 1).Trim());
            }
            return !first;
        }

        func ParseStatusLine(line: string) -> bool
        {
            if (!line.StartsWith("HTTP/")) return false;
            int sp = line.IndexOf(" ");
            if (sp < 0 || sp + 4 > line.Length) return false;
            string code = line.Substring(sp + 1, 3);
            long v = 0;
            if (!Net.ParseDecimal(code, 999, out v) || v < 100) return false;
            if (sp + 4 < line.Length && line[sp + 4] != ' ') return false;
            String.Free(version);
            String.Free(reason);
            version = String.Copy(line.Substring(0, sp));
            reason = String.Copy(sp + 5 <= line.Length ? line.Substring(sp + 5) : "");
            statusCode = (int)v;
            return true;
        }

        // Decodifica un cuerpo "chunked" completo (copia en 'body').
        public static func DecodeChunked(chunked: string, out body: string) -> bool
        {
            StringBuilder sb = new StringBuilder();
            int pos = 0;
            bool ok = DecodeChunks(chunked, ref pos, sb) == 1;
            body = ok ? sb.ToString() : String.Copy("");
            delete sb;
            return ok;
        }

        // Decodifica los bloques completos a partir de 'pos' (que avanza) y los añade a 'body'.
        // 1 = terminado (tras el bloque 0 y los trailers), 0 = faltan datos, -1 = formato no válido.
        public static func DecodeChunks(data: string, ref pos: int, body: StringBuilder) -> int
        {
            for (;;)
            {
                int nl = data.IndexOf("\n", pos);
                if (nl < 0) return 0;
                string line = data.Substring(pos, nl - pos);
                int semi = line.IndexOf(";");
                if (semi >= 0) line = line.Substring(0, semi);
                line = line.Trim();
                if (line.Length == 0 || line.Length > 8) return -1;
                long size = 0;
                for (int i = 0; i < line.Length; i++)
                {
                    int d = Net.Hex(line[i]);
                    if (d < 0) return -1;
                    size = size * 16 + d;
                }
                if (size > 0x7fffffff) return -1;
                if (size == 0)
                {
                    int p = nl + 1;
                    for (;;)
                    {
                        int e = data.IndexOf("\n", p);
                        if (e < 0) return 0;
                        string trailer = data.Substring(p, e - p);
                        p = e + 1;
                        if (trailer.Length == 0 || trailer == "\r")
                        {
                            pos = p;
                            return 1;
                        }
                    }
                }
                int start = nl + 1;
                if ((long)start + size + 1 > data.Length) return 0;
                int after = start + (int)size;
                if (data[after] == '\r')
                {
                    if (after + 1 >= data.Length) return 0;
                    if (data[after + 1] != '\n') return -1;
                    body.Append(data.Substring(start, (int)size));
                    pos = after + 2;
                }
                else if (data[after] == '\n')
                {
                    body.Append(data.Substring(start, (int)size));
                    pos = after + 1;
                }
                else return -1;
            }
        }
    }

    // Lector incremental de respuestas HTTP: se le dan los bytes según llegan.
    public class HttpResponseReader
    {
        var raw: StringBuilder = new StringBuilder();
        var chunks: StringBuilder = new StringBuilder();
        var response: HttpResponse;
        var headRequest: bool;
        var offset: int;          // inicio de la respuesta actual (se saltan las 1xx)
        var bodyStart: int = -1;
        var mode: int;            // 0 sin cuerpo, 1 Content-Length, 2 chunked, 3 hasta el cierre
        var contentLength: long;
        var chunkPos: int;
        var done: bool;

        public init(isHeadRequest: bool) { headRequest = isHeadRequest; }

        deinit
        {
            delete raw;
            delete chunks;
            if (response != null) delete response;
        }

        // Añade datos. 1 = respuesta completa, 0 = faltan datos, -1 = respuesta no válida.
        public func Feed(data: string) -> int
        {
            if (done) return 1;
            raw.Append(data);
            return Step(false);
        }

        // El servidor cerró la conexión: completa la respuesta si es posible (1) o falla (-1).
        public func Finish() -> int
        {
            if (done) return 1;
            return Step(true);
        }

        // Entrega la respuesta (pasa a ser tuya).
        public func Take() -> HttpResponse
        {
            HttpResponse r = done ? response : null;
            if (done) response = null;
            return r;
        }

        static func FindHeaderEnd(d: string, from: int) -> int
        {
            for (int i = from; i + 1 < d.Length; i++)
            {
                if (d[i] != '\n') continue;
                if (d[i + 1] == '\n') return i + 2;
                if (d[i + 1] == '\r' && i + 2 < d.Length && d[i + 2] == '\n') return i + 3;
            }
            return -1;
        }

        func Step(eof: bool) -> int
        {
            string d = raw.View();
            while (response == null)
            {
                int end = FindHeaderEnd(d, offset);
                if (end < 0) return eof ? -1 : 0;
                HttpResponse r = new HttpResponse();
                if (!r.ParseHead(d.Substring(offset, end - offset)))
                {
                    delete r;
                    return -1;
                }
                if (r.StatusCode >= 100 && r.StatusCode < 200 && r.StatusCode != 101)
                {
                    delete r;           // respuesta provisional (100 Continue...): se descarta
                    offset = end;
                    continue;
                }
                response = r;
                bodyStart = end;
                chunkPos = end;
                string te = r.Headers.Get("Transfer-Encoding");
                string cl = r.Headers.Get("Content-Length");
                int code = r.StatusCode;
                if (headRequest || code == 204 || code == 304 || code < 200) mode = 0;
                else if (IsChunked(te)) mode = 2;
                else if (cl.Length > 0)
                {
                    if (!Net.ParseDecimal(cl.Trim(), 0x7fffffff, out contentLength)) return -1;
                    mode = 1;
                }
                else mode = 3;
            }
            if (mode == 0) return Complete("");
            if (mode == 1)
            {
                if (d.Length - bodyStart >= contentLength) return Complete(d.Substring(bodyStart, (int)contentLength));
                return eof ? -1 : 0;
            }
            if (mode == 3) return eof ? Complete(d.Substring(bodyStart)) : 0;
            int c = HttpResponse.DecodeChunks(d, ref chunkPos, chunks);
            if (c == 1) return Complete(chunks.View());
            if (c == 0 && eof) return -1;
            return c;
        }

        func Complete(body: string) -> int
        {
            response.SetBody(body);
            done = true;
            return 1;
        }

        // Transfer-Encoding incluye "chunked" (sin distinguir mayúsculas).
        static func IsChunked(te: string) -> bool
        {
            string l = te.ToLower();
            bool r = l.Contains("chunked");
            String.Free(l);
            return r;
        }
    }

    // Error de una petición de HttpClient.GetAsync / GetStringAsync / PostAsync / SendAsync.
    public class HttpRequestException : IOException
    {
        public var StatusCode: int;  // 0 si no hubo respuesta (no se pudo conectar, TLS...)
        public init(message: string, statusCode: int)
        {
            Message = message;
            StatusCode = statusCode;
        }
    }

    // Cliente HTTP/1.1 sencillo para http:// y https:// (TLS con TlsStream: certificado
    // verificado contra las autoridades del sistema; las redirecciones pueden cambiar de esquema).
    public memory_unsafe class HttpClient
    {
        var defaultHeaders: HttpHeaders = new HttpHeaders();
        var userAgent: string;      // copias propias
        var caFile: string;
        var message: string;
        var timeout: int = 30000;
        var followRedirects: bool = true;
        var maxRedirects: int = 5;
        var validateCertificate: bool = true;
        var error: SocketError;
        var nativeError: int;

        public init()
        {
            userAgent = String.Copy("Faset/1.0");
            caFile = String.Copy("");
            message = String.Copy("");
        }

        deinit
        {
            delete defaultHeaders;
            String.Free(userAgent);
            String.Free(caFile);
            String.Free(message);
        }

        // Cabeceras que se envían en todas las peticiones.
        public prop DefaultHeaders: HttpHeaders => defaultHeaders;
        public prop UserAgent: string
        {
            get => userAgent;
            set
            {
                string v = String.Copy(value);
                String.Free(userAgent);
                userAgent = v;
            }
        }
        // Milisegundos para conectar y para cada lectura o escritura (-1 = sin límite).
        public prop Timeout: int { get => timeout; set { timeout = value; } }
        public prop FollowRedirects: bool { get => followRedirects; set { followRedirects = value; } }
        public prop MaxRedirects: int { get => maxRedirects; set { maxRedirects = value; } }
        // https://: verificar el certificado del servidor (true por defecto). false acepta
        // CUALQUIER certificado, también el de un atacante que se ponga en medio: solo para pruebas.
        public prop ValidateCertificate: bool { get => validateCertificate; set { validateCertificate = value; } }
        // https://: archivo PEM con autoridades de confianza adicionales ("" = solo las del sistema).
        public prop CertificateAuthorityFile: string
        {
            get => caFile;
            set
            {
                string v = String.Copy(value);
                String.Free(caFile);
                caFile = v;
            }
        }
        public prop Error: SocketError => error;
        public prop NativeError: int => nativeError;
        // Motivo del último fallo, en español (vista: no la liberes).
        public prop ErrorMessage: string => message;

        func Fail(e: SocketError, native: int, text: string) -> HttpResponse
        {
            error = e;
            nativeError = native;
            string m = String.Copy(text);
            String.Free(message);
            message = m;
            return null;
        }

        public func Get(url: string) -> HttpResponse
        {
            HttpRequest req = new HttpRequest("GET", url);
            HttpResponse r = Send(req);
            delete req;
            return r;
        }

        public func Post(url: string, body: string, contentType: string) -> HttpResponse
        {
            HttpRequest req = new HttpRequest("POST", url);
            req.SetBody(body, contentType);
            HttpResponse r = Send(req);
            delete req;
            return r;
        }

        // ---- async (std.task). La petición corre en un hilo del grupo de tareas (conexión, TLS y
        // lectura bloqueantes) y 'await' no bloquea a quien espera: en una ventana de std.ui, el
        // resto del manejador sigue en el hilo de la interfaz. Si falla, la tarea lanza
        // HttpRequestException al hacer 'await' (Error y ErrorMessage se comparten entre peticiones:
        // usa un HttpClient por petición simultánea si los necesitas).
        public func GetAsync(url: string) -> Task<HttpResponse>
        {
            HttpClient self = this;
            return Task.Run(() => self.OrThrow(self.Get(url), url));
        }

        public func PostAsync(url: string, body: string, contentType: string) -> Task<HttpResponse>
        {
            HttpClient self = this;
            return Task.Run(() => self.OrThrow(self.Post(url, body, contentType), url));
        }

        public func SendAsync(request: HttpRequest) -> Task<HttpResponse>
        {
            HttpClient self = this;
            return Task.Run(() => self.OrThrow(self.Send(request), request.Url));
        }

        // El cuerpo de la respuesta; un código de estado de error (4xx, 5xx) también es una excepción.
        public func GetStringAsync(url: string) -> Task<string>
        {
            HttpClient self = this;
            return Task.Run(() =>
            {
                HttpResponse r = self.OrThrow(self.Get(url), url);
                if (r.StatusCode >= 400)
                    throw new HttpRequestException("HTTP " + r.StatusCode + " " + r.ReasonPhrase + ": " + url, r.StatusCode);
                return String.Copy(r.Body);
            });
        }

        func OrThrow(r: HttpResponse, url: string) -> HttpResponse
        {
            if (r == null) throw new HttpRequestException(url + ": " + message, 0);
            return r;
        }

        // Envía la petición siguiendo las redirecciones (si FollowRedirects). null si falla:
        // consulta Error y ErrorMessage. Libera la respuesta con delete.
        public func Send(request: HttpRequest) -> HttpResponse
        {
            string url = String.Copy(request.Url);
            string method = String.Copy(request.Method);
            bool withBody = true;
            HttpResponse result = null;
            for (int hop = 0; ; hop++)
            {
                Uri uri = Uri.Parse(url);
                if (uri == null)
                {
                    Fail(SocketError.InvalidUrl, 0, "URL no válida");
                    break;
                }
                if (uri.Scheme != "http" && uri.Scheme != "https")
                {
                    Fail(SocketError.InvalidUrl, 0, "esquema no soportado (solo http:// y https://)");
                    delete uri;
                    break;
                }
                HttpResponse r = SendOnce(method, uri, request.Headers, withBody ? request.Body : "");
                if (r == null)
                {
                    delete uri;
                    break;
                }
                if (!followRedirects || !r.IsRedirect || !r.Headers.Contains("Location") || hop >= maxRedirects)
                {
                    delete uri;
                    result = r;
                    break;
                }
                int code = r.StatusCode;
                if (code == 303 || ((code == 301 || code == 302) && method != "GET" && method != "HEAD"))
                {
                    String.Free(method);
                    method = String.Copy("GET");
                    withBody = false;
                }
                string next = uri.Resolve(r.Headers.Get("Location"));
                String.Free(url);
                url = next;
                delete r;
                delete uri;
            }
            String.Free(url);
            String.Free(method);
            if (result != null)
            {
                error = SocketError.Success;
                nativeError = 0;
                String.Free(message);
                message = String.Copy("");
            }
            return result;
        }

        func SendOnce(method: string, uri: Uri, extra: HttpHeaders, body: string) -> HttpResponse
        {
            HttpHeaders h = new HttpHeaders();
            if (!extra.Contains("User-Agent") && !defaultHeaders.Contains("User-Agent") && userAgent.Length > 0) h.Add("User-Agent", userAgent);
            if (!extra.Contains("Accept") && !defaultHeaders.Contains("Accept")) h.Add("Accept", "*/*");
            for (int i = 0; i < defaultHeaders.Count; i++)
                if (!extra.Contains(defaultHeaders.NameAt(i))) h.Add(defaultHeaders.NameAt(i), defaultHeaders.ValueAt(i));
            for (int i = 0; i < extra.Count; i++) h.Add(extra.NameAt(i), extra.ValueAt(i));
            string wire = BuildRequest(method, uri, h, body);
            delete h;

            TcpClient c = new TcpClient();
            c.ReceiveTimeout = timeout;
            c.SendTimeout = timeout;
            if (!c.Connect(uri.Host, uri.Port, timeout))
            {
                Fail(c.Error, c.NativeError, Net.Describe(c.Error));
                delete c;
                String.Free(wire);
                return null;
            }
            // https://: el TlsStream pasa a ser el dueño de la conexión TCP.
            TlsStream tls = null;
            if (uri.Scheme == "https")
            {
                tls = new TlsStream(c);
                tls.ValidateCertificate = validateCertificate;
                tls.CertificateAuthorityFile = caFile;
                if (!tls.AuthenticateAsClient(uri.Host))
                {
                    Fail(tls.Error, tls.NativeError, tls.ErrorMessage);
                    delete tls;
                    String.Free(wire);
                    return null;
                }
            }
            bool sent = tls != null ? tls.Write(wire) : c.Write(wire);
            String.Free(wire);
            if (!sent)
            {
                if (tls != null) Fail(tls.Error, tls.NativeError, tls.ErrorMessage);
                else Fail(c.Error, c.NativeError, Net.Describe(c.Error));
                if (tls != null) delete tls;
                else delete c;
                return null;
            }
            HttpResponseReader reader = new HttpResponseReader(method == "HEAD");
            byte* buf = (byte*)Memory.Alloc(16384);
            int state = 0;
            while (state == 0)
            {
                int n = tls != null ? tls.Receive(buf, 16384) : c.Receive(buf, 16384);
                if (n > 0) state = reader.Feed(String.FromBytes(buf, n));
                else if (n == 0) state = reader.Finish();
                else
                {
                    if (tls != null) Fail(tls.Error, tls.NativeError, tls.ErrorMessage);
                    else Fail(c.Error, c.NativeError, Net.Describe(c.Error));
                    break;
                }
            }
            Memory.Free(buf);
            if (tls != null) delete tls;
            else delete c;
            HttpResponse resp = null;
            if (state == 1) resp = reader.Take();
            else if (state < 0) Fail(SocketError.ProtocolError, 0, "respuesta del servidor no válida");
            delete reader;
            return resp;
        }

        // Texto exacto de una petición HTTP/1.1 (copia). Añade Host,
        // Content-Length y 'Connection: close' si 'headers' no los trae.
        public static func BuildRequest(method: string, uri: Uri, headers: HttpHeaders, body: string) -> string
        {
            StringBuilder sb = new StringBuilder();
            string target = uri.PathAndQuery();
            sb.Append(method).Append(" ").Append(target).Append(" HTTP/1.1\r\n");
            String.Free(target);
            if (!headers.Contains("Host"))
            {
                string auth = uri.Authority();
                sb.Append("Host: ").Append(auth).Append("\r\n");
                String.Free(auth);
            }
            headers.WriteTo(sb);
            bool needsLength = body.Length > 0 || method == "POST" || method == "PUT" || method == "PATCH";
            if (needsLength && !headers.Contains("Content-Length") && !headers.Contains("Transfer-Encoding"))
                sb.Append("Content-Length: ").Append(body.Length).Append("\r\n");
            if (!headers.Contains("Connection")) sb.Append("Connection: close\r\n");
            sb.Append("\r\n").Append(body);
            string r = sb.ToString();
            delete sb;
            return r;
        }
    }
}
