using std.inexistente;
using std.collections;

namespace A { public class Cosa { } }
namespace B { public class Cosa { } }

struct P { public int X; }

class Caja
{
private:
    int secreto;
public:
    int visible;
}

void Inc(int& x) { x++; }
int& Mala() { int local = 1; return local; }

void main()
{
    Inc(5);
    long l = 1;
    Inc(l);
    List<P> ps = new List<P>();
    ps.Sort();
    Caja c = new Caja();
    c.secreto = 1;
    List x = null;
    auto d = new Dictionary<int>();
    delegate*<int, int> f = &Inc;
    P a = new P(), b = new P();
    bool igual = a == b;
}
