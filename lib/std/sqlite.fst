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
        public int ErrorCode;

        public SqliteException() { Message = "Error de SQLite."; }
        public SqliteException(string message) { Message = message; }
        public SqliteException(string message, int errorCode)
        {
            Message = message;
            ErrorCode = errorCode;
        }

        public int PrimaryCode => ErrorCode & 0xFF;

        public string ToString() => Exception.Describe(this);
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
        public static SqliteException Error(void* db, string what)
        {
            int code = db != null ? sqlite3_extended_errcode(db) : 1;
            string msg = db != null ? faset_sqlite_cstr(sqlite3_errmsg(db)) : "error de SQLite";
            return new SqliteException("SQLite (" + what + "): " + msg, code);
        }
    }

    // Un valor de parámetro.
    struct SqliteParam
    {
        public string Name;     // "" = por posición
        public int Kind;        // 1 entero, 2 real, 3 texto, 4 blob, 5 null
        public long I;
        public double D;
        public string S;
    }

    // Parámetros de una consulta, por nombre (@id, :id, $id o "id") o por posición (?):
    //   new SqliteParameters().Add("@id", 5).Add("@nombre", "Ana")
    //   new SqliteParameters().Add(5).Add("Ana")              // para "... WHERE id = ? AND nombre = ?"
    // Los parámetros por posición se numeran en el orden en que se añaden (?1, ?2...).
    public class SqliteParameters
    {
        internal List<SqliteParam> items = new List<SqliteParam>();
        int positional;

        public SqliteParameters() { }

        public int Count => items.Count;

        SqliteParameters Put(string name, int kind, long i, double d, string s)
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
        public SqliteParameters Add(string name, long value) => Put(name, 1, value, 0, "");
        public SqliteParameters Add(string name, int value) => Put(name, 1, value, 0, "");
        public SqliteParameters Add(string name, double value) => Put(name, 2, 0, value, "");
        public SqliteParameters Add(string name, bool value) => Put(name, 1, value ? 1 : 0, 0, "");
        public SqliteParameters Add(string name, string value) => Put(name, 3, 0, 0, value);
        public SqliteParameters Add(string name, long? value) => value.HasValue ? Add(name, value.Value) : AddNull(name);
        public SqliteParameters Add(string name, int? value) => value.HasValue ? Add(name, value.Value) : AddNull(name);
        public SqliteParameters Add(string name, double? value) => value.HasValue ? Add(name, value.Value) : AddNull(name);
        public SqliteParameters AddNull(string name) => Put(name, 5, 0, 0, "");
        // Datos binarios (BLOB).
        public SqliteParameters AddBlob(string name, string bytes) => Put(name, 4, 0, 0, bytes);

        // Por posición (?).
        public SqliteParameters Add(long value) => Put("", 1, value, 0, "");
        public SqliteParameters Add(int value) => Put("", 1, value, 0, "");
        public SqliteParameters Add(double value) => Put("", 2, 0, value, "");
        public SqliteParameters Add(bool value) => Put("", 1, value ? 1 : 0, 0, "");
        public SqliteParameters Add(string value) => Put("", 3, 0, 0, value);
        public SqliteParameters AddNull() => Put("", 5, 0, 0, "");
        public SqliteParameters AddBlob(string bytes) => Put("", 4, 0, 0, bytes);
    }

    // Conexión con una base de datos SQLite. Se cierra con Close(), con 'using var' o cuando
    // el recolector la recupera.
    public memory_unsafe class SqliteConnection
    {
        void* db;
        string path;
        internal int txDepth;      // 1 si hay una transacción de BeginTransaction abierta
        internal int txSerial;     // identifica la transacción actual

        // Abre (o crea) la base de datos 'path'. ":memory:" crea una base de datos en memoria.
        // También acepta URI ("file:datos.db?mode=ro").
        public SqliteConnection(string path) { Open(path, 0); }

        // Solo lectura: no se puede modificar y el archivo debe existir.
        public SqliteConnection(string path, bool readOnly) { Open(path, readOnly ? 1 : 0); }

        void Open(string p, int flags)
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

        ~SqliteConnection() { Close(); }

        // Cierra la conexión (se puede llamar varias veces). Las consultas sin terminar se
        // cierran cuando se recogen sus lectores.
        public void Close()
        {
            if (db != null) Sql3.sqlite3_close_v2(db);
            db = null;
        }

        public bool IsOpen => db != null;
        public string DataSource => path;
        // Versión de SQLite ("3.54.1").
        public static string Version => Sql3.faset_sqlite_cstr(Sql3.sqlite3_libversion());
        // Filas cambiadas por la última sentencia INSERT, UPDATE o DELETE.
        public long Changes => Sql3.sqlite3_changes64(Handle());
        // rowid de la última fila insertada.
        public long LastInsertRowId => Sql3.sqlite3_last_insert_rowid(Handle());
        // true si hay una transacción abierta (BEGIN sin COMMIT/ROLLBACK).
        public bool InTransaction => Sql3.sqlite3_get_autocommit(Handle()) == 0;

        // Cuánto esperar (en milisegundos) si otra conexión tiene la base de datos bloqueada (5000 por defecto).
        public void SetBusyTimeout(int milliseconds) { Sql3.sqlite3_busy_timeout(Handle(), milliseconds); }

        [TrackCaller] internal void* Handle()
        {
            if (db == null) throw new InvalidOperationException("SqliteConnection: la conexión está cerrada");
            return db;
        }

        // ---------------------------------------------------------------- Execute

        // Ejecuta una o varias sentencias separadas por ';' (sin parámetros). Devuelve las filas
        // cambiadas por la última.
        [TrackCaller] public int Execute(string sql) => Execute(sql, null);

        // Ejecuta con parámetros. Si hay varias sentencias, cada una toma los parámetros con
        // nombre que use (los de posición solo valen para una sentencia).
        [TrackCaller] public int Execute(string sql, SqliteParameters parameters)
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
        [TrackCaller] public SqliteDataReader Query(string sql) => Query(sql, null);

        [TrackCaller] public SqliteDataReader Query(string sql, SqliteParameters parameters)
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
        [TrackCaller] public List<T> Query<T>(string sql, Func<SqliteDataReader, T> map) => Query<T>(sql, null, map);

        [TrackCaller] public List<T> Query<T>(string sql, SqliteParameters parameters, Func<SqliteDataReader, T> map)
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
        [TrackCaller] public long ExecuteScalarInt64(string sql) => ExecuteScalarInt64(sql, null);

        [TrackCaller] public long ExecuteScalarInt64(string sql, SqliteParameters parameters)
        {
            SqliteDataReader r = Query(sql, parameters);
            long v = r.Read() && !r.IsNull(0) ? r.GetInt64(0) : 0;
            r.Close();
            return v;
        }

        // Primera columna de la primera fila como texto ("" si no hay filas o es NULL).
        [TrackCaller] public string ExecuteScalarString(string sql) => ExecuteScalarString(sql, null);

        [TrackCaller] public string ExecuteScalarString(string sql, SqliteParameters parameters)
        {
            SqliteDataReader r = Query(sql, parameters);
            string v = r.Read() && !r.IsNull(0) ? r.GetString(0) : "";
            r.Close();
            return v;
        }

        // Primera columna de la primera fila como número real (0 si no hay filas o es NULL).
        [TrackCaller] public double ExecuteScalarDouble(string sql) => ExecuteScalarDouble(sql, null);

        [TrackCaller] public double ExecuteScalarDouble(string sql, SqliteParameters parameters)
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
        [TrackCaller] public SqliteTransaction BeginTransaction() => BeginTransaction(false);

        [TrackCaller] public SqliteTransaction BeginTransaction(bool immediate)
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
        [TrackCaller] public void RunInTransaction(Action body)
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
        [TrackCaller] public T RunInTransaction<T>(Func<T> body)
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
        public Task<int> ExecuteAsync(string sql) => Task.Run<int>(() => Execute(sql, null));
        public Task<int> ExecuteAsync(string sql, SqliteParameters parameters) => Task.Run<int>(() => Execute(sql, parameters));
        public Task<List<T>> QueryAsync<T>(string sql, Func<SqliteDataReader, T> map) => Task.Run<List<T>>(() => Query<T>(sql, null, map));
        public Task<List<T>> QueryAsync<T>(string sql, SqliteParameters parameters, Func<SqliteDataReader, T> map) =>
            Task.Run<List<T>>(() => Query<T>(sql, parameters, map));
        public Task<long> ExecuteScalarInt64Async(string sql, SqliteParameters parameters) =>
            Task.Run<long>(() => ExecuteScalarInt64(sql, parameters));

        // ---------------------------------------------------------------- privado

        static bool* MakeUsed(SqliteParameters p) => new bool[p == null ? 1 : p.items.Count + 1];

        static void Bind(void* h, void* st, SqliteParameters p, bool* used)
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
        static void CheckUsed(SqliteParameters p, bool* used)
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
        SqliteConnection conn;   // la mantiene viva mientras haya un lector
        void* stmt;
        bool hasRow;
        bool done;
        List<string> names;

        internal SqliteDataReader(SqliteConnection c, void* st)
        {
            conn = c;
            stmt = st;
        }

        ~SqliteDataReader() { Close(); }

        // Avanza a la siguiente fila. false cuando no quedan.
        [TrackCaller] public bool Read()
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
        public void Close()
        {
            if (stmt != null) Sql3.sqlite3_finalize(stmt);
            stmt = null;
            done = true;
            hasRow = false;
        }

        public bool IsClosed => stmt == null;
        public int FieldCount => stmt == null ? 0 : Sql3.sqlite3_column_count(stmt);

        // Nombre de la columna 'i' (el alias de AS si lo hay).
        [TrackCaller] public string GetName(int i)
        {
            CheckColumn(i);
            return Sql3.faset_sqlite_cstr(Sql3.sqlite3_column_name(stmt, i));
        }

        // Índice de la columna 'name' (sin distinguir mayúsculas). IndexOutOfRangeException si no existe.
        [TrackCaller] public int GetOrdinal(string name)
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
        [TrackCaller] public SqliteType GetFieldType(int i)
        {
            CheckRow(i);
            return (SqliteType)Sql3.sqlite3_column_type(stmt, i);
        }

        [TrackCaller] public bool IsNull(int i) => GetFieldType(i) == SqliteType.Null;
        [TrackCaller] public bool IsNull(string name) => IsNull(GetOrdinal(name));

        // Valores. Las conversiones son las de SQLite: un texto numérico se lee como número y
        // NULL como 0 o "" (comprueba IsNull si necesitas distinguirlo).
        [TrackCaller] public long GetInt64(int i)
        {
            CheckRow(i);
            return Sql3.sqlite3_column_int64(stmt, i);
        }
        [TrackCaller] public int GetInt32(int i) => (int)GetInt64(i);
        [TrackCaller] public int GetInt(int i) => (int)GetInt64(i);
        [TrackCaller] public bool GetBoolean(int i) => GetInt64(i) != 0;
        [TrackCaller] public double GetDouble(int i)
        {
            CheckRow(i);
            return Sql3.sqlite3_column_double(stmt, i);
        }
        // Texto (copia).
        [TrackCaller] public string GetString(int i)
        {
            CheckRow(i);
            return Sql3.faset_sqlite_column_text(stmt, i);
        }
        // Bytes de un BLOB (copia).
        [TrackCaller] public string GetBlob(int i)
        {
            CheckRow(i);
            return Sql3.faset_sqlite_column_blob(stmt, i);
        }
        // null si la celda es NULL.
        [TrackCaller] public long? GetNullableInt64(int i)
        {
            if (IsNull(i)) return null;
            return GetInt64(i);
        }
        [TrackCaller] public double? GetNullableDouble(int i)
        {
            if (IsNull(i)) return null;
            return GetDouble(i);
        }

        [TrackCaller] public long GetInt64(string name) => GetInt64(GetOrdinal(name));
        [TrackCaller] public int GetInt32(string name) => GetInt32(GetOrdinal(name));
        [TrackCaller] public int GetInt(string name) => GetInt(GetOrdinal(name));
        [TrackCaller] public bool GetBoolean(string name) => GetBoolean(GetOrdinal(name));
        [TrackCaller] public double GetDouble(string name) => GetDouble(GetOrdinal(name));
        [TrackCaller] public string GetString(string name) => GetString(GetOrdinal(name));
        [TrackCaller] public string GetBlob(string name) => GetBlob(GetOrdinal(name));
        [TrackCaller] public long? GetNullableInt64(string name) => GetNullableInt64(GetOrdinal(name));
        [TrackCaller] public double? GetNullableDouble(string name) => GetNullableDouble(GetOrdinal(name));

        [TrackCaller] void CheckColumn(int i)
        {
            if (stmt == null) throw new InvalidOperationException("SqliteDataReader: el lector está cerrado");
            if (i < 0 || i >= Sql3.sqlite3_column_count(stmt)) throw new IndexOutOfRangeException("SqliteDataReader: columna " + i + " fuera de rango");
        }

        [TrackCaller] void CheckRow(int i)
        {
            CheckColumn(i);
            if (!hasRow) throw new InvalidOperationException("SqliteDataReader: no hay fila actual (llama a Read() y comprueba que devuelve true)");
        }
    }

    // Transacción de BeginTransaction(). Sin Commit(), el destructor ('using var' o el
    // recolector) la deshace.
    public class SqliteTransaction
    {
        SqliteConnection conn;
        int serial;
        bool finished;

        internal SqliteTransaction(SqliteConnection c, int s)
        {
            conn = c;
            serial = s;
        }

        ~SqliteTransaction()
        {
            // Solo si sigue siendo la transacción actual de la conexión.
            if (!finished && conn.IsOpen && conn.txDepth > 0 && conn.txSerial == serial) Rollback();
        }

        public SqliteConnection Connection => conn;
        public bool IsFinished => finished;

        // Confirma los cambios.
        [TrackCaller] public void Commit()
        {
            Finish();
            conn.Execute("COMMIT");
        }

        // Deshace los cambios.
        [TrackCaller] public void Rollback()
        {
            Finish();
            if (conn.InTransaction) conn.Execute("ROLLBACK");
        }

        [TrackCaller] void Finish()
        {
            if (finished) throw new InvalidOperationException("SqliteTransaction: la transacción ya terminó");
            finished = true;
            conn.txDepth = 0;
        }
    }
}
