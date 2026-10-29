// Cadenas interpoladas: huecos, alineación, formatos, escapes y cadenas literales (@"...").
enum Color { Rojo, Verde }

struct Punto
{
    public int X;
    public int Y;
    public Punto(int x, int y) { X = x; Y = y; }
    public string ToString() => $"({X}; {Y})";
}

class Persona
{
    public string Nombre;
    public Persona(string n) { Nombre = n; }
    public string ToString() => "Persona " + Nombre;
}

void main()
{
    string nombre = "Ana";
    int edad = 30;
    println($"Hola {nombre}, tienes {edad} años");
    println($"{edad + 1} el año que viene; mitad: {edad / 2.0}");
    println($"bool {edad > 18}, char {'ñ'}, enum {Color.Verde}, long {1L << 40}");
    println($"sin huecos");
    println($"");
    println($"{{literal}} y }} y {{");

    // Alineación (en caracteres) y formatos numéricos
    println($"[{nombre,6}] [{nombre,-6}] [{"ñandú",7}] [{edad,3}]");
    double precio = 1234.5678;
    println($"{precio:F2} {precio:F0} {precio:N2} {precio:E3} {precio:e2}");
    println($"{0.256:P1} {precio:0.0} {precio:#,##0.00} {0.5:#.##} {7:000}");
    println($"{42:D5} {-42:D5} {255:X} {255:x4} {-1:X} {1234567:N0} {1234567:N}");
    println($"{precio,12:F3}|{edad,-5:D3}|");
    println($"{3.0:G} {1.0 / 3:G3} {-0.0001:F2}");
    byte b = 200;
    ulong grande = 18446744073709551615UL;
    println($"{b:X2} {grande} {grande:N0}");

    // Expresiones con llamadas, ternarios entre paréntesis y cadenas anidadas
    println($"{nombre.ToUpper()} tiene {nombre.Length} letras; {(edad > 20 ? "adulta" : "joven")}");
    println($"{"anidada"} {$"{edad}{edad}"}");

    // ToString() del usuario (struct y clase)
    Punto p = new Punto(3, 4);
    Persona ana = new Persona("Ana");
    println($"punto {p}, {ana}");
    println("concatenado: " + p + " / " + ana);
    string s = "acumulado ";
    s += p;
    println(s);

    // Cadenas literales y literales interpolados con @
    println(@"C:\ruta\sin\escapes");
    println(@"comillas ""dobles""");
    string carpeta = "datos";
    println($@"C:\{carpeta}\archivo.txt");
    println(@$"D:\{carpeta}\{edad}");
    println($"tab\tsalto\\n {nombre}");
}
