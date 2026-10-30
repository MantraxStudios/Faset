// std.text: Base64 y Hex (vectores de RFC 4648), Encoding (UTF-8, Latin-1, ASCII, UTF-16),
// CSV con comillas y las mejoras de StringBuilder.
using std.collections;
using std.text;

void main()
{
    // ---- Base64 (RFC 4648, sección 10)
    var vectores = Text.Split("|f|fo|foo|foob|fooba|foobar", "|");
    foreach (var v in vectores) println($"\"{v}\" -> \"{Base64.Encode(v)}\" -> \"{Base64.Decode(Base64.Encode(v))}\"");
    println(Base64.EncodeUrl("ûÿ"));            // bytes C3 BB C3 BF
    println(Base64.Decode("aG9s\nYQ==") == "hola");
    println(Base64.Decode("aG9sYQ") == "hola");           // sin relleno
    string basura;
    println(Base64.TryDecode("a$b=", out basura));
    println(Base64.TryDecode("aGk=x", out basura));
    try { Base64.Decode("A"); } catch (FormatException e) { println(e.Message); }

    // ---- Hex
    println(Hex.Encode("\u0001ab"));
    println(Hex.EncodeUpper("ñ"));
    println(Hex.Decode("68656C6c6f"));
    try { Hex.Decode("abc"); } catch (FormatException e) { println(e.Message); }

    // ---- Encoding
    string latin1 = Encoding.Latin1.GetBytes("año €");
    println(Hex.Encode(latin1));                          // 61 f1 6f 20 3f ('€' no existe en Latin-1)
    println(Encoding.Latin1.GetString(latin1));
    println(Hex.Encode(Encoding.ASCII.GetBytes("año")));
    string u16 = Encoding.Unicode.GetBytes("hé😀");
    println(Hex.Encode(u16));
    println(Encoding.Unicode.GetString(u16));
    println(Hex.Encode(Encoding.BigEndianUnicode.GetBytes("hé")));
    println(Encoding.BigEndianUnicode.GetString(Encoding.BigEndianUnicode.GetBytes("¡Hola!")));
    println(Encoding.UTF8.GetString("aÿb").Length);  // UTF-8 válido: igual
    StringBuilder malo = new StringBuilder();
    malo.Append("x").AppendByte(0xFF).Append("y");
    println(Encoding.UTF8.GetString(malo.ToString()));    // byte suelto -> U+FFFD
    println(Encoding.GetEncoding("UTF-16").WebName());
    println(Encoding.GetEncoding("latin1").WebName());
    println(Hex.Encode(Encoding.Unicode.GetPreamble()) + " " + Hex.Encode(Encoding.UTF8.GetPreamble()));
    string conBom = Encoding.Unicode.GetPreamble() + Encoding.Unicode.GetBytes("BOM");
    println(Encoding.DecodeWithBom(conBom));
    try { Encoding.GetEncoding("ebcdic"); } catch (ArgumentException e) { println(e.Message); }

    // ---- CSV
    string csv = "nombre,ciudad,nota\r\n\"Pérez, Ana\",Madrid,9.5\n\"Dice \"\"hola\"\"\",\"Línea 1\nLínea 2\",\n,,\n";
    var filas = Csv.Parse(csv);
    println(filas.Count);
    foreach (var f in filas) println(Text.Join(f, " | ") + $" ({f.Count})");
    string escrito = Csv.Write(filas);
    println(Text.Replace(escrito, "\r\n", "⏎"));
    var otra = Csv.Parse(escrito);
    println(otra.Count == filas.Count && otra[2][0] == filas[2][0] && otra[2][1] == filas[2][1]);
    var dicts = Csv.ParseWithHeader("a;b\n1;2\n3;4\n", ';');
    println(dicts[1]["b"]);
    var w = new CsvWriter(';');
    w.NewLine = "\n";
    w.WriteRow("x", "1;2", " espacio");
    print(w.ToString());
    var r = new CsvReader("uno,dos\ntres");
    while (r.Read()) println($"{r.Fields.Count}: {r.Fields[0]}");
    try { Csv.Parse("a,\"sin cerrar\nb"); } catch (FormatException e) { println(e.Message); }
    try { Csv.Parse("a,\"b\"c\n"); } catch (FormatException e) { println(e.Message); }

    // ---- StringBuilder
    var sb = new StringBuilder();
    sb.Append("mundo").Insert(0, "hola ").Replace("o", "0");
    println(sb.ToString());
    sb.Remove(0, 5);
    println(sb.ToString() + " " + sb.Length + " " + (char)sb[0]);
    var bin = new StringBuilder();
    bin.AppendUInt16LE(0x0102).AppendUInt32LE(0xA0B0C0D0).AppendUInt64LE(1);
    println(Hex.Encode(bin.ToString()));
}
