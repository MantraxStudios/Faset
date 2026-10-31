using std::collections;
using MiJuego::Motor;
using Utilidades;

namespace MiJuego
{
    public static class Program
    {
        public static func Main()
        {
            Console::WriteLine(Saludo::Texto());
            var heroe = new Entidad("Héroe", 1, 2);
            heroe.Mover(new std::math::Vec2(2, 3));
            Console::Write(heroe.Nombre); Console::Write(" en "); Console::Write(heroe.Posicion.X);
            Console::Write(", "); Console::WriteLine(heroe.Posicion.Y);
            
            if (heroe != null)
            {
                delete heroe;
                Console.Write("Se limpio la memoria");
            }
        }
    }
}
