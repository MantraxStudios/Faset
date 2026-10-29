namespace Utilidades
{
    // Biblioteca de la solución MiJuego: la usa Juego mediante <ProjectReference>.
    public static class Saludo
    {
        public static string Texto() => "Hola desde la biblioteca Utilidades";
    }

    public static class Puntos
    {
        public static int Doble(int n) => n * 2;
    }
}
