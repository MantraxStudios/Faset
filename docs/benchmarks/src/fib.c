/* Fibonacci recursivo: llamadas a función y aritmética entera. */
#include <stdio.h>

static int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

int main(void)
{
    printf("%d\n", fib(37));
    return 0;
}
