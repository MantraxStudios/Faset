// Excepciones en hilos: cada hilo tiene su propia pila de marcos 'try' (thread-local), así que
// las excepciones de un hilo nunca saltan a los 'try' de otro, ni siquiera a la vez.
using std.collections;
using std.thread;

class Resultado
{
    public Mutex M = new Mutex();
    public long Atrapadas;
    public long Finallys;
    public long Errores;  // excepciones que llegaron a un 'catch' equivocado
    ~Resultado() { delete M; }
}

int Trabajo(int hilo, int i)
{
    if (i % 3 == 0) throw new InvalidOperationException("hilo " + hilo + " vuelta " + i);
    return i;
}

class Tarea
{
    public int Id;
    public Resultado R;
}

void Correr(Tarea t)
{
    long atrapadas = 0, finallys = 0, errores = 0;
    for (int i = 0; i < 3000; i++)
    {
        try
        {
            try
            {
                Trabajo(t.Id, i);
                if (i % 50 == 1) Thread.Yield();  // mezcla los hilos
            }
            finally { finallys++; }
        }
        catch (InvalidOperationException e)
        {
            // El mensaje debe ser de este mismo hilo.
            if (e.Message != "hilo " + t.Id + " vuelta " + i) errores++;
            atrapadas++;
        }
    }
    // Error del runtime dentro de un hilo: también es una excepción.
    try
    {
        Tarea nadie = null;
        println(nadie.Id);
    }
    catch (NullReferenceException) { atrapadas++; }
    t.R.M.Lock();
    t.R.Atrapadas += atrapadas;
    t.R.Finallys += finallys;
    t.R.Errores += errores;
    t.R.M.Unlock();
}

void main()
{
    Resultado r = new Resultado();
    List<Thread> hilos = new List<Thread>();
    // El hilo principal también está dentro de un 'try' mientras los otros lanzan.
    try
    {
        for (int i = 0; i < 4; i++)
        {
            Tarea t = new Tarea();
            t.Id = i;
            t.R = r;
            hilos.Add(Thread.Run(&Correr, t));
        }
        for (int i = 0; i < hilos.Count; i++) hilos[i].Join();
    }
    catch (Exception e) { println("el principal no debería atrapar nada: " + e.Message); }
    println("atrapadas: " + r.Atrapadas);
    println("finally: " + r.Finallys);
    println("errores: " + r.Errores);
}
