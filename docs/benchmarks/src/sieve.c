/* Criba de Eratóstenes hasta 20 000 000: acceso a memoria y bucles. */
#include <stdio.h>
#include <stdlib.h>

int main(void)
{
    int n = 20000000;
    unsigned char* compuesto = calloc((size_t)n + 1, 1);
    int cuenta = 0;
    for (int i = 2; i <= n; i++) {
        if (compuesto[i]) continue;
        cuenta++;
        for (long j = (long)i * i; j <= n; j += i) compuesto[j] = 1;
    }
    printf("%d\n", cuenta);
    free(compuesto);
    return 0;
}
