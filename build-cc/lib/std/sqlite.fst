// =============================================================================
//  std.sqlite  —  bases de datos SQLite (incluido: no hace falta instalar nada).
//
//    using var db = new SqliteConnection("datos.db");       // ":memory:" para una en memoria
//    db.Execute("CREATE TABLE IF NOT EXISTS gente (id INTEGER PRIMARY KEY, nombre TEXT, edad INT)");
//    db.Execute("INSERT INTO gente (nombre, edad) VALUES (@nombre, @edad)",
//               new SqliteParameters().Add("@nombre", "Ana").Add("@edad", 31));
//
//    using var r = db.Query("SELECT nombre, edad FROM gente WHERE edad > ?", new SqliteParameters().Add(18));
//    while (r.Read()) println($"{r.GetString("nombre")}: {r.GetInt("edad")}");
//
//    List<Persona> todas = db.Query<Persona>("SELECT * FROM gente", f => new Persona(f.GetString(1), f.GetInt(2)));
//
//    using var tx = db.BeginTransaction();   // sin Commit, se deshace al salir del bloque
//    ...
//    tx.Commit();
//
//  Los valores siempre van como parámetros (@nombre, :nombre, $nombre o ? por posición), nunca
//  pegados al SQL: así no hay inyección de SQL y los textos pueden llevar comillas.
//
//  SQLite 3 (dominio público) está en lib/sqlite y se compila la primera vez que se usa
//  (una por compilador y arquitectura). Modo serializado: una conexión se puede usar desde
//  varios hilos y tareas (ExecuteAsync / QueryAsync). Los errores lanzan SqliteException.
// =============================================================================
using std.collections;
using std.text;
using std.task;

namespace std.sqlite
{
    // Tipo de un valor de SQLite (el de cada celda, no el declarado en la columna).
    public enum SqliteType { Integer = 1, Real = 2, Text = 3, Blob = 4, Null = 5 }

    // Error de SQLite: sintaxis, restricción violada (UNIQUE, NOT NULL, FOREIGN KEY), base de
    // datos bloqueada o dañada... ErrorCode es el código extendido de SQLite (p. ej. 2067 =
    // SQLITE_CONSTRAINT_UNIQUE) y PrimaryCode el principal (19 = SQLITE_CONSTRAINT).
    [ExceptionBase("Exception")]
    public class SqliteException
    {
        public var ErrorCode: int;

        public init() { Message = "Error de SQLite."; }
        public init(message: string) { Message = message; }
        public init(message: string, errorCode: int)
        {
            Message = message;
            ErrorCode = errorCode;
        }

        public prop PrimaryCode: int => ErrorCode & 0xFF;

        public func ToString() -> string => Exception.Describe(this);
    }

    // Funciones de SQLite (sqlite3.c) y de lib/sqlite/faset_sqlite.c.
    memory_unsafe static class Sql3
    {
        public static extern int faset_sqlite_open(string path, int flags, void** db);
        public static extern int faset_sqlite_prepare(void* db, string sql, long offset, void** stmt, long* next);
        public static extern int faset_sqlite_bind_text(void* stmt, int i, string s);
        public static extern int faset_sqlite_bind_blob(void* stmt, int i, string s);
        public static extern int faset_sqlite_param_index(void* stmt, string name);
        public static extern string faset_sqlite_column_text(void* stmt, int i);
        public static extern string faset_sqlite_column_blob(void* stmt, int i);
        public static extern string faset_sqlite_cstr(byte* p);

        public static extern int sqlite3_close_v2(void* db);
        public static extern byte* sqlite3_errmsg(void* db);
        public static extern byte* sqlite3_errstr(int rc);
        public static extern int sqlite3_extended_errcode(void* db);
        public static extern long sqlite3_changes64(void* db);
        public static extern long sqlite3_total_changes64(void* db);
        public static extern long sqlite3_last_insert_rowid(void* db);
        public static extern int sqlite3_get_autocommit(void* db);
        public static extern int sqlite3_busy_timeout(void* db, int ms);
        public static extern byte* sqlite3_libversion();

        public static extern int sqlite3_step(void* stmt);
        public static extern int sqlite3_reset(void* stmt);
        public static extern int sqlite3_finalize(void* stmt);
        public static extern int sqlite3_bind_int64(void* stmt, int i, long v);
        public static extern int sqlite3_bind_double(void* stmt, int i, double v);
        public static extern int sqlite3_bind_null(void* stmt, int i);
        public static extern int sqlite3_bind_parameter_count(void* stmt);
        public static extern int sqlite3_column_count(void* stmt);
        public static extern byte* sqlite3_column_name(void* stmt, int i);
        public static extern int sqlite3_column_type(void* stmt, int i);
        public static extern long sqlite3_column_int64(void* stmt, int i);
        public static extern double sqlite3_column_double(void* stmt, int i);

        public const int OK = 0;
        public const int ROW = 100;
        public const int DONE = 101;

        // Mensaje y código del último error de 'db'.
        public static func Error(db: void*, what: string) -> SqliteException
        {
            int code = db != null ? sqlite3_extended_errcode(db) : 1;
            string msg = db != null ? faset_sqlite_cstr(sqlite3_errmsg(db)) : "error de SQLite";
            return new SqliteException("SQLite (" + what + "): " + msg, code);
        }
    }

    // Un valor de parámetro.
    struct SqliteParam
    {
        public var Name: string;     // "" = por posición
        public var Kind: int;        // 1 entero, 2 real, 3 texto, 4 blob, 5 null
        public var I: long;
        public var D: double;
        public var S: string;
    }

    // Parámetros de una consulta, por nombre (@id, :id, $id o "id") o por posición (?):
    //   new SqliteParameters().Add("@id", 5).Add("@nombre", "Ana")
    //   new SqliteParameters().Add(5).Add("Ana")              // para "... WHERE id = ? AND nombre = ?"
    // Los parámetros por posición se numeran en el orden en que se añaden (?1, ?2...).
    public class SqliteParameters
    {
        internal var items: List<SqliteParam> = new List<SqliteParam>();
        var positional: int;

        public init() { }

        public prop Count: int => items.Count;

        func Put(name: string, kind: int, i: long, d: double, s: string) -> SqliteParameters
        {
            SqliteParam p;
            p.Name = name;
            p.Kind = kind;
            p.I = i;
            p.D = d;
            p.S = s;
            if (name.Length == 0) positional++;
            items.Add(p);
            return this;
        }

        // Por nombre.
        public func Add(name: string, value: long) -> SqliteParameters => Put(name, 1, value, 0, "");
        public func Add(name: string, value: int) -> SqliteParameters => Put(name, 1, value, 0, "");
        public func Add(name: string, value: double) -> SqliteParameters => Put(name, 2, 0, value, "");
        public func Add(name: string, value: bool) -> SqliteParameters => Put(name, 1, value ? 1 : 0, 0, "");
        public func Add(name: string, value: string) -> SqliteParameters => Put(name, 3, 0, 0, value);
        public func Add(name: string, value: long?) -> SqliteParameters => value.HasValue ? Add(name, value.Value) : AddNull(name);
        public func Add(name: string, value: int?) -> SqliteParameters => value.HasValue ? Add(name, value.Value) : AddNull(name);
        public func Add(name: string, value: double?) -> SqliteParameters => value.HasValue ? Add(name, value.Value) : AddNull(name);
        public func AddNull(name: string) -> SqliteParameters => Put(name, 5, 0, 0, "");
        // Datos binarios (BLOB).
        public func AddBlob(name: string, bytes: string) -> SqliteParameters => Put(name, 4, 0, 0, bytes);

        // Por posición (?).
        public func Add(value: long) -> SqliteParameters => Put("", 1, value, 0, "");
        public func Add(value: int) -> SqliteParameters => Put("", 1, value, 0, "");
        public func Add(value: double) -> SqliteParameters => Put("", 2, 0, value, "");
        public func Add(value: bool) -> SqliteParameters => Put("", 1, value ? 1 : 0, 0, "");
        public func Add(value: string) -> SqliteParameters => Put("", 3, 0, 0, value);
        public func AddNull() -> SqliteParameters => Put("", 5, 0, 0, "");
        public func AddBlob(bytes: string) -> SqliteParameters => Put("", 4, 0, 0, bytes);
    }

    // Conexión con una base de datos SQLite. Se cierra con Close(), con 'using var' o cuando
    // el recolector la recupera.
    public memory_unsafe class SqliteConnection
    {
        var db: void*;
        var path: string;
        internal var txDepth: int;      // 1 si hay una transacción de BeginTransaction abierta
        internal var txSerial: int;     // identifica la transacción actual

        // Abre (o crea) la base de datos 'path'. ":memory:" crea una base de datos en memoria.
        // También acepta URI ("file:datos.db?mode=ro").
        public init(path: string) { Open(path, 0); }

        // Solo lectura: no se puede modificar y el archivo debe existir.
        public init(path: string, readOnly: bool) { Open(path, readOnly ? 1 : 0); }

        func Open(p: string, flags: int)
        {
            path = String.Copy(p);
            void* h = null;
            int rc = Sql3.faset_sqlite_open(p, flags, &h);
            if (rc != Sql3.OK)
            {
                SqliteException e = h != null ? Sql3.Error(h, "abrir '" + p + "'")
                                              : new SqliteException("SQLite: no se puede abrir '" + p + "'", rc);
                if (h != null) Sql3.sqlite3_close_v2(h);
                throw e;
            }
            db = h;
        }

        deinit { Close(); }

        // Cierra la conexión (se puede llamar varias veces). Las consultas sin terminar se
        // cierran cuando se recogen sus lectores.
        public func Close()
        {
            if (db != null) Sql3.sqlite3_close_v2(db);
            db = null;
        }

        public prop IsOpen: bool => db != null;
        public prop DataSource: string => path;
        // Versión de SQLite ("3.54.1").
        public static prop Version: string => Sql3.faset_sqlite_cstr(Sql3.sqlite3_libversion());
        // Filas cambiadas por la última sentencia INSERT, UPDATE o DELETE.
        public prop Changes: long => Sql3.sqlite3_changes64(Handle());
        // rowid de la última fila insertada.
        public prop LastInsertRowId: long => Sql3.sqlite3_last_insert_rowid(Handle());
        // true si hay una transacción abierta (BEGIN sin COMMIT/ROLLBACK).
        public prop InTransaction: bool => Sql3.sqlite3_get_autocommit(Handle()) == 0;

        // Cuánto esperar (en milisegundos) si otra conexión tiene la base de datos bloqueada (5000 por defecto).
        public func SetBusyTimeout(milliseconds: int) { Sql3.sqlite3_busy_timeout(Handle(), milliseconds); }

        [TrackCaller] internal func Handle() -> void*
        {
            if (db == null) throw new InvalidOperationException("SqliteConnection: la conexión está cerrada");
            return db;
        }

        // ---------------------------------------------------------------- Execute

        // Ejecuta una o varias sentencias separadas por ';' (sin parámetros). Devuelve las filas
        // cambiadas por la última.
        [TrackCaller] public func Execute(sql: string) -> int => Execute(sql, null);

        // Ejecuta con parámetros. Si hay varias sentencias, cada una toma los parámetros con
        // nombre que use (los de posición solo valen para una sentencia).
        [TrackCaller] public func Execute(sql: string, parameters: SqliteParameters) -> int
        {
            void* h = Handle();
            long offset = 0;
            long changes = 0;
            bool* used = MakeUsed(parameters);
            while (offset < sql.Length)
            {
                void* st = null;
                long next = 0;
                int rc = Sql3.faset_sqlite_prepare(h, sql, offset, &st, &next);
                if (rc != Sql3.OK) throw Sql3.Error(h, "preparar");
                offset = next;
                if (st == null) continue;   // solo espacios o comentarios
                try
                {
                    Bind(h, st, parameters, used);
                    rc = Sql3.sqlite3_step(st);
                    while (rc == Sql3.ROW) rc = Sql3.sqlite3_step(st);
                    if (rc != Sql3.DONE) throw Sql3.Error(h, "ejecutar");
                    changes = Sql3.sqlite3_changes64(h);
                }
                finally { Sql3.sqlite3_finalize(st); }
            }
            CheckUsed(parameters, used);
            return (int)changes;
        }

        // Ejecuta una consulta y devuelve un lector de sus filas (ciérralo con 'using var' o
        // leyéndolo hasta el final). Solo la primera sentencia de 'sql'.
        [TrackCaller] public func Query(sql: string) -> SqliteDataReader => Query(sql, null);

        [TrackCaller] public func Query(sql: string, parameters: SqliteParameters) -> SqliteDataReader
        {
            void* h = Handle();
            void* st = null;
            long next = 0;
            int rc = Sql3.faset_sqlite_prepare(h, sql, 0, &st, &next);
            if (rc != Sql3.OK) throw Sql3.Error(h, "preparar");
            if (st == null) throw new ArgumentException("SqliteConnection.Query: la consulta está vacía", "sql");
            bool* used = MakeUsed(parameters);
            try
            {
                Bind(h, st, parameters, used);
                CheckUsed(parameters, used);
            }
            catch (Exception e)
            {
                Sql3.sqlite3_finalize(st);
                throw;
            }
            return new SqliteDataReader(this, st);
        }

        // Consulta y convierte cada fila con 'map':
        //   List<Persona> p = db.Query<Persona>("SELECT nombre, edad FROM gente", f => new Persona(f.GetString(0), f.GetInt(1)));
        [TrackCaller] public func Query<T>(sql: string, map: Func<SqliteDataReader, T>) -> List<T> => Query<T>(sql, null, map);

        [TrackCaller] public func Query<T>(sql: string, parameters: SqliteParameters, map: Func<SqliteDataReader, T>) -> List<T>
        {
            List<T> result = new List<T>();
            SqliteDataReader r = Query(sql, parameters);
            try
            {
                while (r.Read()) result.Add(map(r));
            }
            finally { r.Close(); }
            return result;
        }

        // Primera columna de la primera fila como entero (0 si no hay filas o es NULL):
        //   long n = db.ExecuteScalarInt64("SELECT COUNT(*) FROM gente");
        [TrackCaller] public func ExecuteScalarInt64(sql: string) -> long => ExecuteScalarInt64(sql, null);

        [TrackCaller] public func ExecuteScalarInt64(sql: string, parameters: SqliteParameters) -> long
        {
            SqliteDataReader r = Query(sql, parameters);
            long v = r.Read() && !r.IsNull(0) ? r.GetInt64(0) : 0;
            r.Close();
            return v;
        }

        // Primera columna de la primera fila como texto ("" si no hay filas o es NULL).
        [TrackCaller] public func ExecuteScalarString(sql: string) -> string => ExecuteScalarString(sql, null);

        [TrackCaller] public func ExecuteScalarString(sql: string, parameters: SqliteParameters) -> string
        {
            SqliteDataReader r = Query(sql, parameters);
            string v = r.Read() && !r.IsNull(0) ? r.GetString(0) : "";
            r.Close();
            return v;
        }

        // Primera columna de la primera fila como número real (0 si no hay filas o es NULL).
        [TrackCaller] public func ExecuteScalarDouble(sql: string) -> double => ExecuteScalarDouble(sql, null);

        [TrackCaller] public func ExecuteScalarDouble(sql: string, parameters: SqliteParameters) -> double
        {
            SqliteDataReader r = Query(sql, parameters);
            double v = r.Read() && !r.IsNull(0) ? r.GetDouble(0) : 0;
            r.Close();
            return v;
        }

        // ---------------------------------------------------------------- transacciones

        // Empieza una transacción. Termínala con Commit() o Rollback(); con 'using var', si no
        // se confirma, se deshace al salir del bloque. Ojo: hoy 'using' no llama al destructor
        // si el bloque sale por una excepción; para eso usa RunInTransaction o try/catch.
        //   immediate = true usa BEGIN IMMEDIATE (toma el bloqueo de escritura desde el principio).
        [TrackCaller] public func BeginTransaction() -> SqliteTransaction => BeginTransaction(false);

        [TrackCaller] public func BeginTransaction(immediate: bool) -> SqliteTransaction
        {
            if (txDepth > 0) throw new InvalidOperationException("SqliteConnection: ya hay una transacción abierta (SQLite no las anida; usa SAVEPOINT)");
            Execute(immediate ? "BEGIN IMMEDIATE" : "BEGIN");
            txDepth = 1;
            txSerial++;
            return new SqliteTransaction(this, txSerial);
        }

        // Ejecuta 'body' dentro de una transacción: la confirma si termina bien y la deshace
        // (y relanza la excepción) si lanza. Es la forma más segura ante excepciones.
        //   db.RunInTransaction(() => { db.Execute(...); db.Execute(...); });
        [TrackCaller] public func RunInTransaction(body: Action)
        {
            SqliteTransaction tx = BeginTransaction();
            try
            {
                body();
            }
            catch (Exception e)
            {
                if (!tx.IsFinished) tx.Rollback();
                throw;
            }
            if (!tx.IsFinished) tx.Commit();
        }

        // Igual, devolviendo el resultado de 'body'.
        [TrackCaller] public func RunInTransaction<T>(body: Func<T>) -> T
        {
            SqliteTransaction tx = BeginTransaction();
            T result;
            try
            {
                result = body();
            }
            catch (Exception e)
            {
                if (!tx.IsFinished) tx.Rollback();
                throw;
            }
            if (!tx.IsFinished) tx.Commit();
            return result;
        }

        // ---------------------------------------------------------------- async

        // Versiones asíncronas: se ejecutan en el grupo de tareas (la conexión es segura con hilos).
        public func ExecuteAsync(sql: string) -> Task<int> => Task.Run<int>(() => Execute(sql, null));
        public func ExecuteAsync(sql: string, parameters: SqliteParameters) -> Task<int> => Task.Run<int>(() => Execute(sql, parameters));
        public func QueryAsync<T>(sql: string, map: Func<SqliteDataReader, T>) -> Task<List<T>> => Task.Run<List<T>>(() => Query<T>(sql, null, map));
        public func QueryAsync<T>(sql: string, parameters: SqliteParameters, map: Func<SqliteDataReader, T>) -> Task<List<T>> =>
            Task.Run<List<T>>(() => Query<T>(sql, parameters, map));
        public func ExecuteScalarInt64Async(sql: string, parameters: SqliteParameters) -> Task<long> =>
            Task.Run<long>(() => ExecuteScalarInt64(sql, parameters));

        // ---------------------------------------------------------------- privado

        static func MakeUsed(p: SqliteParameters) -> bool* => new bool[p == null ? 1 : p.items.Count + 1];

        static func Bind(h: void*, st: void*, p: SqliteParameters, used: bool*)
        {
            if (p == null) return;
            int count = Sql3.sqlite3_bind_parameter_count(st);
            int position = 0;
            for (int k = 0; k < p.items.Count; k++)
            {
                SqliteParam v = p.items[k];
                int index;
                if (v.Name.Length == 0)
                {
                    position++;
                    index = position;
                    if (index > count) throw new ArgumentException("SQLite: sobra el parámetro por posición número " + position + " (la sentencia tiene " + count + ")", "parameters");
                }
                else
                {
                    index = Sql3.faset_sqlite_param_index(st, v.Name);
                    if (index == 0) continue;
                }
                used[k] = true;
                int rc;
                if (v.Kind == 1) rc = Sql3.sqlite3_bind_int64(st, index, v.I);
                else if (v.Kind == 2) rc = Sql3.sqlite3_bind_double(st, index, v.D);
                else if (v.Kind == 3) rc = Sql3.faset_sqlite_bind_text(st, index, v.S);
                else if (v.Kind == 4) rc = Sql3.faset_sqlite_bind_blob(st, index, v.S);
                else rc = Sql3.sqlite3_bind_null(st, index);
                if (rc != Sql3.OK) throw Sql3.Error(h, "parámetro");
            }
        }

        // Un parámetro con nombre que no aparece en ninguna sentencia suele ser una errata.
        static func CheckUsed(p: SqliteParameters, used: bool*)
        {
            if (p == null) return;
            for (int k = 0; k < p.items.Count; k++)
                if (!used[k] && p.items[k].Name.Length > 0)
                    throw new ArgumentException("SQLite: la consulta no tiene el parámetro '" + p.items[k].Name + "'", "parameters");
        }
    }

    // Filas de una consulta. Read() avanza a la siguiente; las columnas se leen por índice
    // (desde 0) o por nombre. Al terminar las filas (o con Close / 'using var') se libera la
    // sentencia.
    public memory_unsafe class SqliteDataReader
    {
        var conn: SqliteConnection;   // la mantiene viva mientras haya un lector
        var stmt: void*;
        var hasRow: bool;
        var done: bool;
        var names: List<string>;

        internal init(c: SqliteConnection, st: void*)
        {
            conn = c;
            stmt = st;
        }

        deinit { Close(); }

        // Avanza a la siguiente fila. false cuando no quedan.
        [TrackCaller] public func Read() -> bool
        {
            if (done) return false;
            int rc = Sql3.sqlite3_step(stmt);
            if (rc == Sql3.ROW)
            {
                hasRow = true;
                return true;
            }
            hasRow = false;
            done = true;
            if (rc != Sql3.DONE)
            {
                SqliteException e = Sql3.Error(conn.Handle(), "leer");
                Close();
                throw e;
            }
            Sql3.sqlite3_reset(stmt);   // libera los bloqueos de lectura enseguida
            return false;
        }

        // Libera la sentencia (se puede llamar varias veces).
        public func Close()
        {
            if (stmt != null) Sql3.sqlite3_finalize(stmt);
            stmt = null;
            done = true;
            hasRow = false;
        }

        public prop IsClosed: bool => stmt == null;
        public prop FieldCount: int => stmt == null ? 0 : Sql3.sqlite3_column_count(stmt);

        // Nombre de la columna 'i' (el alias de AS si lo hay).
        [TrackCaller] public func GetName(i: int) -> string
        {
            CheckColumn(i);
            return Sql3.faset_sqlite_cstr(Sql3.sqlite3_column_name(stmt, i));
        }

        // Índice de la columna 'name' (sin distinguir mayúsculas). IndexOutOfRangeException si no existe.
        [TrackCaller] public func GetOrdinal(name: string) -> int
        {
            if (stmt == null) throw new InvalidOperationException("SqliteDataReader: el lector está cerrado");
            if (names == null)
            {
                names = new List<string>();
                for (int i = 0; i < FieldCount; i++) names.Add(Sql3.faset_sqlite_cstr(Sql3.sqlite3_column_name(stmt, i)));
            }
            for (int i = 0; i < names.Count; i++)
                if (names[i] == name) return i;
            for (int i = 0; i < names.Count; i++)
                if (names[i].EqualsIgnoreCase(name)) return i;
            throw new IndexOutOfRangeException("SqliteDataReader: no hay ninguna columna '" + name + "'");
        }

        // Tipo del valor de la columna en la fila actual.
        [TrackCaller] public func GetFieldType(i: int) -> SqliteType
        {
            CheckRow(i);
            return (SqliteType)Sql3.sqlite3_column_type(stmt, i);
        }

        [TrackCaller] public func IsNull(i: int) -> bool => GetFieldType(i) == SqliteType.Null;
        [TrackCaller] public func IsNull(name: string) -> bool => IsNull(GetOrdinal(name));

        // Valores. Las conversiones son las de SQLite: un texto numérico se lee como número y
        // NULL como 0 o "" (comprueba IsNull si necesitas distinguirlo).
        [TrackCaller] public func GetInt64(i: int) -> long
        {
            CheckRow(i);
            return Sql3.sqlite3_column_int64(stmt, i);
        }
        [TrackCaller] public func GetInt32(i: int) -> int => (int)GetInt64(i);
        [TrackCaller] public func GetInt(i: int) -> int => (int)GetInt64(i);
        [TrackCaller] public func GetBoolean(i: int) -> bool => GetInt64(i) != 0;
        [TrackCaller] public func GetDouble(i: int) -> double
        {
            CheckRow(i);
            return Sql3.sqlite3_column_double(stmt, i);
        }
        // Texto (copia).
        [TrackCaller] public func GetString(i: int) -> string
        {
            CheckRow(i);
            return Sql3.faset_sqlite_column_text(stmt, i);
        }
        // Bytes de un BLOB (copia).
        [TrackCaller] public func GetBlob(i: int) -> string
        {
            CheckRow(i);
            return Sql3.faset_sqlite_column_blob(stmt, i);
        }
        // null si la celda es NULL.
        [TrackCaller] public func GetNullableInt64(i: int) -> long?
        {
            if (IsNull(i)) return null;
            return GetInt64(i);
        }
        [TrackCaller] public func GetNullableDouble(i: int) -> double?
        {
            if (IsNull(i)) return null;
            return GetDouble(i);
        }

        [TrackCaller] public func GetInt64(name: string) -> long => GetInt64(GetOrdinal(name));
        [TrackCaller] public func GetInt32(name: string) -> int => GetInt32(GetOrdinal(name));
        [TrackCaller] public func GetInt(name: string) -> int => GetInt(GetOrdinal(name));
        [TrackCaller] public func GetBoolean(name: string) -> bool => GetBoolean(GetOrdinal(name));
        [TrackCaller] public func GetDouble(name: string) -> double => GetDouble(GetOrdinal(name));
        [TrackCaller] public func GetString(name: string) -> string => GetString(GetOrdinal(name));
        [TrackCaller] public func GetBlob(name: string) -> string => GetBlob(GetOrdinal(name));
        [TrackCaller] public func GetNullableInt64(name: string) -> long? => GetNullableInt64(GetOrdinal(name));
        [TrackCaller] public func GetNullableDouble(name: string) -> double? => GetNullableDouble(GetOrdinal(name));

        [TrackCaller] func CheckColumn(i: int)
        {
            if (stmt == null) throw new InvalidOperationException("SqliteDataReader: el lector está cerrado");
            if (i < 0 || i >= Sql3.sqlite3_column_count(stmt)) throw new IndexOutOfRangeException("SqliteDataReader: columna " + i + " fuera de rango");
        }

        [TrackCaller] func CheckRow(i: int)
        {
            CheckColumn(i);
            if (!hasRow) throw new InvalidOperationException("SqliteDataReader: no hay fila actual (llama a Read() y comprueba que devuelve true)");
        }
    }

    // Transacción de BeginTransaction(). Sin Commit(), el destructor ('using var' o el
    // recolector) la deshace.
    public class SqliteTransaction
    {
        var conn: SqliteConnection;
        var serial: int;
        var finished: bool;

        internal init(c: SqliteConnection, s: int)
        {
            conn = c;
            serial = s;
        }

        deinit
        {
            // Solo si sigue siendo la transacción actual de la conexión.
            if (!finished && conn.IsOpen && conn.txDepth > 0 && conn.txSerial == serial) Rollback();
        }

        public prop Connection: SqliteConnection => conn;
        public prop IsFinished: bool => finished;

        // Confirma los cambios.
        [TrackCaller] public func Commit()
        {
            Finish();
            conn.Execute("COMMIT");
        }

        // Deshace los cambios.
        [TrackCaller] public func Rollback()
        {
            Finish();
            if (conn.InTransaction) conn.Execute("ROLLBACK");
        }

        [TrackCaller] func Finish()
        {
            if (finished) throw new InvalidOperationException("SqliteTransaction: la transacción ya terminó");
            finished = true;
            conn.txDepth = 0;
        }
    }
}
