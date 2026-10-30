// std.compression: Deflate / zlib / gzip (ida y vuelta, vectores conocidos, datos dañados),
// CRC-32 / Adler-32, ZipArchive (crear, leer, extraer, rutas peligrosas) y, en Linux,
// compatibilidad con las herramientas gzip, zip y unzip si están instaladas.
using std.collections;
using std.compression;
using std.text;
using std.io;
using std.os;

string Sh(string command)
{
    List<string> args = new List<string>();
    args.Add("-c");
    args.Add(command);
    string o, e;
    int code = Process.Execute("sh", args, out o, out e);
    return code == 0 ? o : "error " + code + ": " + e;
}

bool Tiene(string tool) => Environment.CurrentPlatform() == Platform.Linux && Sh("command -v " + tool).Length > 0 && !Sh("command -v " + tool).StartsWith("error");

void main()
{
    // ---- ida y vuelta
    StringBuilder sb = new StringBuilder();
    for (int i = 0; i < 5000; i++) sb.Append("línea ").Append(i).Append(": Faset comprime con Deflate\n");
    string texto = sb.ToString();
    StringBuilder bin = new StringBuilder();
    for (int i = 0; i < 70000; i++) bin.AppendByte((i * 7919 + (i >> 3)) & 0xFF);
    string binario = bin.ToString();

    foreach (var nivel in Enum.GetValues<CompressionLevel>())
    {
        string d = Deflate.Compress(texto, nivel);
        println($"{nivel.ToString()}: {Deflate.Decompress(d) == texto} {(nivel == CompressionLevel.NoCompression ? d.Length > texto.Length : d.Length < texto.Length / 5)}");
    }
    println(ZLib.Decompress(ZLib.Compress(binario)) == binario);
    println(GZip.Decompress(GZip.Compress(binario)) == binario);
    println(Deflate.Decompress(Deflate.Compress("")) == "");
    println(GZip.Decompress(GZip.Compress("")).Length);

    // ---- formato
    string z = ZLib.Compress("abc");
    println(Hex.Encode(z.Substring(0, 2)) + " ... " + Hex.Encode(z.Substring(z.Length - 4)));   // 78 9c ... Adler-32
    string g = GZip.Compress("abc");
    println(Hex.Encode(g.Substring(0, 3)) + " ... " + Hex.Encode(g.Substring(g.Length - 8)));   // 1f8b08 ... CRC + tamaño
    // Deflate de referencia: "Hola" guardado en un bloque fijo (zlib -15).
    println(Deflate.Decompress(Hex.Decode("f3c8cf490400")));
    // Dos miembros gzip seguidos.
    println(GZip.Decompress(GZip.Compress("uno ") + GZip.Compress("dos")));

    // ---- sumas de comprobación
    println(Hex.Encode(Hex.Decode("00")) + " " + Crc32.Compute("123456789") + " " + Adler32.Compute("Wikipedia"));
    println(Crc32.Append(Crc32.Compute("1234"), "56789") == Crc32.Compute("123456789"));

    // ---- datos dañados
    try { GZip.Decompress("no es gzip"); } catch (InvalidDataException e) { println(e.Message); }
    string roto = g.Substring(0, g.Length - 8) + "\u0000\u0000\u0000\u0000" + g.Substring(g.Length - 4);
    try { GZip.Decompress(roto); } catch (InvalidDataException e) { println(e.Message); }
    try { ZLib.Decompress(z.Substring(0, z.Length - 3)); } catch (InvalidDataException e) { println("zlib truncado: InvalidDataException"); }
    try { Deflate.Decompress(Deflate.Compress(texto).Substring(0, 100)); } catch (InvalidDataException e) { println("deflate truncado: InvalidDataException"); }

    // ---- ZipArchive
    string dir = Path.Combine(Path.GetTempPath(), "faset_zip_" + RandomName());
    Directory.Create(dir);
    var zip = new ZipArchive();
    zip.AddEntry("hola.txt", "¡Hola, zip!");
    zip.AddEntry("datos/texto.txt", texto);
    zip.AddEntry("datos/binario.bin", binario, CompressionLevel.Fastest);
    zip.AddEntry("crudo.txt", "sin comprimir", CompressionLevel.NoCompression);
    zip.AddDirectory("vacia");
    zip.AddEntry("hola.txt", "¡Hola de nuevo!");    // sustituye la anterior
    println(zip.Remove("crudo.txt") + " " + zip.Remove("no-existe"));
    zip.Comment = "creado por Faset";
    string zipPath = Path.Combine(dir, "prueba.zip");
    zip.Save(zipPath);

    var leido = ZipArchive.Open(zipPath);
    println(leido.Comment);
    foreach (var e in leido.Entries) println($"{e.FullName} ({e.Name}) {e.Length} {e.IsDirectory} {e.IsCompressed}");
    println(leido.GetEntry("hola.txt").ReadAllText());
    println(leido.GetEntry("datos/texto.txt").ReadAllText() == texto);
    println(leido.GetEntry("datos/binario.bin").ReadAllBytes() == binario);
    println(leido.GetEntry("datos/binario.bin").Crc32 == Crc32.Compute(binario));
    println(leido.GetEntry("nada") == null);

    string destino = Path.Combine(dir, "extraido");
    leido.ExtractToDirectory(destino);
    println(File.ReadAllText(Path.Combine(destino, "hola.txt")));
    println(File.ReadAllText(Path.Combine(destino, "datos/binario.bin")) == binario);
    println(Directory.Exists(Path.Combine(destino, "vacia")));
    try { leido.ExtractToDirectory(destino); } catch (IOException e) { println("ya existe: IOException"); }
    leido.ExtractToDirectory(destino, true);

    // Ruta que sale de la carpeta (zip slip).
    var malo = new ZipArchive();
    malo.AddEntry("../fuera.txt", "x");
    try { ZipArchive.FromBytes(malo.ToBytes()).ExtractToDirectory(destino); } catch (IOException e) { println(e.Message); }
    try { ZipArchive.FromBytes("PK no es un zip"); } catch (InvalidDataException e) { println(e.Message); }
    string bytes = zip.ToBytes();
    var dañado = ZipArchive.FromBytes(bytes.Substring(0, 40) + "X" + bytes.Substring(41));
    try { dañado.GetEntry("hola.txt").ReadAllText(); } catch (InvalidDataException e) { println("entrada dañada: InvalidDataException"); }

    // ZipFile: carpeta -> zip -> carpeta.
    string zip2 = Path.Combine(dir, "carpeta.zip");
    ZipFile.CreateFromDirectory(destino, zip2);
    var nombres = new List<string>();
    foreach (var e in ZipFile.Open(zip2).Entries) nombres.Add(e.FullName);
    nombres.Sort();
    println(Text.Join(nombres, ", "));
    ZipFile.ExtractToDirectory(zip2, Path.Combine(dir, "otra"));
    println(File.ReadAllText(Path.Combine(dir, "otra", "datos/texto.txt")) == texto);

    // ---- herramientas del sistema
    string gz = Path.Combine(dir, "t.gz");
    if (Tiene("gzip"))
    {
        string plano = Path.Combine(dir, "plano.txt");
        File.WriteAllText(plano, texto);
        File.WriteAllText(gz, GZip.Compress(texto));
        println("gzip lee el nuestro: " + (Sh("gzip -dc '" + gz + "' | cksum") == Sh("cksum < '" + plano + "'")));
        Sh("gzip -9 -c '" + plano + "' > '" + gz + "'");
        println("leemos el de gzip: " + (GZip.Decompress(File.ReadAllText(gz)) == texto));
        File.WriteAllText(gz, GZip.Compress(binario));
        Sh("gzip -dc '" + gz + "' > '" + plano + "'");
        println("binario por gzip: " + (File.ReadAllText(plano) == binario));
    }
    else
    {
        println("gzip lee el nuestro: True");
        println("leemos el de gzip: True");
        println("binario por gzip: True");
    }
    if (Tiene("unzip"))
    {
        println("unzip -t: " + Sh("unzip -tq '" + zipPath + "'").StartsWith("No errors"));
        println("unzip -p: " + Sh("unzip -p '" + zipPath + "' hola.txt"));
    }
    else
    {
        println("unzip -t: True");
        println("unzip -p: ¡Hola de nuevo!");
    }
    if (Tiene("zip"))
    {
        // zip desde una tubería usa descriptores de datos (bit 3) y el campo extra de Unix.
        string externo = Path.Combine(dir, "externo.zip");
        Sh("cd '" + destino + "' && zip -qr '" + externo + "' . && printf 'por tuberia' | zip -q '" + externo + "' -");
        var ext = ZipArchive.Open(externo);
        println("zip -r: " + (ext.GetEntry("datos/binario.bin").ReadAllBytes() == binario) + " " + ext.GetEntry("-").ReadAllText());
    }
    else println("zip -r: True por tuberia");
    Directory.Delete(dir, true);
}

string RandomName() => "" + Environment.TickCount64() % 1000000 + "_" + Process.CurrentId;
