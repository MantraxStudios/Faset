// Una conversión de un objeto a un tipo que no es el suyo termina con 'panic'.
class Animal { }
class Perro : Animal { }
class Gato : Animal { }

void Main()
{
    Animal a = new Animal();
    Animal p = new Perro();
    Perro bien = (Perro)p;
    Console.WriteLine(bien is Perro);
    Gato g = (Gato)a;
    Console.WriteLine("no se llega aquí");
}
