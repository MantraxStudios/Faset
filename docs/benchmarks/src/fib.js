// Fibonacci recursivo: llamadas a función y aritmética entera.
function fib(n) {
  return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

console.log(fib(37));
