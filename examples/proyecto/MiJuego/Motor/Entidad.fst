using std.math;

namespace MiJuego.Motor
{
    public class Entidad
    {
    public:
        string Nombre;
        Vec2 Posicion;
        Entidad(string nombre, double x, double y) { Nombre = nombre; Posicion = new Vec2(x, y); }
        void Mover(Vec2 delta) { Posicion = Posicion + delta; }
    }
}
