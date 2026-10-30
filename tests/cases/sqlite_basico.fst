// std.sqlite: tablas, parámetros con nombre y por posición (sin inyección), lector tipado,
// NULL, BLOB, mapeo con Query<T>, transacciones con using var, errores y versiones async.
using std.collections;
using std.sqlite;
using std.text;
using std.io;
using std.task;

record class Persona(string Nombre, int Edad, double? Nota);

async Task<long> ContarAsync(SqliteConnection db)
{
    await db.ExecuteAsync("INSERT INTO gente (nombre, edad) VALUES (@n, @e)", new SqliteParameters().Add("@n", "Async").Add("@e", 1));
    return await db.ExecuteScalarInt64Async("SELECT COUNT(*) FROM gente", null);
}

void main()
{
    println(SqliteConnection.Version.StartsWith("3."));
    var db = new SqliteConnection(":memory:");   // (se cierra al final con Close)
    db.Execute("CREATE TABLE gente (id INTEGER PRIMARY KEY, nombre TEXT NOT NULL UNIQUE, edad INT, nota REAL, foto BLOB);" +
               "CREATE INDEX gente_edad ON gente(edad); -- comentario final\n");

    var ins = "INSERT INTO gente (nombre, edad, nota) VALUES (@nombre, @edad, @nota)";
    println(db.Execute(ins, new SqliteParameters().Add("@nombre", "Ana").Add("@edad", 31).Add("@nota", 9.5)));
    db.Execute(ins, new SqliteParameters().Add("nombre", "Luis").Add(":edad", 17).AddNull("@nota"));
    // Comillas y punto y coma en los datos: van como parámetro, no se interpretan.
    db.Execute(ins, new SqliteParameters().Add("@nombre", "O'Brien'); DROP TABLE gente; --").Add("@edad", 45).Add("@nota", 7.25));
    println(db.LastInsertRowId);
    db.Execute("INSERT INTO gente (nombre, edad) VALUES (?, ?)", new SqliteParameters().Add("Zoé ñandú").Add(28));

    using (var r = db.Query("SELECT id, nombre, edad, nota FROM gente WHERE edad > ? ORDER BY edad", new SqliteParameters().Add(18)))
    {
        println($"{r.FieldCount} columnas: {r.GetName(0)}, {r.GetName(1)}, {r.GetName(2)}, {r.GetName(3)}");
        while (r.Read())
        {
            string nota = r.IsNull("nota") ? "NULL" : "" + r.GetDouble("nota");
            println($"{r.GetInt64(0)} {r.GetString("nombre")} {r.GetInt("EDAD")} {nota} {r.GetFieldType(2)}");
        }
    }

    // Mapeo a objetos.
    List<Persona> todas = db.Query<Persona>("SELECT nombre, edad, nota FROM gente ORDER BY nombre",
                                            f => new Persona(f.GetString(0), f.GetInt(1), f.GetNullableDouble(2)));
    foreach (var p in todas) println($"{p.Nombre} {p.Edad} {p.Nota ?? -1}");
    var menores = db.Query<string>("SELECT nombre FROM gente WHERE edad < @limite", new SqliteParameters().Add("@limite", 18), f => f.GetString(0));
    println(Text.Join(menores, ","));

    println(db.ExecuteScalarInt64("SELECT COUNT(*) FROM gente"));
    println(db.ExecuteScalarString("SELECT nombre FROM gente WHERE id = @id", new SqliteParameters().Add("@id", 2)));
    println(db.ExecuteScalarDouble("SELECT AVG(edad) FROM gente"));
    println(db.ExecuteScalarString("SELECT nombre FROM gente WHERE id = 999") == "");
    println(db.Execute("UPDATE gente SET edad = edad + 1 WHERE edad >= @e", new SqliteParameters().Add("@e", 18)));
    println(db.Changes);

    // BLOB con bytes cero.
    StringBuilder bin = new StringBuilder();
    for (int i = 0; i < 256; i++) bin.AppendByte(i);
    db.Execute("UPDATE gente SET foto = @f WHERE id = 1", new SqliteParameters().AddBlob("@f", bin.ToString()));
    using (var r = db.Query("SELECT foto, length(foto), typeof(foto) FROM gente WHERE id = 1"))
    {
        r.Read();
        println($"{r.GetBlob(0) == bin.ToString()} {r.GetInt(1)} {r.GetString(2)} {r.GetFieldType(0)}");
    }

    // Transacciones.
    {
        using var tx = db.BeginTransaction();
        db.Execute("DELETE FROM gente");
        println(db.InTransaction + " " + db.ExecuteScalarInt64("SELECT COUNT(*) FROM gente"));
    }   // sin Commit: se deshace
    println(db.InTransaction + " " + db.ExecuteScalarInt64("SELECT COUNT(*) FROM gente"));
    {
        using var tx = db.BeginTransaction(true);
        db.Execute(ins, new SqliteParameters().Add("@nombre", "Eva").Add("@edad", 50).Add("@nota", 8.0));
        tx.Commit();
        try { tx.Commit(); } catch (InvalidOperationException e) { println(e.Message); }
    }
    println(db.ExecuteScalarInt64("SELECT COUNT(*) FROM gente"));
    try
    {
        db.RunInTransaction(() =>
        {
            db.Execute("DELETE FROM gente WHERE nombre = 'Eva'");
            throw new InvalidOperationException("algo falló");
        });
    }
    catch (InvalidOperationException e) { println("excepción: " + e.Message); }
    println(db.InTransaction);
    long n = db.RunInTransaction<long>(() =>
    {
        db.Execute("UPDATE gente SET edad = 51 WHERE nombre = 'Eva'");
        return db.Changes;
    });
    println(n);
    println(db.ExecuteScalarInt64("SELECT COUNT(*) FROM gente WHERE nombre = 'Eva'"));
    var t1 = db.BeginTransaction();
    try { db.BeginTransaction(); } catch (InvalidOperationException e) { println("anidada: InvalidOperationException"); }
    t1.Rollback();

    // Errores.
    try { db.Execute(ins, new SqliteParameters().Add("@nombre", "Ana").Add("@edad", 1).Add("@nota", 1.0)); }
    catch (SqliteException e) { println($"{e.ErrorCode} {e.PrimaryCode} {e.Message}"); }
    try { db.Execute("SELEC 1"); } catch (SqliteException e) { println(e.Message); }
    try { db.Query("SELECT * FROM no_existe"); } catch (SqliteException e) { println(e.Message); }
    try { db.Execute("SELECT 1 WHERE 1 = @a", new SqliteParameters().Add("@b", 1)); } catch (ArgumentException e) { println(e.Message); }
    try { db.Execute("SELECT ?", new SqliteParameters().Add(1).Add(2)); } catch (ArgumentException e) { println(e.Message); }
    using (var r = db.Query("SELECT 1"))
    {
        try { r.GetInt(0); } catch (InvalidOperationException e) { println("sin Read: InvalidOperationException"); }
        r.Read();
        try { r.GetInt(5); } catch (IndexOutOfRangeException e) { println("columna 5: IndexOutOfRangeException"); }
        try { r.GetInt("x"); } catch (IndexOutOfRangeException e) { println(e.Message); }
        println(r.Read());
    }

    // Async.
    println(ContarAsync(db).Result);
    var nombres = db.QueryAsync<string>("SELECT nombre FROM gente ORDER BY id LIMIT 2", f => f.GetString(0)).Result;
    println(Text.Join(nombres, " y "));

    // Archivo en disco y solo lectura.
    string ruta = Path.Combine(Path.GetTempPath(), "faset_sqlite_" + Environment.TickCount64() + ".db");
    {
        using var f = new SqliteConnection(ruta);
        f.Execute("CREATE TABLE t (x); INSERT INTO t VALUES (42)");
    }
    {
        using var ro = new SqliteConnection(ruta, true);
        println(ro.ExecuteScalarInt64("SELECT x FROM t"));
        try { ro.Execute("INSERT INTO t VALUES (1)"); } catch (SqliteException e) { println($"solo lectura: {e.PrimaryCode}"); }
    }
    File.Delete(ruta);
    try { new SqliteConnection(Path.Combine(ruta, "no", "existe.db")); } catch (SqliteException e) { println("no se abre: SqliteException"); }
    db.Close();
    try { db.Execute("SELECT 1"); } catch (InvalidOperationException e) { println(e.Message); }
}
