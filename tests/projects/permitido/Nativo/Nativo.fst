// Sin anotaciones: el proyecto tiene <AllowUnsafe>true</AllowUnsafe>.
namespace Nativo
{
    public static class Bloque
    {
        // API segura (sin punteros en la firma) con implementación insegura.
        public static int SumaHasta(int n)
        {
            int* datos = new int[n];
            for (int i = 0; i < n; i++) *(datos + i) = i + 1;
            int s = 0;
            for (int i = 0; i < n; i++) s += datos[i];
            delete[] datos;
            return s;
        }
    }
}
