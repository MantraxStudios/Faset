// 'unsafe' (de C#) no existe: el error propone 'memory_unsafe'.
unsafe class Crudo
{
    public int* P;
}

void main()
{
    int x = 1;
    unsafe
    {
        int* p = &x;
        *p = 2;
    }
}
