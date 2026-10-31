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
        public var Data: T*
        public var Length: int

        public init(data: T*, length: int)
        {
            Data = data;
            Length = length;
        }

        public prop IsEmpty: bool => Length == 0;

        [TrackCaller] public T& operator[](int index)
        {
            if (index < 0 || index >= Length) throw new IndexOutOfRangeException("Span: índice fuera de rango");
            return Data[index];
        }

        [TrackCaller] public func Slice(start: int, length: int) -> Span<T>
        {
            if (start < 0 || length < 0 || start + length > Length) throw new ArgumentOutOfRangeException("Span.Slice: rango fuera de la vista", null);
            return new Span<T>(Data + start, length);
        }

        [TrackCaller] public func Slice(start: int) -> Span<T> => Slice(start, Length - start);

        public func Fill(value: T)
        {
            for (int i = 0; i < Length; i++) Data[i] = value;
        }

        [TrackCaller] public func CopyTo(destination: Span<T>)
        {
            if (destination.Length < Length) throw new ArgumentException("Span.CopyTo: destino demasiado pequeño");
            Memory.CopyItems<T>(destination.Data, Data, Length);
        }

        public func GetEnumerator() -> SpanEnumerator<T> => new SpanEnumerator<T>(this);
    }

    // Enumerador de Span<T> para foreach.
    public memory_unsafe struct SpanEnumerator<T>
    {
        var span: Span<T>
        var index: int

        public init(s: Span<T>)
        {
            span = s;
            index = -1;
        }

        public prop Current: T => span.Data[index];
        public func MoveNext() -> bool
        {
            index++;
            return index < span.Length;
        }
    }

    // Reserva memoria de bloques grandes; todo se libera junto con Reset o delete.
    public memory_unsafe class Arena
    {
        var block: byte*
        var used: long
        var size: long
        var previous: Arena  // bloques anteriores (lista enlazada)

        public init() { Init(64 * 1024); }
        public init(blockSize: long) { Init(blockSize); }

        func Init(blockSize: long)
        {
            size = blockSize < 256 ? 256 : blockSize;
            block = (byte*)Memory.Alloc(size);
            used = 0;
        }

        deinit
        {
            Memory.Free(block);
            delete previous;
        }

        public prop BytesUsed: long => used + (previous != null ? previous.BytesUsed : 0);

        public func Alloc(bytes: long) -> void*
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

        public func New<T>() -> T* => (T*)Alloc(sizeof(T));
        public func NewArray<T>(count: int) -> T* => (T*)Alloc((long)sizeof(T) * count);

        public func Reset()
        {
            delete previous;
            previous = null;
            used = 0;
        }
    }

    // Propietario único de un valor en el heap: lo libera en Reset o al hacer delete.
    public memory_unsafe class Box<T>
    {
        var value: T*

        public init(v: T)
        {
            value = Memory.New<T>(1);
            *value = v;
        }

        deinit { Memory.Free(value); }

        public func Get() -> T* => value;
        public func Value() -> T& => *value;
        public prop HasValue: bool => value != null;

        public func Reset()
        {
            Memory.Free(value);
            value = null;
        }
    }
}
