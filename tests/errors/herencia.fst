// Errores de herencia, virtual/override/abstract/sealed y constructores (ver herencia.expected).
class Animal
{
    public virtual void Hablar() { }
    public void Comer() { }
    public abstract void Dormir();                             // 6: abstracto en clase no abstracta
}

abstract class Forma
{
    public abstract double Area();
    public abstract double Perimetro() { return 0; }           // 12: abstracto con cuerpo
}

class Circulo : Forma                                          // 15: no implementa Area
{
    public override double Perimetro() => 1;
}

class Perro : Animal
{
    public override void Comer() { }                           // 22: override de un método no virtual
    public override int Hablar() { return 1; }                 // 23: tipo de retorno distinto
    public void Hablar(int veces) { }                          // sobrecarga: correcto
    public override void Correr() { }                          // 25: nada que reemplazar
    public override void Dormir(int horas) { }                 // 26: la firma no coincide
}

class Gato : Animal
{
    public void Hablar() { }                                   // 31: oculta un virtual sin override/new
}

class Raton : Animal
{
    public new void Hablar() { }                               // 'new': ocultar es correcto
    private virtual void Esconderse() { }                      // 37: virtual privado
    public static virtual void Contar() { }                    // 38: estático virtual
    public virtual override void Dormir() { }                  // 39: virtual + override
}

sealed class Final { }
class Hijo : Final { }                                         // 43: deriva de una clase sealed
class Doble : Animal, Final { }                                // 44: dos clases base
struct S : Animal { }                                          // 45: un struct no hereda de clases
class A : B { }
class B : A { }                                                // 47: herencia circular
class C : int { }                                              // 48: no es una clase

class Base2
{
    public Base2(int x) { }
}
class Der2 : Base2 { }                                         // 54: base sin constructor sin parámetros
class Der3 : Base2
{
    public Der3() { }                                          // 57: idem en el constructor
}
class Der4 : Base2
{
    public Der4() : base("x") { }                              // 61: argumentos que no encajan
}

class Sellado : Animal
{
    public sealed override void Hablar() { }
}
class SubSellado : Sellado
{
    public override void Hablar() { }                          // 70: reemplaza un miembro sealed
}

class Solo
{
    public Solo() : base() { }                                 // correcto: base de object
    public sealed void Nada() { }                              // 76: sealed sin override
}

abstract class Vehiculo
{
    public abstract int Ruedas { get; }
    public void Arrancar() { base.Arrancar(); }                // 82: object no tiene Arrancar
}
class Moto : Vehiculo
{
    public override int Ruedas => base.Ruedas;                 // 86: base abstracto
}

void Main()
{
    Forma f = new Forma();                                     // 91: clase abstracta
    Animal a = new Animal();
    Perro p = a;                                               // 93: conversión implícita a derivada
    bool b = a is Circulo;                                     // 94: nunca puede ser
    int n = 5;
    bool b2 = n is Animal;                                     // 96: no es una referencia
    Circulo c = a as Circulo;                                  // 97: tipos no relacionados
    Circulo d = (Circulo)a;                                    // 98: reinterpretación (memory_unsafe)
    base.Hablar();                                             // 99: 'base' en contexto estático
}
