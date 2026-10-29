using std::collections;
using MiJuego::Motor;
using Utilidades;

namespace MiJuego
{
    public static class Program
    {
        public static void Main()
        {
            Console::WriteLine(Saludo::Texto());
            auto heroe = new Entidad("Héroe", 1, 2);
            heroe.Mover(new std::math::Vec2(2, 3));
            Console::Write(heroe.Nombre); Console::Write(" en "); Console::Write(heroe.Posicion.X);
            Console::Write(", "); Console::WriteLine(heroe.Posicion.Y);
            delete heroe;
        }
    }
}
