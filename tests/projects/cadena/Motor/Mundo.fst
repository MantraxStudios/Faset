using Base;

namespace Motor.Fisica
{
    public class Mundo
    {
        public Caja<int> Pasos = new Caja<int>(0);

        public int Avanzar()
        {
            Pasos.Valor++;
            return Contador.Siguiente();
        }
    }
}
