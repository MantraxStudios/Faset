# Criba de Eratóstenes hasta 20 000 000: acceso a memoria y bucles.
n = 20000000
compuesto = bytearray(n + 1)
cuenta = 0
for i in range(2, n + 1):
    if compuesto[i]:
        continue
    cuenta += 1
    for j in range(i * i, n + 1, i):
        compuesto[j] = 1
print(cuenta)
