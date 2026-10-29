// =============================================================================
//  Logotipo de Faset: la "F" angular, vectorizada a partir de fassetlogo.png.
//  Tres polígonos convexos en coordenadas normalizadas (0..1) que se rasterizan
//  con supermuestreo 4x4 para obtener bordes suaves a cualquier tamaño.
// =============================================================================
namespace FasetStudio.Gfx
{
    public static class LogoShape
    {
        // Puntos del original (imagen de 1254 px); la caja del logotipo mide 462 x 462.
        const float OriginX = 425.5f;  // centra horizontalmente los 437 px de ancho
        const float OriginY = 408;
        const float Box = 462;

        static float* points;   // x, y normalizados
        static int* starts;     // inicio de cada polígono
        static int* counts;     // número de puntos de cada polígono
        const int Polygons = 3;

        static void Add(float* p, ref int n, float x, float y)
        {
            p[n * 2] = (x - OriginX) / Box;
            p[n * 2 + 1] = (y - OriginY) / Box;
            n++;
        }

        static void Init()
        {
            if (points != null) return;
            points = new float[64];
            starts = new int[Polygons];
            counts = new int[Polygons];
            int n = 0;
            // Columna con el bisel superior y la punta inferior
            starts[0] = n;
            Add(points, ref n, 438, 448);
            Add(points, ref n, 475, 408);
            Add(points, ref n, 523, 408);
            Add(points, ref n, 523, 790);
            Add(points, ref n, 438, 870);
            counts[0] = n - starts[0];
            // Barra superior
            starts[1] = n;
            Add(points, ref n, 523, 408);
            Add(points, ref n, 875, 408);
            Add(points, ref n, 792, 490);
            Add(points, ref n, 523, 490);
            counts[1] = n - starts[1];
            // Barra central
            starts[2] = n;
            Add(points, ref n, 523, 573);
            Add(points, ref n, 773, 573);
            Add(points, ref n, 690, 655);
            Add(points, ref n, 523, 655);
            counts[2] = n - starts[2];
        }

        // ¿El punto (x, y) en [0,1] está dentro del logotipo?
        public static bool Inside(float x, float y)
        {
            Init();
            for (int poly = 0; poly < Polygons; poly++)
            {
                bool inside = true;
                int s = starts[poly], c = counts[poly];
                for (int i = 0; i < c && inside; i++)
                {
                    float ax = points[(s + i) * 2], ay = points[(s + i) * 2 + 1];
                    float bx = points[(s + (i + 1) % c) * 2], by = points[(s + (i + 1) % c) * 2 + 1];
                    // Polígonos en sentido horario (y hacia abajo): el interior queda a la derecha.
                    if ((bx - ax) * (y - ay) - (by - ay) * (x - ax) < 0) inside = false;
                }
                if (inside) return true;
            }
            return false;
        }

        // Cobertura (0..255) del logotipo para un píxel de una imagen de 'size' x 'size'.
        public static byte Coverage(int px, int py, int size)
        {
            int hits = 0;
            for (int sy = 0; sy < 4; sy++)
                for (int sx = 0; sx < 4; sx++)
                {
                    float x = (px + (sx + 0.5f) / 4) / size;
                    float y = (py + (sy + 0.5f) / 4) / size;
                    if (Inside(x, y)) hits++;
                }
            return (byte)(hits * 255 / 16);
        }
    }
}
