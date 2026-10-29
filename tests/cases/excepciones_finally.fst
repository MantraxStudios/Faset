// 'finally' siempre se ejecuta: al terminar normalmente, con una excepción y al salir con
// return, break o continue (también atravesando varios 'try' anidados), en el orden correcto.
using std.collections;

List<string> traza = new List<string>();
void T(string s) { traza.Add(s); }
void Volcar()
{
    string s = "";
    for (int i = 0; i < traza.Count; i++) s = s + (i > 0 ? " " : "") + traza[i];
    println(s);
    traza.Clear();
}

int RetornoEnTry()
{
    try { T("try"); return 1; }
    finally { T("finally"); }
}

// El valor de 'return' se calcula antes del finally (que no lo cambia).
int RetornoCalculado()
{
    int x = 10;
    try { return x * 2; }
    finally { x = 99; T("x=" + x); }
}

string RetornoAnidado(int caso)
{
    try
    {
        try
        {
            try
            {
                T("t3");
                if (caso == 0) return "cero";
                if (caso == 1) throw new FormatException("uno");
            }
            finally { T("f3"); }
            T("después-f3");
        }
        catch (FormatException e) { T("catch:" + e.Message); return "atrapada"; }
        finally { T("f2"); }
        T("después-f2");
        return "normal";
    }
    finally { T("f1"); }
}

// Excepción dentro del catch: el finally del mismo try se ejecuta igual.
void ExcepcionEnCatch()
{
    try
    {
        try { throw new FormatException("primera"); }
        catch (FormatException e) { T("catch"); throw new InvalidOperationException("segunda"); }
        finally { T("finally"); }
    }
    catch (InvalidOperationException e) { T("fuera:" + e.Message); }
}

// Una excepción en el finally sustituye a la que estaba en curso (como en C#).
void ExcepcionEnFinally()
{
    try
    {
        try { throw new FormatException("original"); }
        finally { T("finally"); throw new TimeoutException("del finally"); }
    }
    catch (Exception e) { T(e.TypeName); }
}

void Bucles()
{
    for (int i = 0; i < 6; i++)
    {
        try
        {
            if (i == 1) continue;
            if (i == 4) break;
            T("i" + i);
        }
        finally { T("f" + i); }
    }
    // break/continue que atraviesan dos finally y un catch.
    int j = 0;
    while (true)
    {
        j++;
        try
        {
            try
            {
                try
                {
                    if (j == 2) continue;
                    if (j == 3) break;
                    T("j" + j);
                }
                catch (Exception e) { T("nunca"); }
            }
            finally { T("a" + j); }
        }
        finally { T("b" + j); }
    }
    T("fin-j" + j);
    // break dentro de un bucle interior: no sale del 'try'.
    try
    {
        for (int k = 0; k < 10; k++)
        {
            if (k == 2) break;
            T("k" + k);
        }
        T("tras-k");
    }
    finally { T("fk"); }
    // switch dentro del try: su break no atraviesa el finally.
    for (int m = 0; m < 3; m++)
    {
        try
        {
            switch (m)
            {
                case 0: T("s0"); break;
                case 1: T("s1"); continue;
                default: T("s2"); break;
            }
            T("tras-switch" + m);
        }
        finally { T("fs" + m); }
    }
}

// Bucle de bucles: break del interior con try en ambos niveles.
void Anidados()
{
    for (int i = 0; i < 2; i++)
    {
        try
        {
            for (int k = 0; k < 3; k++)
            {
                try
                {
                    if (k == 1) break;
                    T(i + "." + k);
                }
                finally { T("fin" + i + "." + k); }
            }
        }
        finally { T("fin" + i); }
    }
}

// return void que atraviesa catch y finally.
void RetornoVoid(bool salir)
{
    try
    {
        try
        {
            if (salir) return;
            T("sigue");
        }
        catch (Exception e) { T("nunca"); }
    }
    finally { T("finally-void"); }
    T("al-final");
}

// Valor de retorno con struct y string.
struct Par { public int A; public int B; }
Par DevolverPar()
{
    Par p = new Par();
    p.A = 1;
    try { p.B = 2; return p; }
    finally { T("par"); }
}
string DevolverCadena(int n)
{
    try { if (n > 0) return "positivo"; throw new ArgumentException("negativo"); }
    catch (ArgumentException e) { return "error: " + e.Message; }
    finally { T("cadena" + n); }
}

void main()
{
    println(RetornoEnTry());
    Volcar();
    println(RetornoCalculado());
    Volcar();
    println(RetornoAnidado(0));
    Volcar();
    println(RetornoAnidado(1));
    Volcar();
    println(RetornoAnidado(2));
    Volcar();
    ExcepcionEnCatch();
    Volcar();
    ExcepcionEnFinally();
    Volcar();
    Bucles();
    Volcar();
    Anidados();
    Volcar();
    RetornoVoid(true);
    RetornoVoid(false);
    Volcar();
    Par p = DevolverPar();
    println(p.A + p.B);
    println(DevolverCadena(1));
    println(DevolverCadena(-1));
    Volcar();
    // finally sin catch con una excepción: corre y la excepción sigue hacia fuera.
    try
    {
        try { T("dentro"); throw new FormatException("sigue"); }
        finally { T("finally-solo"); }
    }
    catch (FormatException e) { T("fuera:" + e.Message); }
    Volcar();
}
