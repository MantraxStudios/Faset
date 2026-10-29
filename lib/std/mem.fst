// =============================================================================
//  std.mem  —  utilidades de memoria al estilo C++.
//
//    Span<T>   vista (puntero + longitud) con comprobación de límites
//    Arena     asignador por bloques: muchas reservas, una sola liberación
//    Box<T>    propietario único de un T en el heap (como unique_ptr)
// =============================================================================
namespace std.mem
{
    public memory_unsafe struct Span<T>
    {
        public T* Data;
        public int Length;

        public Span(T* data, int length)
        {
            Data = data;
            Length = length;
        }

        public bool IsEmpty => Length == 0;

        [TrackCaller] public T& operator[](int index)
        {
            if (index < 0 || index >= Length) panic("Span: índice fuera de rango");
            return Data[index];
        }

        [TrackCaller] public Span<T> Slice(int start, int length)
        {
            if (start < 0 || length < 0 || start + length > Length) panic("Span.Slice: rango fuera de la vista");
            return new Span<T>(Data + start, length);
        }

        [TrackCaller] public Span<T> Slice(int start) => Slice(start, Length - start);

        public void Fill(T value)
        {
            for (int i = 0; i < Length; i++) Data[i] = value;
        }

        [TrackCaller] public void CopyTo(Span<T> destination)
        {
            if (destination.Length < Length) panic("Span.CopyTo: destino demasiado pequeño");
            Memory.CopyItems<T>(destination.Data, Data, Length);
        }
    }

    // Reserva memoria de bloques grandes; todo se libera junto con Reset o delete.
    public memory_unsafe class Arena
    {
        byte* block;
        long used;
        long size;
        Arena previous;  // bloques anteriores (lista enlazada)

        public Arena() { Init(64 * 1024); }
        public Arena(long blockSize) { Init(blockSize); }

        void Init(long blockSize)
        {
            size = blockSize < 256 ? 256 : blockSize;
            block = (byte*)Memory.Alloc(size);
            used = 0;
        }

        ~Arena()
        {
            Memory.Free(block);
            delete previous;
        }

        public long BytesUsed => used + (previous != null ? previous.BytesUsed : 0);

        public void* Alloc(long bytes)
        {
            long aligned = (bytes + 15) & ~15L;
            if (used + aligned > size)
            {
                Arena old = new Arena(1);
                Memory.Free(old.block);
                old.block = block;
                old.used = used;
                old.size = size;
                old.previous = previous;
                previous = old;
                Init(aligned > size ? aligned : size);
            }
            void* p = block + used;
            used += aligned;
            Memory.Set(p, 0, aligned);
            return p;
        }

        public T* New<T>() => (T*)Alloc(sizeof(T));
        public T* NewArray<T>(int count) => (T*)Alloc((long)sizeof(T) * count);

        public void Reset()
        {
            delete previous;
            previous = null;
            used = 0;
        }
    }

    // Propietario único de un valor en el heap: lo libera en Reset o al hacer delete.
    public memory_unsafe class Box<T>
    {
        T* value;

        public Box(T v)
        {
            value = Memory.New<T>(1);
            *value = v;
        }

        ~Box() { Memory.Free(value); }

        public T* Get() => value;
        public T& Value() => *value;
        public bool HasValue => value != null;

        public void Reset()
        {
            Memory.Free(value);
            value = null;
        }
    }
}
