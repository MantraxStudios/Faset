// Las versiones de std.thread con void* son memory_unsafe.
using std.thread;

void Trabajo(void* p) { }
void Cuerpo(int i, void* p) { }

void main()
{
    Thread t = Thread.Run(&Trabajo, null);
    ThreadPool pool = new ThreadPool(2);
    pool.Submit(&Trabajo, null);
    Parallel.For(0, 4, &Cuerpo, null);
    Thread u = new Thread(&Trabajo, null);
}
