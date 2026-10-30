// =============================================================================
//  std.reflection  —  reflexión al ejecutar (opcional).
//
//    using std.reflection;
//
//    [Reflectable]
//    class Persona { public string Nombre = ""; public int Edad; }
//
//    foreach (FieldInfo f in typeof(Persona).GetFields())
//        Console.WriteLine($"{f.Name}: {f.FieldType.Name} = {f.GetValue(p)}");
//    object o = Activator.CreateInstance(typeof(Persona));
//
//  Solo llevan metadatos las clases marcadas con [Reflectable] (y sus derivadas) y las que el
//  compilador ve escritas en typeof(X).GetFields()/GetProperties()/GetMethods()/... o en
//  Activator.CreateInstance: un programa que no usa la reflexión no crece. Los metadatos los genera
//  Registrar<T>() con la reflexión de tiempo de compilación (comptime foreach sobre Tipo<T>): cada
//  campo recibe funciones de acceso directas, sin búsquedas por nombre al leer o escribir.
//
//  Los valores que no son objetos (int, double, string, structs...) viajan como 'object' dentro de
//  un Boxed<T>: Reflection.Box(5) y Reflection.Unbox<int>(o).
// =============================================================================
using std.collections;

namespace std.reflection
{
    // Un valor que no es un objeto (int, string, un struct...) guardado como 'object'.
    public sealed class Boxed<T>
    {
        public T Value;
        public Boxed(T value) { Value = value; }
        public override string ToString() => $"{Value}";
    }

    // Lo común a campos, propiedades y métodos: nombre, tipo que lo declara y atributos.
    public class MemberInfo
    {
        public string Name;
        public Type DeclaringType;
        public List<Attribute> Attributes = new List<Attribute>();

        public MemberInfo(string name, Type declaringType)
        {
            Name = name;
            DeclaringType = declaringType;
        }

        // Primer atributo del tipo A (o derivado), o null.
        public A GetCustomAttribute<A>()
        {
            foreach (Attribute a in Attributes)
            {
                A r = a as A;
                if (r != null) return r;
            }
            return null;
        }
        public bool IsDefined<A>() => GetCustomAttribute<A>() != null;

        public override string ToString() => Name;
    }

    // Un campo o una propiedad (IsProperty) con sus funciones de lectura y escritura.
    public class FieldInfo : MemberInfo
    {
        public Type FieldType;
        public bool IsProperty;
        public Func<object, object> Getter;
        public Action<object, object> Setter;  // null si es de solo lectura

        public FieldInfo(string name, Type fieldType, Type declaringType, bool isProperty) : base(name, declaringType)
        {
            FieldType = fieldType;
            IsProperty = isProperty;
        }

        public bool CanWrite => Setter != null;

        // Valor del campo en 'obj' (los que no son objetos llegan en un Boxed<T>).
        public object GetValue(object obj)
        {
            Reflection.CheckTarget(obj, DeclaringType, Name);
            return Getter(obj);
        }

        // Cambia el valor del campo en 'obj'. InvalidCastException si 'value' no es del tipo del campo.
        public void SetValue(object obj, object value)
        {
            Reflection.CheckTarget(obj, DeclaringType, Name);
            if (Setter == null) throw new InvalidOperationException($"'{DeclaringType.Name}.{Name}' es de solo lectura");
            Setter(obj, value);
        }
    }

    // Un método público. Invoke recibe los argumentos en una List<object> (Reflection.Box para valores).
    public class MethodInfo : MemberInfo
    {
        public Type ReturnType;    // null si devuelve void
        public bool IsStatic;
        public List<string> ParameterNames = new List<string>();
        public List<Type> ParameterTypes = new List<Type>();
        public Func<object, List<object>, object> Invoker;

        public MethodInfo(string name, Type returnType, Type declaringType, bool isStatic) : base(name, declaringType)
        {
            ReturnType = returnType;
            IsStatic = isStatic;
        }

        // Llama al método sobre 'obj' (null si es estático). Devuelve null si el método es void.
        public object Invoke(object obj, List<object> args)
        {
            if (!IsStatic) Reflection.CheckTarget(obj, DeclaringType, Name);
            int n = args == null ? 0 : args.Count;
            if (n != ParameterNames.Count)
                throw new ArgumentException($"'{DeclaringType.Name}.{Name}' espera {ParameterNames.Count} argumento(s), no {n}");
            if (args == null) args = new List<object>();
            return Invoker(obj, args);
        }
        public object Invoke(object obj) => Invoke(obj, null);

        public override string ToString()
        {
            string s = (ReturnType == null ? "void" : ReturnType.Name) + " " + Name + "(";
            for (int i = 0; i < ParameterNames.Count; i++)
                s += (i > 0 ? ", " : "") + ParameterTypes[i].Name + " " + ParameterNames[i];
            return s + ")";
        }
    }

    // Metadatos de un tipo (los crea Registrar<T>).
    public class TypeMetadata
    {
        public Type Type;
        public List<FieldInfo> Fields = new List<FieldInfo>();
        public List<FieldInfo> Properties = new List<FieldInfo>();
        public List<MethodInfo> Methods = new List<MethodInfo>();
        public List<Attribute> Attributes = new List<Attribute>();
        public Func<object> Factory;  // null si no tiene constructor sin parámetros (o es abstracta)

        public TypeMetadata(Type type) { Type = type; }
    }

    public static class Reflection
    {
        static Dictionary<string, TypeMetadata> tabla;

        // Valor -> object: los objetos pasan tal cual; lo demás va en un Boxed<T>.
        public static object Box<T>(T value)
        {
            comptime if (Tipo<T>.EsClase || Tipo<T>.EsInterfaz) return value;
            else return new Boxed<T>(value);
        }

        // object -> T. InvalidCastException si 'o' no es un T (o un Boxed<T>).
        public static T Unbox<T>(object o)
        {
            comptime if (Tipo<T>.EsClase || Tipo<T>.EsInterfaz)
            {
                if (o == null) return null;
                T r = o as T;
                if (r == null) throw new InvalidCastException($"no se puede convertir '{TypeName(o)}' en '{typeof(T).Name}'");
                return r;
            }
            else
            {
                Boxed<T> b = o as Boxed<T>;
                if (b == null) throw new InvalidCastException($"no se puede convertir '{TypeName(o)}' en '{typeof(T).Name}'");
                return b.Value;
            }
        }

        // Nombre del tipo de un valor ('int' para un Boxed<int>).
        public static string TypeName(object o)
        {
            if (o == null) return "null";
            string n = o.GetType().Name;
            if (n.StartsWith("Boxed<") && n.EndsWith(">")) return n.Substring(6, n.Length - 7);
            return n;
        }

        // Metadatos de 't'. InvalidOperationException si el tipo no los tiene.
        public static TypeMetadata Metadata(Type t)
        {
            TypeMetadata m = Find(t);
            if (m == null)
                throw new InvalidOperationException($"el tipo '{t.Name}' no tiene metadatos de reflexión: márcalo con [Reflectable]");
            return m;
        }

        // Metadatos de 't', o null si no los tiene.
        public static TypeMetadata Find(Type t)
        {
            if (tabla == null || t == null) return null;
            TypeMetadata m;
            if (tabla.TryGetValue(t.FullName, out m)) return m;
            return null;
        }

        public static void CheckTarget(object obj, Type declaring, string member)
        {
            if (obj == null) throw new ArgumentNullException("obj", $"el objeto de '{declaring.Name}.{member}' es null");
            if (!declaring.IsInstanceOfType(obj))
                throw new ArgumentException($"'{declaring.Name}.{member}' no se puede usar sobre un '{obj.GetType().Name}'");
        }

        // Lo llama el compilador (src/Reflection.cpp) una vez por tipo con metadatos, al iniciar.
        public static bool Registrar<T>()
        {
            if (tabla == null) tabla = new Dictionary<string, TypeMetadata>();
            TypeMetadata info = new TypeMetadata(typeof(T));
            comptime foreach (var a in Tipo<T>.Atributos) info.Attributes.Add(a.Crear());
            comptime if (Tipo<T>.TieneConstructorVacio) info.Factory = () => new T();
            comptime foreach (var f in Tipo<T>.Miembros)
            {
                FieldInfo fi = new FieldInfo(f.Nombre, typeof(f.Tipo), typeof(f.DeclaradoEn), f.EsPropiedad);
                fi.Getter = (object o) => Box(f.Get((T)o));
                comptime if (f.PuedeEscribir) fi.Setter = (object o, object v) => { f.Set((T)o, Unbox<f.Tipo>(v)); };
                comptime foreach (var a in f.Atributos) fi.Attributes.Add(a.Crear());
                comptime if (f.EsPropiedad) info.Properties.Add(fi);
                else info.Fields.Add(fi);
            }
            comptime foreach (var m in Tipo<T>.Metodos)
            {
                comptime if (m.EsInvocable)
                {
                    MethodInfo mi;
                    comptime if (m.Retorno.EsVoid)
                    {
                        mi = new MethodInfo(m.Nombre, null, typeof(m.DeclaradoEn), m.EsEstatico);
                        comptime if (m.EsEstatico) mi.Invoker = (object o, List<object> args) => { m.InvocarLista(args); return null; };
                        else mi.Invoker = (object o, List<object> args) => { m.InvocarLista((T)o, args); return null; };
                    }
                    else
                    {
                        mi = new MethodInfo(m.Nombre, typeof(m.Retorno), typeof(m.DeclaradoEn), m.EsEstatico);
                        comptime if (m.EsEstatico) mi.Invoker = (object o, List<object> args) => Box(m.InvocarLista(args));
                        else mi.Invoker = (object o, List<object> args) => Box(m.InvocarLista((T)o, args));
                    }
                    comptime foreach (var p in m.Parametros)
                    {
                        mi.ParameterNames.Add(p.Nombre);
                        mi.ParameterTypes.Add(typeof(p.Tipo));
                    }
                    comptime foreach (var a in m.Atributos) mi.Attributes.Add(a.Crear());
                    info.Methods.Add(mi);
                }
            }
            tabla[info.Type.FullName] = info;
            return true;
        }

        // ---- extensiones de Type (typeof(X).GetFields()...)

        public static List<FieldInfo> GetFields(this Type t) => Metadata(t).Fields;
        public static List<FieldInfo> GetProperties(this Type t) => Metadata(t).Properties;
        public static List<MethodInfo> GetMethods(this Type t) => Metadata(t).Methods;
        public static List<Attribute> GetCustomAttributes(this Type t) => Metadata(t).Attributes;
        public static bool HasMetadata(this Type t) => Find(t) != null;

        // Campos y propiedades juntos, en orden de declaración (primero los de la base).
        public static List<FieldInfo> GetMembers(this Type t)
        {
            List<FieldInfo> r = new List<FieldInfo>();
            foreach (FieldInfo f in Metadata(t).Fields) r.Add(f);
            foreach (FieldInfo f in Metadata(t).Properties) r.Add(f);
            return r;
        }

        public static FieldInfo GetField(this Type t, string name)
        {
            foreach (FieldInfo f in Metadata(t).Fields) if (f.Name == name) return f;
            return null;
        }
        public static FieldInfo GetProperty(this Type t, string name)
        {
            foreach (FieldInfo f in Metadata(t).Properties) if (f.Name == name) return f;
            return null;
        }
        public static MethodInfo GetMethod(this Type t, string name)
        {
            foreach (MethodInfo m in Metadata(t).Methods) if (m.Name == name) return m;
            return null;
        }
    }

    public static class Activator
    {
        // Instancia nueva de 't' con su constructor sin parámetros.
        public static object CreateInstance(Type t)
        {
            TypeMetadata m = Reflection.Metadata(t);
            if (m.Factory == null) throw new InvalidOperationException($"'{t.Name}' no tiene un constructor público sin parámetros");
            return m.Factory();
        }

        public static T CreateInstance<T>() => new T();
    }
}
