// =============================================================================
//  std.compression  —  Deflate, zlib, gzip y archivos .zip.
//
//    string comprimido = GZip.Compress(texto);
//    string original = GZip.Decompress(comprimido);
//
//    var zip = new ZipArchive();
//    zip.AddEntry("hola.txt", "¡Hola!");
//    zip.AddFile("datos/informe.pdf", "informe.pdf");
//    zip.Save("paquete.zip");
//
//    var leido = ZipArchive.Open("paquete.zip");
//    foreach (var e in leido.Entries) println($"{e.FullName}: {e.Length} bytes");
//    string hola = leido.GetEntry("hola.txt").ReadAllText();
//
//  Los datos binarios son cadenas (string): una cadena de Faset es una vista de bytes y
//  puede contener cualquier valor, también ceros. Deflate e Inflate vienen de miniz
//  (licencia MIT, lib/compression/miniz), compatible con zlib, gzip, zip y unzip.
//  Los datos dañados lanzan InvalidDataException.
// =============================================================================
using std.collections;
using std.text;
using std.io;
using std.time;

namespace std.compression
{
    // Nivel de compresión (como System.IO.Compression.CompressionLevel).
    public enum CompressionLevel { Optimal, Fastest, NoCompression, SmallestSize }

    // Los datos comprimidos no son válidos, están truncados o su suma de comprobación no coincide.
    [ExceptionBase("IOException")]
    public class InvalidDataException
    {
        public InvalidDataException() { Message = "Los datos no son válidos."; }
        public InvalidDataException(string message) { Message = message; }
        public InvalidDataException(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }

        public string ToString() => Exception.Describe(this);
    }

    // Funciones de lib/compression/faset_compression.c (miniz).
    memory_unsafe static class Zlib
    {
        public static extern long faset_deflate(byte* src, long n, int level, int format, byte** output);
        public static extern long faset_inflate(byte* src, long n, int format, byte** output);
        public static extern uint faset_crc32(uint crc, byte* p, long n);
        public static extern uint faset_adler32(uint adler, byte* p, long n);

        public static int Level(CompressionLevel level)
        {
            if (level == CompressionLevel.Fastest) return 1;
            if (level == CompressionLevel.NoCompression) return 0;
            if (level == CompressionLevel.SmallestSize) return 9;
            return 6;
        }

        public static string Compress(string data, CompressionLevel level, int format)
        {
            byte* output = null;
            long n = faset_deflate(data.Ptr, data.Length, Level(level), format, &output);
            if (n < 0) throw new InvalidOperationException("Deflate: no hay memoria suficiente");
            return String.FromBytes(output, n);
        }

        public static string Decompress(string data, int format, string what)
        {
            byte* output = null;
            long n = faset_inflate(data.Ptr, data.Length, format, &output);
            if (n == -3) throw new InvalidDataException(what + ": la suma de comprobación no coincide (datos dañados)");
            if (n < 0) throw new InvalidDataException(what + ": los datos comprimidos no son válidos o están incompletos");
            return String.FromBytes(output, n);
        }
    }

    // Deflate sin cabecera (RFC 1951), como DeflateStream de .NET.
    public static class Deflate
    {
        public static string Compress(string data) => Zlib.Compress(data, CompressionLevel.Optimal, 0);
        public static string Compress(string data, CompressionLevel level) => Zlib.Compress(data, level, 0);
        [TrackCaller] public static string Decompress(string data) => Zlib.Decompress(data, 0, "Deflate.Decompress");
    }

    // Formato zlib (RFC 1950: Deflate con cabecera de 2 bytes y Adler-32), como ZLibStream.
    public static class ZLib
    {
        public static string Compress(string data) => Zlib.Compress(data, CompressionLevel.Optimal, 1);
        public static string Compress(string data, CompressionLevel level) => Zlib.Compress(data, level, 1);
        [TrackCaller] public static string Decompress(string data) => Zlib.Decompress(data, 1, "ZLib.Decompress");
    }

    // Formato gzip (RFC 1952), compatible con la herramienta gzip. Decompress acepta
    // varios miembros seguidos (como 'cat a.gz b.gz').
    public static class GZip
    {
        public static string Compress(string data) => Zlib.Compress(data, CompressionLevel.Optimal, 2);
        public static string Compress(string data, CompressionLevel level) => Zlib.Compress(data, level, 2);
        [TrackCaller] public static string Decompress(string data) => Zlib.Decompress(data, 2, "GZip.Decompress");

        // Comprime el archivo 'source' en 'destination' (p. ej. "datos.txt" -> "datos.txt.gz").
        [TrackCaller] public static void CompressFile(string source, string destination)
        {
            string data = File.ReadAllText(source);
            if (!File.WriteAllText(destination, Compress(data))) throw new IOException("GZip.CompressFile: no se puede escribir '" + destination + "'");
        }

        [TrackCaller] public static void DecompressFile(string source, string destination)
        {
            string data = File.ReadAllText(source);
            if (!File.WriteAllText(destination, Decompress(data))) throw new IOException("GZip.DecompressFile: no se puede escribir '" + destination + "'");
        }
    }

    // Sumas de comprobación CRC-32 (la de zip, gzip y PNG) y Adler-32 (la de zlib).
    public memory_unsafe static class Crc32
    {
        public static uint Compute(string data) => Zlib.faset_crc32(0, data.Ptr, data.Length);
        // Continúa un CRC calculado antes (para datos en trozos).
        public static uint Append(uint crc, string data) => Zlib.faset_crc32(crc, data.Ptr, data.Length);
    }

    public memory_unsafe static class Adler32
    {
        public static uint Compute(string data) => Zlib.faset_adler32(1, data.Ptr, data.Length);
        public static uint Append(uint adler, string data) => Zlib.faset_adler32(adler, data.Ptr, data.Length);
    }

    // ---------------------------------------------------------------- .zip

    // Una entrada (archivo o carpeta) de un ZipArchive.
    public class ZipArchiveEntry
    {
        internal string fullName;
        internal int method;          // 0 = sin comprimir, 8 = Deflate
        internal uint crc;
        internal long length;
        internal long compressedLength;
        internal string compressed;   // datos comprimidos (vista del archivo leído o propios)
        internal DateTime lastWrite;
        internal int unixMode;        // permisos Unix (0 = sin información)
        internal int flags;

        internal ZipArchiveEntry() { }

        // Ruta dentro del archivo, con '/' ("docs/leeme.txt"; las carpetas terminan en '/').
        public string FullName => fullName;
        // Último componente de la ruta ("leeme.txt").
        public string Name
        {
            get
            {
                int i = fullName.LastIndexOf("/");
                return i < 0 ? fullName : fullName.Substring(i + 1);
            }
        }
        // Tamaño sin comprimir, en bytes.
        public long Length => length;
        // Tamaño comprimido, en bytes.
        public long CompressedLength => compressedLength;
        // CRC-32 de los datos sin comprimir.
        public uint Crc32 => crc;
        // Fecha de modificación (hora local, con resolución de 2 segundos como en el formato zip).
        public DateTime LastWriteTime => lastWrite;
        public bool IsDirectory => fullName.EndsWith("/");
        // true si los datos están comprimidos con Deflate (false: guardados tal cual).
        public bool IsCompressed => method == 8;

        // Contenido descomprimido (bytes). Comprueba el CRC-32: InvalidDataException si no coincide.
        [TrackCaller] public string ReadAllBytes()
        {
            if ((flags & 1) != 0) throw new NotSupportedException("ZipArchive: la entrada '" + fullName + "' está cifrada");
            string data;
            if (method == 0) data = compressed;
            else if (method == 8) data = Zlib.Decompress(compressed, 0, "ZipArchive (" + fullName + ")");
            else throw new NotSupportedException("ZipArchive: método de compresión " + method + " no admitido en '" + fullName + "'");
            if (data.Length != length || std.compression.Crc32.Compute(data) != crc)
                throw new InvalidDataException("ZipArchive: la entrada '" + fullName + "' está dañada (CRC-32 o tamaño incorrectos)");
            return data;
        }

        // Igual que ReadAllBytes (el texto se devuelve tal cual, normalmente UTF-8).
        [TrackCaller] public string ReadAllText() => ReadAllBytes();

        // Extrae la entrada a un archivo (crea las carpetas que falten). Si ya existe, lanza IOException.
        [TrackCaller] public void ExtractToFile(string path) => ExtractToFile(path, false);

        [TrackCaller] public void ExtractToFile(string path, bool overwrite)
        {
            if (!overwrite && File.Exists(path)) throw new IOException("ZipArchive: el archivo '" + path + "' ya existe");
            string dir = Path.GetDirectoryName(path);
            if (dir.Length > 0 && !Directory.Exists(dir)) Directory.Create(dir);
            if (!File.WriteAllText(path, ReadAllBytes())) throw new IOException("ZipArchive: no se puede escribir '" + path + "'");
            long ms = lastWrite.ToUniversalTime().ToUnixMs();
            File.SetLastWriteTime(path, ms);
            if (unixMode != 0 && Environment.CurrentPlatform() != Platform.Windows) File.SetUnixMode(path, unixMode & 0x1FF);
        }

        public override string ToString() => fullName;
    }

    // Archivo .zip en memoria: se lee entero con Open/FromBytes, se modifica con AddEntry /
    // AddFile / Remove y se escribe con Save/ToBytes. No admite cifrado ni ZIP64 (entradas
    // o archivos de más de 4 GiB).
    public class ZipArchive
    {
        List<ZipArchiveEntry> entries = new List<ZipArchiveEntry>();

        // Archivo vacío (para crear uno nuevo).
        public ZipArchive() { }

        // Entradas en el orden del archivo.
        public List<ZipArchiveEntry> Entries => entries;

        // Comentario del archivo ("" si no tiene).
        public string Comment = "";

        // Lee un .zip del disco. FileNotFoundException si no existe; InvalidDataException si no es un zip.
        [TrackCaller] public static ZipArchive Open(string path) => FromBytes(File.ReadAllText(path));

        // Lee un .zip que ya está en memoria.
        [TrackCaller] public static ZipArchive FromBytes(string data)
        {
            ZipArchive z = new ZipArchive();
            z.Parse(data);
            return z;
        }

        // Entrada con ese nombre, o null.
        public ZipArchiveEntry GetEntry(string fullName)
        {
            foreach (var e in entries)
                if (e.fullName == fullName) return e;
            return null;
        }

        // Añade (o sustituye) una entrada con el contenido 'data' comprimido con Deflate.
        public ZipArchiveEntry AddEntry(string fullName, string data) => AddEntry(fullName, data, CompressionLevel.Optimal);

        [TrackCaller] public ZipArchiveEntry AddEntry(string fullName, string data, CompressionLevel level)
        {
            ZipArchiveEntry e = NewEntry(fullName, DateTime.Now);
            e.length = data.Length;
            e.crc = std.compression.Crc32.Compute(data);
            string packed = level == CompressionLevel.NoCompression ? data : Deflate.Compress(data, level);
            if (packed.Length >= data.Length)
            {
                e.method = 0;  // no compensa: se guarda tal cual (como hace zip)
                e.compressed = String.Copy(data);
            }
            else
            {
                e.method = 8;
                e.compressed = packed;
            }
            e.compressedLength = e.compressed.Length;
            Put(e);
            return e;
        }

        // Añade el archivo del disco 'path' con el nombre 'fullName' (conserva la fecha y los permisos).
        [TrackCaller] public ZipArchiveEntry AddFile(string path, string fullName) => AddFile(path, fullName, CompressionLevel.Optimal);

        [TrackCaller] public ZipArchiveEntry AddFile(string path, string fullName, CompressionLevel level)
        {
            ZipArchiveEntry e = AddEntry(fullName, File.ReadAllText(path), level);
            e.lastWrite = DateTime.FromUnixMs(File.GetLastWriteTime(path)).ToLocalTime();
            if (Environment.CurrentPlatform() != Platform.Windows) e.unixMode = File.GetUnixMode(path) & 0x1FF;
            return e;
        }

        // Añade una carpeta vacía ("docs/").
        [TrackCaller] public ZipArchiveEntry AddDirectory(string fullName)
        {
            string name = fullName.EndsWith("/") ? fullName : fullName + "/";
            ZipArchiveEntry e = NewEntry(name, DateTime.Now);
            e.compressed = "";
            e.unixMode = 0x1ED;  // 0755
            Put(e);
            return e;
        }

        // Quita la entrada con ese nombre. Devuelve false si no existía.
        public bool Remove(string fullName)
        {
            for (int i = 0; i < entries.Count; i++)
            {
                if (entries[i].fullName == fullName)
                {
                    entries.RemoveAt(i);
                    return true;
                }
            }
            return false;
        }

        // Extrae todas las entradas en la carpeta 'directory' (la crea si no existe). Rechaza
        // las rutas que saldrían de la carpeta ("../x", "/etc/x") con IOException.
        [TrackCaller] public void ExtractToDirectory(string directory) => ExtractToDirectory(directory, false);

        [TrackCaller] public void ExtractToDirectory(string directory, bool overwrite)
        {
            if (!Directory.Exists(directory)) Directory.Create(directory);
            foreach (var e in entries)
            {
                string target = SafePath(directory, e.fullName);
                if (e.IsDirectory)
                {
                    if (!Directory.Exists(target)) Directory.Create(target);
                }
                else e.ExtractToFile(target, overwrite);
            }
        }

        // Bytes del archivo .zip.
        public string ToBytes()
        {
            StringBuilder sb = new StringBuilder();
            List<long> offsets = new List<long>();
            foreach (var e in entries)
            {
                offsets.Add(sb.Length);
                sb.AppendUInt32LE(0x04034b50);
                sb.AppendUInt16LE(e.method == 8 ? 20 : 10);  // versión necesaria (2.0 / 1.0)
                sb.AppendUInt16LE(0x0800);                    // bit 11: nombres en UTF-8
                sb.AppendUInt16LE(e.method);
                AppendDosTime(sb, e.lastWrite);
                sb.AppendUInt32LE(e.crc);
                sb.AppendUInt32LE((uint)e.compressedLength);
                sb.AppendUInt32LE((uint)e.length);
                sb.AppendUInt16LE(e.fullName.Length);
                sb.AppendUInt16LE(0);
                sb.Append(e.fullName);
                sb.Append(e.compressed);
            }
            long cdStart = sb.Length;
            for (int i = 0; i < entries.Count; i++)
            {
                ZipArchiveEntry e = entries[i];
                sb.AppendUInt32LE(0x02014b50);
                sb.AppendUInt16LE(0x031E);                    // creado en Unix, versión 3.0
                sb.AppendUInt16LE(e.method == 8 ? 20 : 10);
                sb.AppendUInt16LE(0x0800);
                sb.AppendUInt16LE(e.method);
                AppendDosTime(sb, e.lastWrite);
                sb.AppendUInt32LE(e.crc);
                sb.AppendUInt32LE((uint)e.compressedLength);
                sb.AppendUInt32LE((uint)e.length);
                sb.AppendUInt16LE(e.fullName.Length);
                sb.AppendUInt16LE(0);                         // campo extra
                sb.AppendUInt16LE(0);                         // comentario
                sb.AppendUInt16LE(0);                         // disco
                sb.AppendUInt16LE(0);                         // atributos internos
                int mode = e.unixMode != 0 ? e.unixMode : 0x1A4;  // 0644
                uint unixType = e.IsDirectory ? 0x4000u : 0x8000u;
                uint external = (((uint)mode | unixType) << 16) | (e.IsDirectory ? 0x10u : 0u);
                sb.AppendUInt32LE(external);
                sb.AppendUInt32LE((uint)offsets[i]);
                sb.Append(e.fullName);
            }
            long cdSize = sb.Length - cdStart;
            sb.AppendUInt32LE(0x06054b50);
            sb.AppendUInt16LE(0);
            sb.AppendUInt16LE(0);
            sb.AppendUInt16LE(entries.Count);
            sb.AppendUInt16LE(entries.Count);
            sb.AppendUInt32LE((uint)cdSize);
            sb.AppendUInt32LE((uint)cdStart);
            sb.AppendUInt16LE(Comment.Length);
            sb.Append(Comment);
            return sb.ToString();
        }

        // Escribe el archivo .zip en el disco.
        [TrackCaller] public void Save(string path)
        {
            if (!File.WriteAllText(path, ToBytes())) throw new IOException("ZipArchive.Save: no se puede escribir '" + path + "'");
        }

        // ------------------------------------------------------------ privado

        ZipArchiveEntry NewEntry(string fullName, DateTime time)
        {
            if (fullName.Length == 0 || fullName.Length > 0xFFFF) throw new ArgumentException("ZipArchive: nombre de entrada no válido", "fullName");
            if (entries.Count >= 0xFFFF) throw new NotSupportedException("ZipArchive: demasiadas entradas (ZIP64 no admitido)");
            ZipArchiveEntry e = new ZipArchiveEntry();
            e.fullName = Text.Replace(fullName, "\\", "/");
            e.lastWrite = time;
            return e;
        }

        void Put(ZipArchiveEntry e)
        {
            if (e.compressed.Length > 0xFFFFFFFFL || e.length > 0xFFFFFFFFL)
                throw new NotSupportedException("ZipArchive: entrada de más de 4 GiB (ZIP64 no admitido)");
            for (int i = 0; i < entries.Count; i++)
            {
                if (entries[i].fullName == e.fullName)
                {
                    entries[i] = e;
                    return;
                }
            }
            entries.Add(e);
        }

        static string SafePath(string directory, string name)
        {
            string n = Text.Replace(name, "\\", "/");
            if (n.StartsWith("/") || (n.Length > 1 && n[1] == ':')) throw new IOException("ZipArchive: ruta absoluta no permitida: '" + name + "'");
            foreach (var part in Text.Split(n, "/"))
                if (part == "..") throw new IOException("ZipArchive: la entrada '" + name + "' saldría de la carpeta de destino");
            string rel = n.EndsWith("/") ? n.Substring(0, n.Length - 1) : n;
            return Path.Combine(directory, rel);
        }

        static void AppendDosTime(StringBuilder sb, DateTime t)
        {
            int year = t.Year < 1980 ? 1980 : (t.Year > 2107 ? 2107 : t.Year);
            int time = (t.Hour << 11) | (t.Minute << 5) | (t.Second / 2);
            int date = ((year - 1980) << 9) | (t.Month << 5) | t.Day;
            if (t.Year < 1980) date = (0 << 9) | (1 << 5) | 1;
            sb.AppendUInt16LE(time);
            sb.AppendUInt16LE(date);
        }

        static DateTime FromDosTime(int time, int date)
        {
            int year = 1980 + ((date >> 9) & 0x7F), month = (date >> 5) & 0xF, day = date & 0x1F;
            int hour = (time >> 11) & 0x1F, minute = (time >> 5) & 0x3F, second = (time & 0x1F) * 2;
            if (!DateTime.IsValid(year, month, day, hour, minute, second, 0)) return new DateTime(1980, 1, 1);
            return new DateTime(year, month, day, hour, minute, second);
        }

        static int U16(string d, long p) => d[(int)p] | (d[(int)p + 1] << 8);
        static uint U32(string d, long p) => (uint)U16(d, p) | ((uint)U16(d, p + 2) << 16);

        [TrackCaller] void Parse(string d)
        {
            // Fin del directorio central: está al final, antes del comentario (hasta 64 KiB).
            long eocd = -1;
            long stop = d.Length - 22 - 0xFFFF;
            if (stop < 0) stop = 0;
            for (long p = d.Length - 22; p >= stop; p--)
            {
                if (d[(int)p] == 0x50 && U32(d, p) == 0x06054b50)
                {
                    eocd = p;
                    break;
                }
            }
            if (eocd < 0) throw new InvalidDataException("ZipArchive: no es un archivo .zip (falta el directorio central)");
            int count = U16(d, eocd + 10);
            long cdSize = U32(d, eocd + 12);
            long cdOffset = U32(d, eocd + 16);
            int commentLength = U16(d, eocd + 20);
            if (count == 0xFFFF || cdOffset == 0xFFFFFFFFL) throw new NotSupportedException("ZipArchive: formato ZIP64 no admitido");
            if (cdOffset + cdSize > eocd || eocd + 22 + commentLength > d.Length)
                throw new InvalidDataException("ZipArchive: el directorio central está fuera del archivo");
            Comment = d.Substring((int)eocd + 22, commentLength);
            long p = cdOffset;
            for (int i = 0; i < count; i++)
            {
                if (p + 46 > eocd || U32(d, p) != 0x02014b50) throw new InvalidDataException("ZipArchive: directorio central dañado");
                ZipArchiveEntry e = new ZipArchiveEntry();
                int madeBy = U16(d, p + 4);
                e.flags = U16(d, p + 8);
                e.method = U16(d, p + 10);
                e.lastWrite = FromDosTime(U16(d, p + 12), U16(d, p + 14));
                e.crc = U32(d, p + 16);
                e.compressedLength = U32(d, p + 20);
                e.length = U32(d, p + 24);
                int nameLength = U16(d, p + 28), extraLength = U16(d, p + 30), entryComment = U16(d, p + 32);
                uint external = U32(d, p + 38);
                long local = U32(d, p + 42);
                if (p + 46 + nameLength > eocd) throw new InvalidDataException("ZipArchive: directorio central dañado");
                e.fullName = d.Substring((int)p + 46, nameLength);
                if ((madeBy >> 8) == 3) e.unixMode = (int)((external >> 16) & 0x1FF);
                if (e.compressedLength == 0xFFFFFFFFL || e.length == 0xFFFFFFFFL || local == 0xFFFFFFFFL)
                    throw new NotSupportedException("ZipArchive: formato ZIP64 no admitido ('" + e.fullName + "')");
                // Los datos empiezan tras la cabecera local (su campo extra puede diferir del central).
                if (local + 30 > d.Length || U32(d, local) != 0x04034b50) throw new InvalidDataException("ZipArchive: cabecera local dañada en '" + e.fullName + "'");
                long start = local + 30 + U16(d, local + 26) + U16(d, local + 28);
                if (start + e.compressedLength > d.Length) throw new InvalidDataException("ZipArchive: la entrada '" + e.fullName + "' está truncada");
                e.compressed = d.Substring((int)start, (int)e.compressedLength);
                entries.Add(e);
                p += 46 + nameLength + extraLength + entryComment;
            }
        }
    }

    // Atajos para trabajar con carpetas (como System.IO.Compression.ZipFile).
    public static class ZipFile
    {
        [TrackCaller] public static ZipArchive Open(string path) => ZipArchive.Open(path);

        // Crea 'zipPath' con todo el contenido de la carpeta 'sourceDirectory' (rutas relativas a ella).
        [TrackCaller] public static void CreateFromDirectory(string sourceDirectory, string zipPath)
        {
            ZipArchive z = new ZipArchive();
            string root = Path.GetFullPath(sourceDirectory);
            foreach (var dir in Directory.GetDirectories(root, "*", true))
            {
                string rel = Relative(root, dir);
                if (Directory.GetFileSystemEntries(dir, "*", false).Count == 0) z.AddDirectory(rel);
            }
            foreach (var file in Directory.GetFiles(root, "*", true)) z.AddFile(file, Relative(root, file));
            z.Save(zipPath);
        }

        [TrackCaller] public static void ExtractToDirectory(string zipPath, string destinationDirectory) =>
            ZipArchive.Open(zipPath).ExtractToDirectory(destinationDirectory, false);

        [TrackCaller] public static void ExtractToDirectory(string zipPath, string destinationDirectory, bool overwrite) =>
            ZipArchive.Open(zipPath).ExtractToDirectory(destinationDirectory, overwrite);

        static string Relative(string root, string path)
        {
            string r = path.Substring(root.Length);
            while (r.StartsWith("/") || r.StartsWith("\\")) r = r.Substring(1);
            return Text.Replace(r, "\\", "/");
        }
    }
}
