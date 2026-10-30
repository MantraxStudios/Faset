// Errores de parámetros opcionales, argumentos con nombre, inicializadores, init, required y out var.
enum Color { Rojo }
int k = 3;
void F(int x = 0, string s = "a") { }
void G(int a = 1, int b) { }
void H(int x = k) { }
void I(ref int x = 0) { }
void J([CallerLineNumber] string s = "") { }
void K([CallerMemberName] string s) { }
void L(Color c = 5) { }
delegate void D(int x = 3);

class Persona
{
    public required string Nombre;
    public string Apodo { get; init; } = "";
    public required int Edad { get; set; }
    public void Cambiar() { Apodo = "x"; }
}

class Sin
{
    public int A;
}

void main()
{
    F(y: 3);
    F(s: "b", 1);
    F(1, x: 2);
    F(1, "a", 3);
    Action<int> ac = x => { };
    ac(x: 1);
    var p = new Persona { Nombre = "Ana" };
    var p2 = new Persona { Nombre = "Ana", Edad = 1, Apodo = "a" };
    p2.Apodo = "b";
    var s = new Sin { B = 3 };
    var s2 = new Sin { A = 1, A = 2 };
    var s3 = new Sin { 1, 2 };
    int n = new int { };
}

void Dos(out int a) { a = 1; }
void Dos(out string a) { a = ""; }
void Usa()
{
    Dos(out var x);
}
