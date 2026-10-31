// =============================================================================
//  std.io  —  archivos, carpetas, rutas, flujos y vigilancia de cambios.
//
//    File          leer/escribir texto, bytes y líneas; copiar, mover, borrar, metadatos
//    FileStream    flujo con búfer: Read, ReadLine, Write, Seek, Position, Length
//    Directory     crear (recursivo), borrar, enumerar con patrón ("*.fst") y recursión
//    Path          Combine, GetFileName, GetExtension, Normalize, GetFullPath, GetRelativePath...
//    FileInfo      tamaño, fechas, tipo (archivo/carpeta/enlace), permisos
//    FileWatcher   cambios en una carpeta (inotify en Linux; sondeo en el resto)
//
//  Las rutas son UTF-8. En Windows se usan las API W de Win32 (UTF-16) y se aceptan
//  tanto '/' como '\'. Las fechas son milisegundos Unix (UTC).
//
//  Memoria: las cadenas y listas nuevas las recupera el recolector de basura; las
//  funciones Free* se conservan por compatibilidad.
// =============================================================================
using std.collections;
using std.task;
using std.text;

namespace std.io
{
    public struct DirEntry
    {
        public var Name: string       // copia propia
        public var IsDirectory: bool  // carpeta (o enlace a una carpeta)
        public var IsSymlink: bool    // enlace simbólico (o punto de reanálisis en Windows)
    }

    public enum FileKind { None, File, Directory, Other }

    public enum FileMode
    {
        CreateNew,      // crea; falla si ya existe
        Create,         // crea o vacía
        Open,           // abre; falla si no existe
        OpenOrCreate,   // abre o crea
        Truncate,       // abre y vacía; falla si no existe
        Append          // abre o crea y escribe al final (solo escritura)
    }

    public enum FileAccess { Read = 1, Write = 2, ReadWrite = 3 }
    public enum SeekOrigin { Begin, Current, End }

    // Metadatos de un archivo o carpeta (sigue los enlaces simbólicos, salvo IsSymlink).
    public memory_unsafe struct FileInfo
    {
        public var Exists: bool
        public var Kind: FileKind
        public var IsSymlink: bool
        public var Length: long            // bytes (0 para carpetas)
        public var LastWriteTimeMs: long   // ms Unix
        public var LastAccessTimeMs: long
        public var CreationTimeMs: long    // Windows: creación; POSIX: último cambio de estado (ctime)
        public var Mode: int               // permisos Unix (0644...); en Windows se emulan (0444 / 0666)
        public var IsReadOnly: bool

        public prop IsFile: bool => Kind == FileKind.File;
        public prop IsDirectory: bool => Kind == FileKind.Directory;

        // Metadatos de 'path' (Exists = false si no existe).
        public static func Get(path: string) -> FileInfo
        {
            FileInfo info = new FileInfo();
            Native.Stat(path, &info);
            return info;
        }
    }

    // ======================================================================= capa nativa
    //  Misma interfaz en todos los sistemas. Los manejadores son 'long' (-1 = no válido).
    //  Open: banderas 1 leer, 2 escribir, 4 crear, 8 truncar, 16 exclusivo, 32 añadir.
    //  ListDir: "<tipo><nombre>\0..." con f/d/o (archivo/carpeta/otro) y F/D/L (enlaces).

#if WINDOWS
    memory_unsafe static class Native
    {
        static extern void* CreateFileW(ushort* name, uint access, uint share, void* security, uint disposition, uint flags, void* template);
        static extern int ReadFile(void* h, void* buffer, uint count, uint* done, void* overlapped);
        static extern int WriteFile(void* h, void* buffer, uint count, uint* done, void* overlapped);
        static extern int SetFilePointerEx(void* h, long distance, long* newPosition, uint method);
        static extern int SetEndOfFile(void* h);
        static extern int FlushFileBuffers(void* h);
        static extern int CloseHandle(void* h);
        static extern int GetFileAttributesExW(ushort* name, int level, byte* data);
        static extern uint GetFileAttributesW(ushort* name);
        static extern int SetFileAttributesW(ushort* name, uint attributes);
        static extern int GetFileInformationByHandle(void* h, byte* info);
        static extern int SetFileTime(void* h, ulong* creation, ulong* access, ulong* write);
        static extern int CreateDirectoryW(ushort* name, void* security);
        static extern int RemoveDirectoryW(ushort* name);
        static extern int DeleteFileW(ushort* name);
        static extern int MoveFileExW(ushort* from, ushort* to, uint flags);
        static extern int CopyFileW(ushort* from, ushort* to, int failIfExists);
        static extern void* FindFirstFileW(ushort* pattern, byte* data);
        static extern int FindNextFileW(void* h, byte* data);
        static extern int FindClose(void* h);
        static extern uint GetCurrentDirectoryW(uint size, ushort* buffer);
        static extern int SetCurrentDirectoryW(ushort* name);
        static extern uint GetFullPathNameW(ushort* name, uint size, ushort* buffer, ushort** filePart);
        static extern uint GetTempPathW(uint size, ushort* buffer);
        static extern uint GetLastError();

        public const bool IsWindows = true;
        public const bool IgnoreCase = true;

        static func U32(p: byte*, offset: int) -> uint =>
            (uint)p[offset] | ((uint)p[offset + 1] << 8) | ((uint)p[offset + 2] << 16) | ((uint)p[offset + 3] << 24);

        // FILETIME (100 ns desde 1601) -> ms Unix.
        static func FileTimeMs(p: byte*, offset: int) -> long
        {
            ulong ft = ((ulong)U32(p, offset + 4) << 32) | (ulong)U32(p, offset);
            if (ft == 0) return 0;
            return ((long)ft - 116444736000000000) / 10000;
        }

        static func Fill(info: FileInfo*, attrs: uint, data: byte*, sizeOffset: int)
        {
            bool dir = (attrs & 0x10) != 0;
            info->Exists = true;
            info->Kind = dir ? FileKind.Directory : FileKind.File;
            info->Length = dir ? 0 : (long)(((ulong)U32(data, sizeOffset) << 32) | (ulong)U32(data, sizeOffset + 4));
            info->CreationTimeMs = FileTimeMs(data, 4);
            info->LastAccessTimeMs = FileTimeMs(data, 12);
            info->LastWriteTimeMs = FileTimeMs(data, 20);
            info->IsReadOnly = (attrs & 1) != 0;
            info->Mode = (info->IsReadOnly ? 0x124 : 0x1B6) | (dir ? 0x49 : 0);   // 0444 / 0666, + 0111 (Faset no tiene literales octales)
        }

        public static func Stat(path: string, info: FileInfo*) -> bool
        {
            ushort* w = Utf16.Encode(path);
            byte* data = (byte*)Memory.AllocZeroed(64);   // WIN32_FILE_ATTRIBUTE_DATA
            bool ok = GetFileAttributesExW(w, 0, data) != 0;
            if (ok)
            {
                uint attrs = U32(data, 0);
                Fill(info, attrs, data, 28);
                if ((attrs & 0x400) != 0)   // punto de reanálisis: datos del destino
                {
                    info->IsSymlink = true;
                    void* h = CreateFileW(w, 0x80, 7, null, 3, 0x02000000, null);
                    if ((long)h != -1)
                    {
                        byte* bh = (byte*)Memory.AllocZeroed(64);   // BY_HANDLE_FILE_INFORMATION
                        if (GetFileInformationByHandle(h, bh) != 0) Fill(info, U32(bh, 0), bh, 32);
                        Memory.Free(bh);
                        CloseHandle(h);
                    }
                    else info->Kind = FileKind.Other;
                }
            }
            Memory.Free(data);
            Memory.Free(w);
            return ok;
        }

        public static func MkDir(path: string) -> int
        {
            ushort* w = Utf16.Encode(path);
            int r = CreateDirectoryW(w, null) != 0 ? 0 : GetLastError() == 183 ? 1 : 2;
            Memory.Free(w);
            return r;
        }

        public static func RmDir(path: string) -> bool
        {
            ushort* w = Utf16.Encode(path);
            bool ok = RemoveDirectoryW(w) != 0;
            Memory.Free(w);
            return ok;
        }

        public static func Unlink(path: string) -> bool
        {
            ushort* w = Utf16.Encode(path);
            bool ok = DeleteFileW(w) != 0;
            Memory.Free(w);
            return ok;
        }

        // Borra aunque tenga el atributo de solo lectura (para el borrado recursivo).
        public static func ForceUnlink(path: string) -> bool
        {
            if (Unlink(path)) return true;
            ushort* w = Utf16.Encode(path);
            uint attrs = GetFileAttributesW(w);
            bool ok = false;
            if (attrs != 0xFFFFFFFF && (attrs & 1) != 0 && SetFileAttributesW(w, attrs & 0xFFFFFFFE) != 0)
                ok = DeleteFileW(w) != 0;
            Memory.Free(w);
            return ok;
        }

        public static func Rename(from: string, to: string, overwrite: bool) -> int
        {
            ushort* a = Utf16.Encode(from);
            ushort* b = Utf16.Encode(to);
            int r = MoveFileExW(a, b, overwrite ? (uint)3 : (uint)2) != 0 ? 1 : 0;   // REPLACE_EXISTING | COPY_ALLOWED
            Memory.Free(a);
            Memory.Free(b);
            return r;
        }

        public static func CopyFile(from: string, to: string, overwrite: bool) -> bool
        {
            ushort* a = Utf16.Encode(from);
            ushort* b = Utf16.Encode(to);
            bool ok = CopyFileW(a, b, overwrite ? 0 : 1) != 0;
            Memory.Free(a);
            Memory.Free(b);
            return ok;
        }

        public static func SetReadOnly(path: string, readOnly: bool) -> bool
        {
            ushort* w = Utf16.Encode(path);
            uint attrs = GetFileAttributesW(w);
            bool ok = false;
            if (attrs != 0xFFFFFFFF)
            {
                attrs = readOnly ? attrs | 1 : attrs & 0xFFFFFFFE;
                ok = SetFileAttributesW(w, attrs == 0 ? (uint)0x80 : attrs) != 0;
            }
            Memory.Free(w);
            return ok;
        }

        // Windows solo tiene "solo lectura": se usa el bit de escritura del propietario.
        public static func SetMode(path: string, mode: int) -> bool => SetReadOnly(path, (mode & 0x80) == 0);

        public static func SetMTime(path: string, ms: long) -> bool
        {
            ushort* w = Utf16.Encode(path);
            void* h = CreateFileW(w, 0x100, 7, null, 3, 0x02000000, null);   // FILE_WRITE_ATTRIBUTES
            Memory.Free(w);
            if ((long)h == -1) return false;
            ulong ft = (ulong)(ms * 10000 + 116444736000000000);
            bool ok = SetFileTime(h, null, null, &ft) != 0;
            CloseHandle(h);
            return ok;
        }

        public static func Open(path: string, flags: int) -> long
        {
            uint access = 0;
            if ((flags & 1) != 0) access |= 0x80000000;   // GENERIC_READ
            if ((flags & 2) != 0) access |= 0x40000000;   // GENERIC_WRITE
            uint disposition = 3;                          // OPEN_EXISTING
            if ((flags & 16) != 0) disposition = 1;        // CREATE_NEW
            else if ((flags & 4) != 0 && (flags & 8) != 0) disposition = 2;   // CREATE_ALWAYS
            else if ((flags & 4) != 0) disposition = 4;    // OPEN_ALWAYS
            else if ((flags & 8) != 0) disposition = 5;    // TRUNCATE_EXISTING
            ushort* w = Utf16.Encode(path);
            void* h = CreateFileW(w, access, 7, null, disposition, 0x80, null);
            Memory.Free(w);
            return (long)h == -1 ? -1 : (long)h;
        }

        public static func Read(h: long, buffer: byte*, count: long) -> long
        {
            uint done = 0;
            uint n = count > 0x40000000 ? (uint)0x40000000 : (uint)count;
            if (ReadFile((void*)h, buffer, n, &done, null) == 0) return GetLastError() == 109 ? 0 : -1;
            return done;
        }

        public static func Write(h: long, data: byte*, count: long) -> bool
        {
            while (count > 0)
            {
                uint done = 0;
                uint n = count > 0x40000000 ? (uint)0x40000000 : (uint)count;
                if (WriteFile((void*)h, data, n, &done, null) == 0 || done == 0) return false;
                data += done;
                count -= done;
            }
            return true;
        }

        public static func Seek(h: long, offset: long, whence: int) -> long
        {
            long pos = 0;
            if (SetFilePointerEx((void*)h, offset, &pos, (uint)whence) == 0) return -1;
            return pos;
        }

        public static func Truncate(h: long, length: long) -> bool
        {
            long cur = Seek(h, 0, 1);
            bool ok = Seek(h, length, 0) >= 0 && SetEndOfFile((void*)h) != 0;
            Seek(h, cur, 0);
            return ok;
        }

        public static func Sync(h: long) -> bool => FlushFileBuffers((void*)h) != 0;
        public static func Close(h: long) { if (h != -1) CloseHandle((void*)h); }

        public static func ListDir(path: string, out ok: bool) -> string
        {
            StringBuilder sb = new StringBuilder();
            string pattern = path.EndsWith("/") || path.EndsWith("\\") ? String.Concat(path, "*") : String.Concat(path, "\\*");
            ushort* w = Utf16.Encode(pattern);
            String.Free(pattern);
            byte* data = (byte*)Memory.AllocZeroed(600);   // WIN32_FIND_DATAW (592 bytes)
            void* h = FindFirstFileW(w, data);
            Memory.Free(w);
            ok = (long)h != -1 || GetLastError() == 2;
            if ((long)h != -1)
            {
                for (;;)
                {
                    string name = Utf16.Decode((ushort*)(data + 44));
                    if (name != "." && name != "..")
                    {
                        uint attrs = U32(data, 0);
                        uint tag = U32(data, 36);
                        bool dir = (attrs & 0x10) != 0;
                        bool link = (attrs & 0x400) != 0 && (tag == 0xA000000C || tag == 0xA0000003);
                        sb.Append(link ? (dir ? 'D' : 'F') : (dir ? 'd' : 'f'));
                        sb.Append(name).Append((char)0);
                    }
                    String.Free(name);
                    if (FindNextFileW(h, data) == 0) break;
                }
                FindClose(h);
            }
            Memory.Free(data);
            string r = sb.ToString();
            delete sb;
            return r;
        }

        public static func GetCwd() -> string
        {
            uint n = GetCurrentDirectoryW(0, null);
            ushort* buf = Memory.New<ushort>(n + 1);
            uint got = GetCurrentDirectoryW(n + 1, buf);
            string s = Utf16.Decode(buf, (int)(got <= n ? got : 0));
            Memory.Free(buf);
            return s;
        }

        public static func SetCwd(path: string) -> bool
        {
            ushort* w = Utf16.Encode(path);
            bool ok = SetCurrentDirectoryW(w) != 0;
            Memory.Free(w);
            return ok;
        }

        // Ruta absoluta (resuelve '.', '..' y la unidad actual; no exige que exista). Copia.
        public static func FullPath(path: string) -> string
        {
            ushort* w = Utf16.Encode(path);
            uint n = GetFullPathNameW(w, 0, null, null);
            string s;
            if (n == 0) s = String.Copy("");
            else
            {
                ushort* buf = Memory.New<ushort>(n + 1);
                uint got = GetFullPathNameW(w, n + 1, buf, null);
                s = Utf16.Decode(buf, (int)(got <= n ? got : 0));
                Memory.Free(buf);
            }
            Memory.Free(w);
            return s;
        }

        public static func TempDir() -> string
        {
            uint n = GetTempPathW(0, null);
            ushort* buf = Memory.New<ushort>(n + 1);
            uint got = GetTempPathW(n + 1, buf);
            int len = (int)(got <= n ? got : 0);
            while (len > 3 && (buf[len - 1] == '\\' || buf[len - 1] == '/')) len--;
            string s = Utf16.Decode(buf, len);
            Memory.Free(buf);
            return s;
        }
    }
#else
    memory_unsafe static class Native
    {
        static extern bool faset_px_stat(string path, long* data);
        static extern int faset_px_mkdir(string path, int mode);
        static extern bool faset_px_rmdir(string path);
        static extern bool faset_px_unlink(string path);
        static extern int faset_px_rename(string from, string to, bool overwrite);
        static extern bool faset_px_copy_file(string from, string to, bool overwrite);
        static extern bool faset_px_chmod(string path, int mode);
        static extern bool faset_px_set_mtime(string path, long ms);
        static extern long faset_px_open(string path, int flags);
        static extern long faset_px_read(long fd, byte* buffer, long count);
        static extern bool faset_px_write(long fd, byte* data, long count);
        static extern long faset_px_seek(long fd, long offset, int whence);
        static extern bool faset_px_truncate(long fd, long length);
        static extern bool faset_px_fsync(long fd);
        static extern void faset_px_close(long fd);
        static extern string faset_px_list_dir(string path, bool* ok);
        static extern bool faset_px_chdir(string path);
        static extern string faset_px_temp_dir();
        static extern string faset_get_cwd();
        static extern string faset_full_path(string path);

        public const bool IsWindows = false;
        public const bool IgnoreCase = false;

        public static func Stat(path: string, info: FileInfo*) -> bool
        {
            long* d = Memory.New<long>(8);
            bool ok = faset_px_stat(path, d);
            if (ok)
            {
                info->Exists = true;
                info->Kind = d[0] == 1 ? FileKind.File : d[0] == 2 ? FileKind.Directory : FileKind.Other;
                info->IsSymlink = d[1] != 0;
                info->Length = d[0] == 2 ? 0 : d[2];
                info->LastWriteTimeMs = d[3];
                info->LastAccessTimeMs = d[4];
                info->CreationTimeMs = d[5];
                info->Mode = (int)d[6];
                info->IsReadOnly = d[7] != 0;
            }
            Memory.Free(d);
            return ok;
        }

        public static func MkDir(path: string) -> int => faset_px_mkdir(path, 0x1FF);   // 0777;
        public static func RmDir(path: string) -> bool => faset_px_rmdir(path);
        public static func Unlink(path: string) -> bool => faset_px_unlink(path);
        public static func ForceUnlink(path: string) -> bool => faset_px_unlink(path);
        public static func Rename(from: string, to: string, overwrite: bool) -> int => faset_px_rename(from, to, overwrite);
        public static func CopyFile(from: string, to: string, overwrite: bool) -> bool => faset_px_copy_file(from, to, overwrite);
        public static func SetMode(path: string, mode: int) -> bool => faset_px_chmod(path, mode);

        public static func SetReadOnly(path: string, readOnly: bool) -> bool
        {
            FileInfo info = new FileInfo();
            if (!Stat(path, &info)) return false;
            return faset_px_chmod(path, readOnly ? info.Mode & ~0x92 : info.Mode | 0x80);
        }

        public static func SetMTime(path: string, ms: long) -> bool => faset_px_set_mtime(path, ms);
        public static func Open(path: string, flags: int) -> long => faset_px_open(path, flags);
        public static func Read(h: long, buffer: byte*, count: long) -> long => faset_px_read(h, buffer, count);
        public static func Write(h: long, data: byte*, count: long) -> bool => faset_px_write(h, data, count);
        public static func Seek(h: long, offset: long, whence: int) -> long => faset_px_seek(h, offset, whence);
        public static func Truncate(h: long, length: long) -> bool => faset_px_truncate(h, length);
        public static func Sync(h: long) -> bool => faset_px_fsync(h);
        public static func Close(h: long) { faset_px_close(h); }

        public static func ListDir(path: string, out ok: bool) -> string
        {
            bool good = false;
            string r = faset_px_list_dir(path, &good);
            ok = good;
            return r;
        }

        public static func GetCwd() -> string => faset_get_cwd();
        public static func SetCwd(path: string) -> bool => faset_px_chdir(path);
        public static func TempDir() -> string => faset_px_temp_dir();

        // Ruta canónica (resuelve enlaces); "" si no existe.
        public static func FullPath(path: string) -> string
        {
            FileInfo info = new FileInfo();
            if (!Stat(path, &info)) return String.Copy("");
            return faset_full_path(path);
        }
    }
#endif

    // ======================================================================= File

    public memory_unsafe static class File
    {
        // ---------------------------------------------------------------- texto y bytes

        // Lee todo el archivo. Devuelve una cadena nueva.
        public static func TryReadAllText(path: string, out content: string) -> bool
        {
            byte* data;
            long length;
            bool ok = TryReadAllBytes(path, out data, out length);
            content = String.FromBytes(data, length);
            return ok;
        }

        // Como TryReadAllText, pero si no se puede leer lanza FileNotFoundException (no existe)
        // o IOException.
        [TrackCaller] public static func ReadAllText(path: string) -> string
        {
            string s;
            if (!TryReadAllText(path, out s)) ThrowReadError("File.ReadAllText", path);
            return s;
        }

        [TrackCaller] static func ThrowReadError(what: string, path: string)
        {
            if (!Exists(path)) throw new FileNotFoundException(what + ": no se encontró el archivo '" + path + "'", path);
            throw new IOException(what + ": no se puede leer el archivo '" + path + "'");
        }

        // Lee todos los bytes. 'data' es memoria nueva terminada en 0,
        // también si falla (vacía).
        public static func TryReadAllBytes(path: string, out data: byte*, out length: long) -> bool
        {
            long h = Native.Open(path, 1);
            long cap = 0, len = 0;
            if (h != -1)
            {
                long end = Native.Seek(h, 0, 2);
                Native.Seek(h, 0, 0);
                cap = (end > 0 ? end : 0) + 4097;   // margen para archivos que crecen o sin tamaño (/proc)
            }
            byte* buf = (byte*)Memory.Alloc(cap > 0 ? cap : 1);
            bool ok = h != -1;
            if (ok)
            {
                for (;;)
                {
                    if (len + 1 >= cap)
                    {
                        cap *= 2;
                        buf = (byte*)Memory.Realloc(buf, cap);
                    }
                    long n = Native.Read(h, buf + len, cap - len - 1);
                    if (n < 0) ok = false;
                    if (n <= 0) break;
                    len += n;
                }
                Native.Close(h);
            }
            buf[len] = 0;
            data = buf;
            length = len;
            return ok;
        }

        public static func WriteAllText(path: string, text: string) -> bool => WriteAllBytes(path, text.Ptr, text.Length);
        public static func AppendAllText(path: string, text: string) -> bool => AppendAllBytes(path, text.Ptr, text.Length);

        // ---------------------------------------------------------------- async (std.task)
        // No hay E/S de archivos no bloqueante portátil (Linux, Windows y Android): la operación
        // corre en un hilo del grupo de tareas y 'await' no bloquea a quien espera (ni a la interfaz).
        // Los errores llegan como excepciones al hacer 'await' (FileNotFoundException, IOException).
        public static func ReadAllTextAsync(path: string) -> Task<string> => Task.Run(() => ReadAllText(path));

        public static func WriteAllTextAsync(path: string, text: string) -> Task
        {
            return Task.Run(() =>
            {
                if (!WriteAllText(path, text)) throw new IOException("File.WriteAllTextAsync: no se puede escribir el archivo '" + path + "'");
            });
        }

        public static func AppendAllTextAsync(path: string, text: string) -> Task
        {
            return Task.Run(() =>
            {
                if (!AppendAllText(path, text)) throw new IOException("File.AppendAllTextAsync: no se puede escribir el archivo '" + path + "'");
            });
        }
        public static func WriteAllBytes(path: string, data: byte*, length: long) -> bool => WriteRaw(path, data, length, 2 | 4 | 8);
        public static func AppendAllBytes(path: string, data: byte*, length: long) -> bool => WriteRaw(path, data, length, 2 | 4 | 32);

        static func WriteRaw(path: string, data: byte*, length: long, flags: int) -> bool
        {
            long h = Native.Open(path, flags);
            if (h == -1) return false;
#if WINDOWS
            if ((flags & 32) != 0) Native.Seek(h, 0, 2);
#endif
            bool ok = length <= 0 || Native.Write(h, data, length);
            Native.Close(h);
            return ok;
        }

        // ---------------------------------------------------------------- líneas

        // Líneas del archivo ('\n' o "\r\n"), sin el salto. Copias
        public static func TryReadAllLines(path: string, out lines: List<string>) -> bool
        {
            string text;
            bool ok = TryReadAllText(path, out text);
            List<string> list = new List<string>();
            int start = 0;
            for (int i = 0; i <= text.Length; i++)
            {
                if (i < text.Length && text[i] != '\n') continue;
                if (i == text.Length && start == i) break;
                int end = i;
                if (end > start && text[end - 1] == '\r') end--;
                list.Add(String.Copy(text.Substring(start, end - start)));
                start = i + 1;
            }
            String.Free(text);
            lines = list;
            return ok;
        }

        // Como TryReadAllLines, pero lanza FileNotFoundException o IOException si no se puede leer.
        [TrackCaller] public static func ReadAllLines(path: string) -> List<string>
        {
            List<string> lines;
            if (!TryReadAllLines(path, out lines)) ThrowReadError("File.ReadAllLines", path);
            return lines;
        }

        // Escribe cada línea seguida de '\n'.
        public static func WriteAllLines(path: string, lines: List<string>) -> bool => WriteRawLines(path, lines, false);
        public static func AppendAllLines(path: string, lines: List<string>) -> bool => WriteRawLines(path, lines, true);

        static func WriteRawLines(path: string, lines: List<string>, append: bool) -> bool
        {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < lines.Count; i++) sb.Append(lines[i]).Append("\n");
            string text = sb.View();
            bool ok = append ? AppendAllText(path, text) : WriteAllText(path, text);
            delete sb;
            return ok;
        }

        // Libera una lista de cadenas copiadas (ReadAllLines, Directory.GetFiles...).
        public static func FreeLines(lines: List<string>)
        {
            for (int i = 0; i < lines.Count; i++) String.Free(lines[i]);
            delete lines;
        }

        // ---------------------------------------------------------------- operaciones

        public static func Exists(path: string) -> bool
        {
            FileInfo info = new FileInfo();
            return Native.Stat(path, &info) && info.Kind != FileKind.Directory && info.Kind != FileKind.None;
        }

        public static func Delete(path: string) -> bool => Native.Unlink(path);

        // Mueve o renombra un archivo. Falla si el destino existe (salvo con overwrite = true).
        // Entre sistemas de archivos distintos copia y borra el original.
        public static func Move(from: string, to: string) -> bool => Move(from, to, false);

        public static func Move(from: string, to: string, overwrite: bool) -> bool
        {
            int r = Native.Rename(from, to, overwrite);
            if (r == 2 && Exists(from) && Native.CopyFile(from, to, overwrite)) return Native.Unlink(from);
            return r == 1;
        }

        // Copia un archivo (con sus permisos). Falla si el destino existe (salvo con overwrite = true).
        public static func Copy(from: string, to: string) -> bool => Native.CopyFile(from, to, false);
        public static func Copy(from: string, to: string, overwrite: bool) -> bool => Native.CopyFile(from, to, overwrite);

        // ---------------------------------------------------------------- metadatos

        public static func GetInfo(path: string) -> FileInfo => FileInfo.Get(path);

        // Tamaño en bytes (-1 si no existe).
        public static func GetSize(path: string) -> long
        {
            FileInfo info = FileInfo.Get(path);
            return info.Exists ? info.Length : -1;
        }

        // Fecha de la última escritura en ms Unix (-1 si no existe).
        public static func GetLastWriteTime(path: string) -> long
        {
            FileInfo info = FileInfo.Get(path);
            return info.Exists ? info.LastWriteTimeMs : -1;
        }

        public static func SetLastWriteTime(path: string, unixMs: long) -> bool => Native.SetMTime(path, unixMs);

        public static func IsReadOnly(path: string) -> bool => FileInfo.Get(path).IsReadOnly;
        public static func SetReadOnly(path: string, readOnly: bool) -> bool => Native.SetReadOnly(path, readOnly);

        // Permisos Unix (-1 si no existe). En Windows: 0444 o 0666 según el atributo de solo lectura.
        public static func GetUnixMode(path: string) -> int
        {
            FileInfo info = FileInfo.Get(path);
            return info.Exists ? info.Mode : -1;
        }

        public static func SetUnixMode(path: string, mode: int) -> bool => Native.SetMode(path, mode);

        // ---------------------------------------------------------------- flujos (null si falla)

        public static func Open(path: string, mode: FileMode, access: FileAccess) -> FileStream => FileStream.Open(path, mode, access);
        public static func OpenRead(path: string) -> FileStream => FileStream.Open(path, FileMode.Open, FileAccess.Read);
        public static func OpenWrite(path: string) -> FileStream => FileStream.Open(path, FileMode.Create, FileAccess.Write);
        public static func OpenAppend(path: string) -> FileStream => FileStream.Open(path, FileMode.Append, FileAccess.Write);
        public static func Create(path: string) -> FileStream => FileStream.Open(path, FileMode.Create, FileAccess.ReadWrite);
    }

    // ======================================================================= FileStream

    // Flujo de bytes con búfer sobre un archivo. Se cierra con Close o con delete.
    //   FileStream f = File.OpenRead("datos.txt");
    //   string line;
    //   while (f.ReadLine(out line)) { ...; String.Free(line); }
    //   delete f;
    public memory_unsafe class FileStream
    {
        const int BufferSize = 65536;
        var handle: long = -1;
        var canRead: bool
        var canWrite: bool
        var append: bool
        var buffer: byte*
        var readPos: int     // siguiente byte por leer del búfer
        var readLen: int     // bytes válidos de lectura en el búfer
        var writeLen: int    // bytes pendientes de escribir en el búfer
        var osPos: long      // posición del sistema operativo
        var failed: bool

        deinit { Close(); }

        // Abre un archivo. Devuelve null si no se puede.
        public static func Open(path: string, mode: FileMode, access: FileAccess) -> FileStream
        {
            int flags = (int)access;
            if (mode == FileMode.CreateNew) flags |= 4 | 16;
            else if (mode == FileMode.Create) flags |= 4 | 8;
            else if (mode == FileMode.OpenOrCreate) flags |= 4;
            else if (mode == FileMode.Truncate) flags |= 8;
            else if (mode == FileMode.Append) flags = 2 | 4 | 32;
            if ((flags & 2) == 0 && (flags & (4 | 8)) != 0) return null;   // crear o truncar exige escritura
            long h = Native.Open(path, flags);
            if (h == -1) return null;
            FileStream f = new FileStream();
            f.handle = h;
            f.canRead = (flags & 1) != 0;
            f.canWrite = (flags & 2) != 0;
            f.append = mode == FileMode.Append;
            f.buffer = (byte*)Memory.Alloc(BufferSize);
            if (f.append) f.osPos = Native.Seek(h, 0, 2);
            return f;
        }

        public prop IsOpen: bool => handle != -1;
        public prop CanRead: bool => handle != -1 && canRead;
        public prop CanWrite: bool => handle != -1 && canWrite;
        // true si alguna operación de lectura o escritura falló.
        public prop HasError: bool => failed;

        // ---------------------------------------------------------------- posición

        public prop Position: long
        {
            get => osPos + writeLen - (readLen - readPos);
            set { Seek(value, SeekOrigin.Begin); }
        }

        public prop Length: long
        {
            get
            {
                if (handle == -1) return 0;
                FlushWrite();
                long end = Native.Seek(handle, 0, 2);
                Native.Seek(handle, osPos, 0);
                return end;
            }
        }

        // Cambia la posición; devuelve la nueva (-1 si falla).
        public func Seek(offset: long, origin: SeekOrigin) -> long
        {
            if (handle == -1) return -1;
            if (!FlushWrite()) return -1;
            if (origin == SeekOrigin.Current) offset += Position;
            long target = origin == SeekOrigin.End ? Native.Seek(handle, offset, 2) : Native.Seek(handle, offset, 0);
            readPos = 0;
            readLen = 0;
            if (target < 0)
            {
                Native.Seek(handle, osPos, 0);
                return -1;
            }
            osPos = target;
            return target;
        }

        // Cambia el tamaño del archivo (la posición no cambia).
        public func SetLength(length: long) -> bool
        {
            if (!CanWrite || !FlushWrite()) return false;
            long pos = Position;
            DiscardRead();
            bool ok = Native.Truncate(handle, length);
            Seek(pos, SeekOrigin.Begin);
            return ok;
        }

        // ---------------------------------------------------------------- lectura

        // true si no quedan bytes por leer.
        public prop EndOfStream: bool
        {
            get
            {
                if (!CanRead || !FlushWrite()) return true;
                if (readPos < readLen) return false;
                return !Fill();
            }
        }

        // Lee hasta 'count' bytes. Devuelve los leídos (0 al final, -1 si falla).
        public func Read(destination: byte*, count: int) -> int
        {
            if (!CanRead || !FlushWrite()) return -1;
            if (count <= 0) return 0;
            int avail = readLen - readPos;
            if (avail == 0)
            {
                if (count >= BufferSize)
                {
                    long n = Native.Read(handle, destination, count);
                    if (n < 0) failed = true;
                    if (n > 0) osPos += n;
                    return (int)n;
                }
                if (!Fill()) return failed ? -1 : 0;
                avail = readLen - readPos;
            }
            int take = avail < count ? avail : count;
            Memory.Copy(destination, buffer + readPos, take);
            readPos += take;
            return take;
        }

        // Siguiente byte (0-255) o -1 al final.
        public func ReadByte() -> int
        {
            if (!CanRead || !FlushWrite()) return -1;
            if (readPos >= readLen && !Fill()) return -1;
            return buffer[readPos++];
        }

        // Lee una línea ('\n' o "\r\n", sin el salto). 'line' es una copia;
        // devuelve false al final del archivo.
        public func ReadLine(out line: string) -> bool
        {
            line = String.FromBytes(null, 0);
            if (!CanRead || !FlushWrite()) return false;
            StringBuilder sb = null;
            bool any = false;
            for (;;)
            {
                if (readPos >= readLen && !Fill()) break;
                any = true;
                int start = readPos;
                while (readPos < readLen && buffer[readPos] != '\n') readPos++;
                bool newline = readPos < readLen;
                string part = String.FromBytes(buffer + start, readPos - start);
                if (newline) readPos++;
                if (newline && sb == null)
                {
                    if (part.EndsWith("\r")) part = part.Substring(0, part.Length - 1);
                    line = String.Copy(part);
                    return true;
                }
                if (sb == null) sb = new StringBuilder();
                sb.Append(part);
                if (newline) break;
            }
            if (!any)
            {
                if (sb != null) delete sb;
                return false;
            }
            string all = sb.View();
            if (all.EndsWith("\r")) all = all.Substring(0, all.Length - 1);
            line = String.Copy(all);
            delete sb;
            return true;
        }

        // Lee desde la posición actual hasta el final (copia).
        public func ReadToEnd() -> string
        {
            StringBuilder sb = new StringBuilder();
            if (CanRead && FlushWrite())
            {
                while (readPos < readLen || Fill())
                {
                    sb.Append(String.FromBytes(buffer + readPos, readLen - readPos));
                    readPos = readLen;
                }
            }
            string s = sb.ToString();
            delete sb;
            return s;
        }

        func Fill() -> bool
        {
            readPos = 0;
            readLen = 0;
            long n = Native.Read(handle, buffer, BufferSize);
            if (n < 0) failed = true;
            if (n <= 0) return false;
            readLen = (int)n;
            osPos += n;
            return true;
        }

        // Si hay datos leídos sin consumir, vuelve a colocar el sistema en la posición lógica.
        func DiscardRead()
        {
            int unread = readLen - readPos;
            if (unread > 0)
            {
                osPos = Native.Seek(handle, osPos - unread, 0);
            }
            readPos = 0;
            readLen = 0;
        }

        // ---------------------------------------------------------------- escritura

        public func Write(data: byte*, count: long) -> bool
        {
            if (!CanWrite) return false;
            if (readLen > 0) DiscardRead();
            if (count <= 0) return true;
            if (writeLen + count > BufferSize)
            {
                if (!FlushWrite()) return false;
                if (count >= BufferSize) return WriteThrough(data, count);
            }
            Memory.Copy(buffer + writeLen, data, count);
            writeLen += (int)count;
            return true;
        }

        public func Write(text: string) -> bool => Write(text.Ptr, text.Length);
        public func WriteLine(text: string) -> bool => Write(text.Ptr, text.Length) && Write("\n");
        public func WriteLine() -> bool => Write("\n");

        public func WriteByte(value: byte) -> bool
        {
            byte b = value;
            return Write(&b, 1);
        }

        // Escribe el búfer en el sistema operativo.
        public func Flush() -> bool => FlushWrite();

        // Igual, y con toDisk = true espera a que los datos lleguen al disco (fsync).
        public func Flush(toDisk: bool) -> bool
        {
            if (!FlushWrite()) return false;
            return !toDisk || handle == -1 || Native.Sync(handle);
        }

        func FlushWrite() -> bool
        {
            if (writeLen == 0 || handle == -1) return true;
            int n = writeLen;
            writeLen = 0;
            return WriteThrough(buffer, n);
        }

        func WriteThrough(data: byte*, count: long) -> bool
        {
            if (append) osPos = Native.Seek(handle, 0, 2);
            if (!Native.Write(handle, data, count))
            {
                failed = true;
                return false;
            }
            osPos += count;
            return true;
        }

        // Escribe lo pendiente y cierra el archivo (también lo hace delete).
        public func Close()
        {
            if (handle == -1) return;
            FlushWrite();
            Native.Close(handle);
            handle = -1;
            Memory.Free(buffer);
            buffer = null;
            readPos = 0;
            readLen = 0;
        }
    }

    // ======================================================================= Directory

    public memory_unsafe static class Directory
    {
        public static func Exists(path: string) -> bool
        {
            FileInfo info = new FileInfo();
            return Native.Stat(path, &info) && info.Kind == FileKind.Directory;
        }

        // Crea la carpeta y las carpetas intermedias que falten. true si existe al terminar.
        public static func Create(path: string) -> bool
        {
            if (path.Length == 0) return false;
            int r = Native.MkDir(path);
            if (r == 0) return true;
            if (r == 1) return Exists(path);
            string parent = Path.GetDirectoryName(Path.TrimEndingSeparators(path));
            if (parent.Length == 0 || parent.Length >= path.Length || Exists(parent) || !Create(parent)) return Exists(path);
            return Native.MkDir(path) != 2 && Exists(path);
        }

        // Borra una carpeta con todo su contenido. Los enlaces simbólicos se borran sin seguirlos.
        public static func Delete(path: string) -> bool => Delete(path, true);

        // Con recursive = false solo borra carpetas vacías.
        public static func Delete(path: string, recursive: bool) -> bool
        {
            FileInfo info = FileInfo.Get(path);
            if (!info.Exists) return false;
            if (info.IsSymlink) return Native.RmDir(path) || Native.Unlink(path);
            if (info.Kind != FileKind.Directory) return false;
            return recursive ? DeleteTree(path) : Native.RmDir(path);
        }

        static func DeleteTree(path: string) -> bool
        {
            bool ok;
            string raw = Native.ListDir(path, out ok);
            int start = 0;
            for (int i = 0; i < raw.Length; i++)
            {
                if (raw[i] != 0) continue;
                byte kind = raw[start];
                string child = Path.Combine(path, raw.Substring(start + 1, i - start - 1));
                if (kind == 'd') DeleteTree(child);
                else if (kind == 'D') { if (!Native.RmDir(child)) Native.Unlink(child); }   // enlace: no se sigue
                else Native.ForceUnlink(child);
                String.Free(child);
                start = i + 1;
            }
            String.Free(raw);
            return Native.RmDir(path);
        }

        // Mueve o renombra una carpeta (falla si el destino existe).
        public static func Move(from: string, to: string) -> bool => Native.Rename(from, to, false) == 1;

        // Carpeta de trabajo actual (copia).
        public static func GetCurrent() -> string => Native.GetCwd();
        public static func SetCurrent(path: string) -> bool => Native.SetCwd(path);

        // Crea una carpeta nueva y única dentro de la carpeta temporal y devuelve su ruta
        // (copia; "" si falla). Bórrala con Directory.Delete al terminar.
        public static func CreateTemp(prefix: string) -> string
        {
            string tmp = Path.GetTempPath();
            for (int attempt = 0; attempt < 100; attempt++)
            {
                string name = Path.GetRandomFileName();
                string leaf = String.Concat(prefix, name);
                string full = Path.Combine(tmp, leaf);
                String.Free(leaf);
                String.Free(name);
                if (Native.MkDir(full) == 0)
                {
                    String.Free(tmp);
                    return full;
                }
                String.Free(full);
            }
            String.Free(tmp);
            return String.Copy("");
        }

        // ---------------------------------------------------------------- enumeración

        // Contenido de una carpeta: primero subcarpetas y luego archivos, por nombre.
        public static func GetEntries(path: string) -> List<DirEntry>
        {
            List<DirEntry> dirs = new List<DirEntry>();
            List<DirEntry> files = new List<DirEntry>();
            bool ok;
            string raw = Native.ListDir(path, out ok);
            int start = 0;
            for (int i = 0; i < raw.Length; i++)
            {
                if (raw[i] != 0) continue;
                if (i > start)
                {
                    byte kind = raw[start];
                    DirEntry e;
                    e.IsDirectory = kind == 'd' || kind == 'D';
                    e.IsSymlink = kind == 'D' || kind == 'F' || kind == 'L';
                    e.Name = String.Copy(raw.Substring(start + 1, i - start - 1));
                    if (e.IsDirectory) dirs.Add(e);
                    else files.Add(e);
                }
                start = i + 1;
            }
            String.Free(raw);
            dirs.Sort(&CompareEntries);
            files.Sort(&CompareEntries);
            dirs.AddRange(files);
            delete files;
            return dirs;
        }

        public static func FreeEntries(entries: List<DirEntry>)
        {
            for (int i = 0; i < entries.Count; i++) String.Free(entries[i].Name);
            delete entries;
        }

        // Rutas (Path.Combine(path, nombre)) de los archivos de la carpeta, ordenadas por nombre.
        // 'pattern' admite '*' y '?' ("*.fst"); con recursive = true recorre las subcarpetas
        // (sin entrar en enlaces simbólicos).
        public static func GetFiles(path: string) -> List<string> => Enumerate(path, "*", false, true, false);
        public static func GetFiles(path: string, pattern: string) -> List<string> => Enumerate(path, pattern, false, true, false);
        public static func GetFiles(path: string, pattern: string, recursive: bool) -> List<string> => Enumerate(path, pattern, recursive, true, false);

        // Igual que GetFiles, para subcarpetas.
        public static func GetDirectories(path: string) -> List<string> => Enumerate(path, "*", false, false, true);
        public static func GetDirectories(path: string, pattern: string) -> List<string> => Enumerate(path, pattern, false, false, true);
        public static func GetDirectories(path: string, pattern: string, recursive: bool) -> List<string> => Enumerate(path, pattern, recursive, false, true);

        // Archivos y carpetas a la vez (en cada carpeta: primero subcarpetas, luego archivos).
        public static func GetFileSystemEntries(path: string, pattern: string, recursive: bool) -> List<string> => Enumerate(path, pattern, recursive, true, true);

        public static func FreeList(paths: List<string>) { File.FreeLines(paths); }

        static func Enumerate(path: string, pattern: string, recursive: bool, files: bool, dirs: bool) -> List<string>
        {
            List<string> result = new List<string>();
            Walk(path, pattern, recursive, files, dirs, result);
            return result;
        }

        static func Walk(path: string, pattern: string, recursive: bool, files: bool, dirs: bool, result: List<string>)
        {
            List<DirEntry> entries = GetEntries(path);
            for (int i = 0; i < entries.Count; i++)
            {
                DirEntry e = entries[i];
                bool match = Path.MatchesPattern(e.Name, pattern);
                string full = Path.Combine(path, e.Name);
                if (match && (e.IsDirectory ? dirs : files)) result.Add(String.Copy(full));
                if (e.IsDirectory && dirs && !files && recursive && !e.IsSymlink) Walk(full, pattern, true, files, dirs, result);
                String.Free(full);
            }
            if (recursive && files)
            {
                for (int i = 0; i < entries.Count; i++)
                {
                    DirEntry e = entries[i];
                    if (!e.IsDirectory || e.IsSymlink) continue;
                    string full = Path.Combine(path, e.Name);
                    Walk(full, pattern, true, files, dirs, result);
                    String.Free(full);
                }
            }
            FreeEntries(entries);
        }

        static func CompareEntries(a: DirEntry, b: DirEntry) -> int
        {
            string x = a.Name.ToLower(), y = b.Name.ToLower();
            int c = x.CompareTo(y);
            String.Free(x);
            String.Free(y);
            return c != 0 ? c : a.Name.CompareTo(b.Name);
        }
    }

    // ======================================================================= Path

    // Las funciones de Path que devuelven una parte de la ruta (GetFileName, GetExtension...)
    // devuelven vistas de la original; las demás, copias nuevas.
    public memory_unsafe static class Path
    {
#if WINDOWS
        public static prop DirectorySeparatorChar: char => '\\';
        public static prop PathSeparator: char => ';';
#else
        public static prop DirectorySeparatorChar: char => '/';
        public static prop PathSeparator: char => ':';
#endif
        public static prop AltDirectorySeparatorChar: char => '/';

        static func IsSep(c: byte) -> bool => c == '/' || (Native.IsWindows && c == '\\');

        // true para '/' (y '\' en Windows).
        public static func IsSeparator(c: char) -> bool => c == '/' || (Native.IsWindows && c == '\\');

        static func LastSeparator(path: string) -> int
        {
            for (int i = path.Length - 1; i >= 0; i--)
                if (path[i] == '/' || path[i] == '\\') return i;
            return -1;
        }

        public static func GetFileName(path: string) -> string => path.Substring(LastSeparator(path) + 1);

        // Carpeta que contiene 'path' ("" si no tiene; "/" para "/archivo").
        public static func GetDirectoryName(path: string) -> string
        {
            int i = LastSeparator(path);
            if (i < 0) return "";
            int root = GetPathRoot(path).Length;
            if (i < root) return path.Length > root ? path.Substring(0, root) : "";
            int end = i;
            while (end > root && (path[end - 1] == '/' || path[end - 1] == '\\')) end--;
            return path.Substring(0, end > 0 ? end : root);
        }

        public static func GetExtension(path: string) -> string
        {
            string name = GetFileName(path);
            int dot = name.LastIndexOf(".");
            return dot <= 0 ? "" : name.Substring(dot);
        }

        public static func HasExtension(path: string) -> bool => GetExtension(path).Length > 1;

        public static func GetFileNameWithoutExtension(path: string) -> string
        {
            string name = GetFileName(path);
            int dot = name.LastIndexOf(".");
            return dot <= 0 ? name : name.Substring(0, dot);
        }

        // Cambia la extensión ("txt" o ".txt"; "" la quita). Copia.
        public static func ChangeExtension(path: string, extension: string) -> string
        {
            string name = GetFileName(path);
            int dot = name.LastIndexOf(".");
            string stem = dot <= 0 ? path : path.Substring(0, path.Length - name.Length + dot);
            if (extension.Length == 0) return String.Copy(stem);
            if (extension.StartsWith(".")) return String.Concat(stem, extension);
            return String.Concat(stem, ".", extension);
        }

        // Raíz de la ruta (vista): "/" en POSIX; "C:\", "C:", "\" o "\\servidor\recurso\" en Windows.
        public static func GetPathRoot(path: string) -> string
        {
            if (path.Length == 0) return "";
#if WINDOWS
            if (path.Length >= 2 && path[1] == ':' && Char.IsLetter((char)path[0]))
                return path.Length >= 3 && IsSep(path[2]) ? path.Substring(0, 3) : path.Substring(0, 2);
            if (path.Length >= 2 && IsSep(path[0]) && IsSep(path[1]))
            {
                int i = 2, parts = 0;
                while (i < path.Length && parts < 2)
                {
                    if (IsSep(path[i])) parts++;
                    i++;
                }
                return path.Substring(0, i);
            }
#endif
            return IsSep(path[0]) ? path.Substring(0, 1) : "";
        }

        // true si la ruta empieza por una raíz ("/", "C:\", "\\servidor"...).
        public static func IsPathRooted(path: string) -> bool => GetPathRoot(path).Length > 0;
        public static func IsRooted(path: string) -> bool => IsPathRooted(path);

        // Une dos partes con '/' (copia). Si 'b' tiene raíz, devuelve una copia de 'b'.
        public static func Combine(a: string, b: string) -> string
        {
            if (a.Length == 0 || IsPathRooted(b)) return String.Copy(b);
            if (b.Length == 0) return String.Copy(a);
            if (a.EndsWith("/") || a.EndsWith("\\")) return String.Concat(a, b);
            return String.Concat(a, "/", b);
        }

        public static func Combine(a: string, b: string, c: string) -> string
        {
            string ab = Combine(a, b);
            string r = Combine(ab, c);
            String.Free(ab);
            return r;
        }

        // Quita los separadores finales (vista), salvo el de la raíz.
        public static func TrimEndingSeparators(path: string) -> string
        {
            int root = GetPathRoot(path).Length;
            int n = path.Length;
            while (n > root && (path[n - 1] == '/' || path[n - 1] == '\\')) n--;
            return path.Substring(0, n);
        }

        // Cambia todos los separadores por el del sistema (copia).
        public static func NormalizeSeparators(path: string) -> string
        {
            byte* p = (byte*)Memory.Alloc(path.Length + 1);
            byte sep = (byte)DirectorySeparatorChar;
            for (int i = 0; i < path.Length; i++) p[i] = IsSep(path[i]) ? sep : path[i];
            p[path.Length] = 0;
            return String.FromBytes(p, path.Length);
        }

        // Normaliza una ruta sin tocar el disco: separadores del sistema, sin repetidos,
        // sin '.', y con los '..' resueltos (copia). "" -> ".".
        public static func Normalize(path: string) -> string
        {
            string root = GetPathRoot(path);
            string rest = path.Substring(root.Length);
            List<string> parts = new List<string>();
            int start = 0;
            for (int i = 0; i <= rest.Length; i++)
            {
                if (i < rest.Length && !IsSep(rest[i])) continue;
                string part = rest.Substring(start, i - start);
                start = i + 1;
                if (part.Length == 0 || part == ".") continue;
                if (part == "..")
                {
                    if (parts.Count > 0 && parts.Last() != "..") parts.Pop();
                    else if (root.Length == 0) parts.Add(part);
                    continue;
                }
                parts.Add(part);
            }
            StringBuilder sb = new StringBuilder();
            string sep = DirectorySeparatorChar == '/' ? "/" : "\\";
            for (int i = 0; i < root.Length; i++)
            {
                if (IsSep(root[i])) sb.Append(sep);
                else sb.Append((char)root[i]);
            }
            for (int i = 0; i < parts.Count; i++)
            {
                if (i > 0) sb.Append(sep);
                sb.Append(parts[i]);
            }
            if (sb.Length == 0) sb.Append(".");
            delete parts;
            string r = sb.ToString();
            delete sb;
            return r;
        }

        // Ruta absoluta (copia). En POSIX, si existe, es la canónica (sin enlaces simbólicos);
        // si no existe se resuelve sin tocar el disco.
        public static func GetFullPath(path: string) -> string
        {
            string full = Native.FullPath(path);
            if (full.Length > 0) return full;
            String.Free(full);
            return Absolute(path);
        }

        // Ruta absoluta resuelta sin tocar el disco (copia).
        static func Absolute(path: string) -> string
        {
#if WINDOWS
            string full = Native.FullPath(path);
            if (full.Length > 0) return full;
            String.Free(full);
#endif
            if (IsPathRooted(path)) return Normalize(path);
            string cwd = Native.GetCwd();
            string joined = Combine(cwd, path);
            string r = Normalize(joined);
            String.Free(joined);
            String.Free(cwd);
            return r;
        }

        // Ruta de 'path' relativa a la carpeta 'relativeTo' (copia), p. ej. "../b/c.txt".
        // Si no comparten raíz devuelve la ruta absoluta de 'path'.
        public static func GetRelativePath(relativeTo: string, path: string) -> string
        {
            string from = Absolute(relativeTo), to = Absolute(path);
            List<string> a = Segments(from), b = Segments(to);
            string result;
            if (!SameText(GetPathRoot(from), GetPathRoot(to))) result = String.Copy(to);
            else
            {
                int common = 0;
                while (common < a.Count && common < b.Count && SameText(a[common], b[common])) common++;
                StringBuilder sb = new StringBuilder();
                string sep = DirectorySeparatorChar == '/' ? "/" : "\\";
                for (int i = common; i < a.Count; i++)
                {
                    if (sb.Length > 0) sb.Append(sep);
                    sb.Append("..");
                }
                for (int i = common; i < b.Count; i++)
                {
                    if (sb.Length > 0) sb.Append(sep);
                    sb.Append(b[i]);
                }
                if (sb.Length == 0) sb.Append(".");
                result = sb.ToString();
                delete sb;
            }
            delete a;
            delete b;
            String.Free(from);
            String.Free(to);
            return result;
        }

        // Partes (vistas) de una ruta normalizada, sin la raíz.
        static func Segments(path: string) -> List<string>
        {
            List<string> parts = new List<string>();
            string rest = path.Substring(GetPathRoot(path).Length);
            int start = 0;
            for (int i = 0; i <= rest.Length; i++)
            {
                if (i < rest.Length && !IsSep(rest[i])) continue;
                if (i > start) parts.Add(rest.Substring(start, i - start));
                start = i + 1;
            }
            return parts;
        }

        static func SameText(a: string, b: string) -> bool => Native.IgnoreCase ? a.EqualsIgnoreCase(b) : a == b;

        // Carpeta temporal del sistema, sin separador final (copia).
        public static func GetTempPath() -> string => Native.TempDir();

        // Nombre aleatorio de 8 + 3 caracteres, p. ej. "k3x9q0ab.r2t" (copia).
        public static func GetRandomFileName() -> string
        {
            byte* p = (byte*)Memory.Alloc(13);
            for (int i = 0; i < 12; i++)
            {
                if (i == 8)
                {
                    p[i] = (byte)'.';
                    continue;
                }
                int v = (int)(NextRandom() % 36);
                p[i] = (byte)(v < 10 ? '0' + v : 'a' + v - 10);
            }
            p[12] = 0;
            return String.FromBytes(p, 12);
        }

        // Crea un archivo vacío y único en la carpeta temporal y devuelve su ruta (copia; "" si falla).
        public static func GetTempFileName() -> string
        {
            string tmp = GetTempPath();
            for (int attempt = 0; attempt < 100; attempt++)
            {
                string name = GetRandomFileName();
                string leaf = String.Concat("tmp", name, ".tmp");
                string full = Combine(tmp, leaf);
                String.Free(leaf);
                String.Free(name);
                long h = Native.Open(full, 2 | 4 | 16);
                if (h != -1)
                {
                    Native.Close(h);
                    String.Free(tmp);
                    return full;
                }
                String.Free(full);
            }
            String.Free(tmp);
            return String.Copy("");
        }

        static var randomState: ulong

        static func NextRandom() -> ulong
        {
            if (randomState == 0)
            {
                FileInfo info = new FileInfo();
                randomState = ((ulong)Environment.TickCount64() * (ulong)0x9E3779B97F4A7C15) ^ (ulong)(long)(void*)&info ^ (ulong)0x2545F4914F6CDD1D;
            }
            randomState ^= randomState >> 12;
            randomState ^= randomState << 25;
            randomState ^= randomState >> 27;
            return randomState * (ulong)0x2545F4914F6CDD1D;
        }

        // Comprueba un nombre contra un patrón con '*' (cualquier texto) y '?' (un carácter).
        // "*" y "*.*" aceptan todo. En Windows no distingue mayúsculas (ASCII).
        public static func MatchesPattern(name: string, pattern: string) -> bool
        {
            if (pattern.Length == 0 || pattern == "*" || pattern == "*.*") return true;
            int n = 0, p = 0, starP = -1, starN = 0;
            while (n < name.Length)
            {
                if (p < pattern.Length && pattern[p] == '*')
                {
                    starP = p++;
                    starN = n;
                }
                else if (p < pattern.Length && (pattern[p] == '?' || SameByte(pattern[p], name[n])))
                {
                    if (pattern[p] == '?') n = NextChar(name, n);
                    else n++;
                    p++;
                }
                else if (starP >= 0)
                {
                    p = starP + 1;
                    starN = NextChar(name, starN);
                    n = starN;
                }
                else return false;
            }
            while (p < pattern.Length && pattern[p] == '*') p++;
            return p == pattern.Length;
        }

        static func NextChar(s: string, i: int) -> int
        {
            i++;
            while (i < s.Length && (s[i] & 0xC0) == 0x80) i++;
            return i;
        }

        static func SameByte(a: byte, b: byte) -> bool =>
            a == b || (Native.IgnoreCase && Char.ToLower((char)a) == Char.ToLower((char)b));
    }

    // ======================================================================= FileWatcher

    public enum WatcherChangeKind { Created, Deleted, Changed }

    public struct FileChange
    {
        public var Kind: WatcherChangeKind
        public var Path: string        // copia (FileWatcher.FreeChanges)
        public var IsDirectory: bool
    }

    struct WatchStamp
    {
        public var Time: long
        public var Length: long
        public var IsDirectory: bool
    }

#if !WINDOWS
    static class Inotify
    {
        public static extern int faset_px_watch_init();
        public static extern int faset_px_watch_add(int fd, string path);
        public static extern string faset_px_watch_read(int fd);
        public static extern void faset_px_close(long fd);
        public static extern bool faset_px_poll(int* fds, int count, int writeFd, int milliseconds);
    }
#endif

    // Vigila los cambios dentro de una carpeta (o de un archivo):
    //   FileWatcher w = new FileWatcher("src", true);
    //   List<FileChange> changes = new List<FileChange>;
    //   if (w.WaitForChanges(changes, 1000) > 0) { ... }
    //   FileWatcher.FreeChanges(changes);
    // En Linux usa inotify; en el resto (o si inotify falla) compara instantáneas de la carpeta
    // cada PollIntervalMs. Los renombrados aparecen como Deleted + Created.
    public memory_unsafe class FileWatcher
    {
        var root: string
        var recursive: bool
        var fd: int = -1;
        var watches: Dictionary<int, string>          // inotify: descriptor -> carpeta
        var snapshot: Dictionary<string, WatchStamp>  // sondeo: ruta -> fecha y tamaño
        var lastScan: long
        public var PollIntervalMs: int = 500;

        public init(path: string, includeSubdirectories: bool) { Init(path, includeSubdirectories, false); }

        // Con usePolling = true compara instantáneas aunque haya inotify (p. ej. carpetas de red).
        public init(path: string, includeSubdirectories: bool, usePolling: bool) { Init(path, includeSubdirectories, usePolling); }

        func Init(path: string, includeSubdirectories: bool, usePolling: bool)
        {
            root = String.Copy(path);
            recursive = includeSubdirectories;
#if !WINDOWS
            if (!usePolling) fd = Inotify.faset_px_watch_init();
            if (fd >= 0)
            {
                watches = new Dictionary<int, string>();
                if (!AddWatch(root))
                {
                    Inotify.faset_px_close(fd);
                    fd = -1;
                    FreeWatches();
                }
                else if (recursive && Directory.Exists(root))
                {
                    List<string> dirs = Directory.GetDirectories(root, "*", true);
                    for (int i = 0; i < dirs.Count; i++) AddWatch(dirs[i]);
                    Directory.FreeList(dirs);
                }
            }
#endif
            if (fd < 0)
            {
                snapshot = Scan();
                lastScan = Environment.TickCount64();
            }
        }

        deinit
        {
#if !WINDOWS
            if (fd >= 0) Inotify.faset_px_close(fd);
#endif
            FreeWatches();
            if (snapshot != null) FreeSnapshot(snapshot);
            String.Free(root);
        }

        // true si usa avisos del sistema (inotify) en lugar de sondeo.
        public prop IsNative: bool => fd >= 0;
        public prop WatchedPath: string => root;

        // Añade a 'changes' los cambios ocurridos desde la última llamada, sin esperar.
        // Devuelve cuántos añadió.
        public func Poll(changes: List<FileChange>) -> int
        {
            int before = changes.Count;
#if !WINDOWS
            if (fd >= 0)
            {
                ReadEvents(changes);
                return changes.Count - before;
            }
#endif
            long now = Environment.TickCount64();
            if (now - lastScan < PollIntervalMs) return 0;
            lastScan = now;
            Dictionary<string, WatchStamp> next = Scan();
            List<string> keys = next.Keys();
            for (int i = 0; i < keys.Count; i++)
            {
                WatchStamp cur = next.Get(keys[i]);
                WatchStamp old;
                if (!snapshot.TryGetValue(keys[i], out old)) Add(changes, WatcherChangeKind.Created, keys[i], cur.IsDirectory);
                else if (!cur.IsDirectory && (old.Time != cur.Time || old.Length != cur.Length))
                    Add(changes, WatcherChangeKind.Changed, keys[i], false);
            }
            delete keys;
            List<string> gone = snapshot.Keys();
            for (int i = 0; i < gone.Count; i++)
                if (!next.ContainsKey(gone[i])) Add(changes, WatcherChangeKind.Deleted, gone[i], snapshot.Get(gone[i]).IsDirectory);
            delete gone;
            FreeSnapshot(snapshot);
            snapshot = next;
            return changes.Count - before;
        }

        // Espera hasta 'timeoutMs' (-1 = sin límite) a que haya cambios y los añade a 'changes'.
        public func WaitForChanges(changes: List<FileChange>, timeoutMs: int) -> int
        {
            long start = Environment.TickCount64();
            for (;;)
            {
                int n = Poll(changes);
                if (n > 0) return n;
                long left = timeoutMs < 0 ? 1000 : timeoutMs - (Environment.TickCount64() - start);
                if (left <= 0) return 0;
#if !WINDOWS
                if (fd >= 0)
                {
                    int f = fd;
                    Inotify.faset_px_poll(&f, 1, -1, (int)(left < 1000 ? left : 1000));
                    continue;
                }
#endif
                long wait = PollIntervalMs - (Environment.TickCount64() - lastScan);
                if (wait < 1) wait = 1;
                std.time.Time.Sleep(wait < left ? wait : left);
            }
        }

        // Libera las rutas de los cambios y vacía la lista (no la borra).
        public static func FreeChanges(changes: List<FileChange>)
        {
            for (int i = 0; i < changes.Count; i++) String.Free(changes[i].Path);
            changes.Clear();
        }

        static func Add(changes: List<FileChange>, kind: WatcherChangeKind, path: string, isDir: bool)
        {
            // Une los avisos repetidos seguidos (varias escrituras al mismo archivo).
            for (int i = changes.Count - 1; i >= 0 && i >= changes.Count - 4; i--)
                if (changes[i].Kind == kind && changes[i].Path == path) return;
            FileChange c;
            c.Kind = kind;
            c.Path = String.Copy(path);
            c.IsDirectory = isDir;
            changes.Add(c);
        }

        // ---------------------------------------------------------------- inotify
#if !WINDOWS
        func AddWatch(dir: string) -> bool
        {
            int wd = Inotify.faset_px_watch_add(fd, dir);
            if (wd < 0) return false;
            string old;
            if (watches.TryGetValue(wd, out old)) String.Free(old);
            watches.Set(wd, String.Copy(dir));
            return true;
        }

        func ReadEvents(changes: List<FileChange>)
        {
            string raw = Inotify.faset_px_watch_read(fd);
            int start = 0;
            for (int i = 0; i < raw.Length; i++)
            {
                if (raw[i] != 0) continue;
                string ev = raw.Substring(start, i - start);
                start = i + 1;
                int colon = ev.IndexOf(":");
                if (ev.Length < 3 || colon < 0) continue;
                byte kind = ev[0];
                bool isDir = ev[1] == '1';
                int wd = ev.Substring(2, colon - 2).ToInt();
                string name = ev.Substring(colon + 1);
                string dir;
                if (!watches.TryGetValue(wd, out dir)) continue;
                if (kind == 'x')
                {
                    if (name.Length == 0 && dir == root) Add(changes, WatcherChangeKind.Deleted, root, true);
                    continue;
                }
                string full = name.Length > 0 ? Path.Combine(dir, name) : String.Copy(dir);
                if (kind == 'c')
                {
                    Add(changes, WatcherChangeKind.Created, full, isDir);
                    if (isDir && recursive)
                    {
                        AddWatch(full);
                        // Lo creado antes de añadir la vigilancia también cuenta.
                        List<string> inner = Directory.GetFileSystemEntries(full, "*", true);
                        for (int k = 0; k < inner.Count; k++)
                        {
                            bool d = Directory.Exists(inner[k]);
                            Add(changes, WatcherChangeKind.Created, inner[k], d);
                            if (d) AddWatch(inner[k]);
                        }
                        Directory.FreeList(inner);
                    }
                }
                else if (kind == 'd') Add(changes, WatcherChangeKind.Deleted, full, isDir);
                else if (!isDir) Add(changes, WatcherChangeKind.Changed, full, false);
                String.Free(full);
            }
            String.Free(raw);
        }
#endif

        func FreeWatches()
        {
            if (watches == null) return;
            List<string> dirs = watches.Values();
            for (int i = 0; i < dirs.Count; i++) String.Free(dirs[i]);
            delete dirs;
            delete watches;
            watches = null;
        }

        // ---------------------------------------------------------------- sondeo

        func Scan() -> Dictionary<string, WatchStamp>
        {
            Dictionary<string, WatchStamp> map = new Dictionary<string, WatchStamp>();
            FileInfo info = FileInfo.Get(root);
            if (info.IsDirectory)
            {
                List<string> all = Directory.GetFileSystemEntries(root, "*", recursive);
                for (int i = 0; i < all.Count; i++)
                {
                    FileInfo fi = FileInfo.Get(all[i]);
                    WatchStamp s;
                    s.Time = fi.LastWriteTimeMs;
                    s.Length = fi.Length;
                    s.IsDirectory = fi.IsDirectory;
                    map.Set(all[i], s);   // la clave es la copia de la lista
                }
                delete all;
            }
            else if (info.Exists)
            {
                WatchStamp s;
                s.Time = info.LastWriteTimeMs;
                s.Length = info.Length;
                s.IsDirectory = false;
                map.Set(String.Copy(root), s);
            }
            return map;
        }

        static func FreeSnapshot(map: Dictionary<string, WatchStamp>)
        {
            List<string> keys = map.Keys();
            for (int i = 0; i < keys.Count; i++) String.Free(keys[i]);
            delete keys;
            delete map;
        }
    }
}
