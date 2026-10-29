// N-body (Benchmarks Game): 5 cuerpos, 2 000 000 pasos. Coma flotante y structs.
struct Body
{
    public double X, Y, Z, Vx, Vy, Vz, Mass;
    public Body(double x, double y, double z, double vx, double vy, double vz, double mass)
    {
        X = x; Y = y; Z = z; Vx = vx; Vy = vy; Vz = vz; Mass = mass;
    }
}

memory_unsafe static class Program   // punteros crudos, como en C
{
    const double SolarMass = 4.0 * Math.PI * Math.PI;
    const double DaysPerYear = 365.24;

    static void Advance(Body* b, int n, double dt)
    {
        for (int i = 0; i < n; i++)
        {
            for (int j = i + 1; j < n; j++)
            {
                double dx = b[i].X - b[j].X;
                double dy = b[i].Y - b[j].Y;
                double dz = b[i].Z - b[j].Z;
                double d2 = dx * dx + dy * dy + dz * dz;
                double mag = dt / (d2 * Math.Sqrt(d2));
                double mi = b[i].Mass * mag;
                double mj = b[j].Mass * mag;
                b[i].Vx -= dx * mj; b[i].Vy -= dy * mj; b[i].Vz -= dz * mj;
                b[j].Vx += dx * mi; b[j].Vy += dy * mi; b[j].Vz += dz * mi;
            }
        }
        for (int i = 0; i < n; i++)
        {
            b[i].X += dt * b[i].Vx;
            b[i].Y += dt * b[i].Vy;
            b[i].Z += dt * b[i].Vz;
        }
    }

    static double Energy(Body* b, int n)
    {
        double e = 0;
        for (int i = 0; i < n; i++)
        {
            e += 0.5 * b[i].Mass * (b[i].Vx * b[i].Vx + b[i].Vy * b[i].Vy + b[i].Vz * b[i].Vz);
            for (int j = i + 1; j < n; j++)
            {
                double dx = b[i].X - b[j].X;
                double dy = b[i].Y - b[j].Y;
                double dz = b[i].Z - b[j].Z;
                e -= b[i].Mass * b[j].Mass / Math.Sqrt(dx * dx + dy * dy + dz * dz);
            }
        }
        return e;
    }

    static int Main()
    {
        int n = 5;
        Body* b = new Body[n];
        b[0] = new Body(0, 0, 0, 0, 0, 0, SolarMass);
        b[1] = new Body(4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01,
                        1.66007664274403694e-03 * DaysPerYear, 7.69901118419740425e-03 * DaysPerYear,
                        -6.90460016972063023e-05 * DaysPerYear, 9.54791938424326609e-04 * SolarMass);
        b[2] = new Body(8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01,
                        -2.76742510726862411e-03 * DaysPerYear, 4.99852801234917238e-03 * DaysPerYear,
                        2.30417297573763929e-05 * DaysPerYear, 2.85885980666130812e-04 * SolarMass);
        b[3] = new Body(1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01,
                        2.96460137564761618e-03 * DaysPerYear, 2.37847173959480950e-03 * DaysPerYear,
                        -2.96589568540237556e-05 * DaysPerYear, 4.36624404335156298e-05 * SolarMass);
        b[4] = new Body(1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01,
                        2.68067772490389322e-03 * DaysPerYear, 1.62824170038242295e-03 * DaysPerYear,
                        -9.51592254519715870e-05 * DaysPerYear, 5.15138902046611451e-05 * SolarMass);

        double px = 0, py = 0, pz = 0;
        for (int i = 0; i < n; i++)
        {
            px += b[i].Vx * b[i].Mass;
            py += b[i].Vy * b[i].Mass;
            pz += b[i].Vz * b[i].Mass;
        }
        b[0].Vx = -px / SolarMass;
        b[0].Vy = -py / SolarMass;
        b[0].Vz = -pz / SolarMass;

        Console.WriteLine(Energy(b, n));
        for (int s = 0; s < 2000000; s++) Advance(b, n, 0.01);
        Console.WriteLine(Energy(b, n));
        delete[] b;
        return 0;
    }
}
