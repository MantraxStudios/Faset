using std.math;

namespace MiJuego.Motor
{
    public class Entidad
    {
    public:
        var Nombre: string;
        var Posicion: Vec2;
        init(nombre: string, x: double, y: double) { Nombre = nombre; Posicion = new Vec2(x, y); }
        func Mover(delta: Vec2) { Posicion = Posicion + delta; }
    }
}
