# N-body (Benchmarks Game): 5 cuerpos, 2 000 000 pasos. Coma flotante.
import math

PI = 3.14159265358979323846
SOLAR_MASS = 4 * PI * PI
DAYS_PER_YEAR = 365.24

bodies = [
    [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, SOLAR_MASS],
    [4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01,
     1.66007664274403694e-03 * DAYS_PER_YEAR, 7.69901118419740425e-03 * DAYS_PER_YEAR,
     -6.90460016972063023e-05 * DAYS_PER_YEAR, 9.54791938424326609e-04 * SOLAR_MASS],
    [8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01,
     -2.76742510726862411e-03 * DAYS_PER_YEAR, 4.99852801234917238e-03 * DAYS_PER_YEAR,
     2.30417297573763929e-05 * DAYS_PER_YEAR, 2.85885980666130812e-04 * SOLAR_MASS],
    [1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01,
     2.96460137564761618e-03 * DAYS_PER_YEAR, 2.37847173959480950e-03 * DAYS_PER_YEAR,
     -2.96589568540237556e-05 * DAYS_PER_YEAR, 4.36624404335156298e-05 * SOLAR_MASS],
    [1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01,
     2.68067772490389322e-03 * DAYS_PER_YEAR, 1.62824170038242295e-03 * DAYS_PER_YEAR,
     -9.51592254519715870e-05 * DAYS_PER_YEAR, 5.15138902046611451e-05 * SOLAR_MASS],
]
n = len(bodies)


def advance(b, dt):
    for i in range(n):
        bi = b[i]
        for j in range(i + 1, n):
            bj = b[j]
            dx = bi[0] - bj[0]
            dy = bi[1] - bj[1]
            dz = bi[2] - bj[2]
            d2 = dx * dx + dy * dy + dz * dz
            mag = dt / (d2 * math.sqrt(d2))
            mi = bi[6] * mag
            mj = bj[6] * mag
            bi[3] -= dx * mj
            bi[4] -= dy * mj
            bi[5] -= dz * mj
            bj[3] += dx * mi
            bj[4] += dy * mi
            bj[5] += dz * mi
    for bi in b:
        bi[0] += dt * bi[3]
        bi[1] += dt * bi[4]
        bi[2] += dt * bi[5]


def energy(b):
    e = 0.0
    for i in range(n):
        bi = b[i]
        e += 0.5 * bi[6] * (bi[3] * bi[3] + bi[4] * bi[4] + bi[5] * bi[5])
        for j in range(i + 1, n):
            bj = b[j]
            dx = bi[0] - bj[0]
            dy = bi[1] - bj[1]
            dz = bi[2] - bj[2]
            e -= bi[6] * bj[6] / math.sqrt(dx * dx + dy * dy + dz * dz)
    return e


px = py = pz = 0.0
for bi in bodies:
    px += bi[3] * bi[6]
    py += bi[4] * bi[6]
    pz += bi[5] * bi[6]
bodies[0][3] = -px / SOLAR_MASS
bodies[0][4] = -py / SOLAR_MASS
bodies[0][5] = -pz / SOLAR_MASS

print(repr(energy(bodies)))
for _ in range(2000000):
    advance(bodies, 0.01)
print(repr(energy(bodies)))
