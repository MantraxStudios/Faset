// N-body (Benchmarks Game): 5 cuerpos, 2 000 000 pasos. Coma flotante.
const PI = 3.14159265358979323846;
const SOLAR_MASS = 4 * PI * PI;
const DAYS_PER_YEAR = 365.24;

function body(x, y, z, vx, vy, vz, mass) {
  return { x, y, z, vx, vy, vz, mass };
}

const b = [
  body(0, 0, 0, 0, 0, 0, SOLAR_MASS),
  body(4.8414314424647209, -1.16032004402742839, -1.03622044471123109e-1,
    1.66007664274403694e-3 * DAYS_PER_YEAR, 7.69901118419740425e-3 * DAYS_PER_YEAR,
    -6.90460016972063023e-5 * DAYS_PER_YEAR, 9.54791938424326609e-4 * SOLAR_MASS),
  body(8.34336671824457987, 4.12479856412430479, -4.03523417114321381e-1,
    -2.76742510726862411e-3 * DAYS_PER_YEAR, 4.99852801234917238e-3 * DAYS_PER_YEAR,
    2.30417297573763929e-5 * DAYS_PER_YEAR, 2.85885980666130812e-4 * SOLAR_MASS),
  body(1.2894369562139131e1, -1.51111514016986312e1, -2.23307578892655734e-1,
    2.96460137564761618e-3 * DAYS_PER_YEAR, 2.3784717395948095e-3 * DAYS_PER_YEAR,
    -2.96589568540237556e-5 * DAYS_PER_YEAR, 4.36624404335156298e-5 * SOLAR_MASS),
  body(1.53796971148509165e1, -2.59193146099879641e1, 1.79258772950371181e-1,
    2.68067772490389322e-3 * DAYS_PER_YEAR, 1.62824170038242295e-3 * DAYS_PER_YEAR,
    -9.5159225451971587e-5 * DAYS_PER_YEAR, 5.15138902046611451e-5 * SOLAR_MASS),
];
const n = b.length;

function advance(dt) {
  for (let i = 0; i < n; i++) {
    const bi = b[i];
    for (let j = i + 1; j < n; j++) {
      const bj = b[j];
      const dx = bi.x - bj.x, dy = bi.y - bj.y, dz = bi.z - bj.z;
      const d2 = dx * dx + dy * dy + dz * dz;
      const mag = dt / (d2 * Math.sqrt(d2));
      const mi = bi.mass * mag, mj = bj.mass * mag;
      bi.vx -= dx * mj; bi.vy -= dy * mj; bi.vz -= dz * mj;
      bj.vx += dx * mi; bj.vy += dy * mi; bj.vz += dz * mi;
    }
  }
  for (let i = 0; i < n; i++) {
    const bi = b[i];
    bi.x += dt * bi.vx; bi.y += dt * bi.vy; bi.z += dt * bi.vz;
  }
}

function energy() {
  let e = 0;
  for (let i = 0; i < n; i++) {
    const bi = b[i];
    e += 0.5 * bi.mass * (bi.vx * bi.vx + bi.vy * bi.vy + bi.vz * bi.vz);
    for (let j = i + 1; j < n; j++) {
      const bj = b[j];
      const dx = bi.x - bj.x, dy = bi.y - bj.y, dz = bi.z - bj.z;
      e -= bi.mass * bj.mass / Math.sqrt(dx * dx + dy * dy + dz * dz);
    }
  }
  return e;
}

let px = 0, py = 0, pz = 0;
for (const bi of b) { px += bi.vx * bi.mass; py += bi.vy * bi.mass; pz += bi.vz * bi.mass; }
b[0].vx = -px / SOLAR_MASS; b[0].vy = -py / SOLAR_MASS; b[0].vz = -pz / SOLAR_MASS;

console.log(energy());
for (let s = 0; s < 2000000; s++) advance(0.01);
console.log(energy());
