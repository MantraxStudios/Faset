using Motor.Fisica;

namespace App
{
    public static class Program
    {
        public static void Main()
        {
            auto mundo = new Mundo();
            mundo.Avanzar();
            Console.WriteLine(mundo.Avanzar());
            Console.WriteLine(mundo.Pasos.Valor);
            auto caja = new Base::Caja<string>("caja de Base");   // tipo de una dependencia indirecta
            Console.WriteLine(caja.Valor);
            Console.WriteLine(Base.Contador.Siguiente());
            delete caja;
            delete mundo;
        }
    }
}
