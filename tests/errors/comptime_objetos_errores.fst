// Un objeto calculado con comptime que forma un ciclo no se puede escribir como constante.
class Nodo { public Nodo Otro; }
comptime Nodo Ciclo() { Nodo a = new Nodo(); Nodo b = new Nodo(); a.Otro = b; b.Otro = a; return a; }
void Main() { Nodo n = comptime Ciclo(); }
