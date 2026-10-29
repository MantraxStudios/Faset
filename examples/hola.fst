// Ejemplo mínimo. Ejecuta:  faset run examples/hola.fst
// 'std' se importa siempre: print/println, Console, Math, String...

void main()
{
    println("¡Hola, mundo desde Faset!");

    int a = 7, b = 3;
    Console::Write("a + b = "); Console::WriteLine(a + b);   // estilo C++ (::)
    Console.Write("a / b = "); Console.WriteLine(a / b);     // estilo C# (.)
    println(7.0 / 2);
    println(Math::Sqrt(2));
    println(int.MaxValue);
    println('ñ');
    println(a > b);
}
