// Criba de Eratóstenes hasta 20 000 000: acceso a memoria y bucles.
const n = 20000000;
const compuesto = new Uint8Array(n + 1);
let cuenta = 0;
for (let i = 2; i <= n; i++) {
  if (compuesto[i]) continue;
  cuenta++;
  for (let j = i * i; j <= n; j += i) compuesto[j] = 1;
}
console.log(cuenta);
