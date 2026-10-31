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
//  Los structs también ([Reflectable] struct ...): viajan como 'object' en un Boxed<T>, y SetValue
//  e Invoke cambian el struct dentro de esa caja; Reflection.TypeOf(o) da su tipo.
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
    public abstract class BoxedValue
    {
        public abstract prop ValueType: Type { get; }  // typeof(T) de su Boxed<T>
    }

    public sealed class Boxed<T> : BoxedValue
    {
        public var Value: T;
        public init(value: T) { Value = value; }
        public override prop ValueType: Type => typeof(T);
        public override func ToString() -> string
        {
            comptime if (Tipo<T>.TieneToString) return $"{Value}";
            else return Tipo<T>.Nombre;  // un struct sin ToString(): su nombre, como en C#
        }
    }

    // Lo común a campos, propiedades y métodos: nombre, tipo que lo declara y atributos.
    public class MemberInfo
    {
        public var Name: string;
        public var DeclaringType: Type;
        public var Attributes: List<Attribute> = new List<Attribute>();

        public init(name: string, declaringType: Type)
        {
            Name = name;
            DeclaringType = declaringType;
        }

        // Primer atributo del tipo A (o derivado), o null.
        public func GetCustomAttribute<A>() -> A
        {
            foreach (Attribute a in Attributes)
            {
                A r = a as A;
                if (r != null) return r;
            }
            return null;
        }
        public func IsDefined<A>() -> bool => GetCustomAttribute<A>() != null;

        public override func ToString() -> string => Name;
    }

    // Un campo o una propiedad (IsProperty) con sus funciones de lectura y escritura.
    public class FieldInfo : MemberInfo
    {
        public var FieldType: Type;
        public var IsProperty: bool;
        public var Getter: Func<object, object>;
        public var Setter: Action<object, object>;  // null si es de solo lectura

        public init(name: string, fieldType: Type, declaringType: Type, isProperty: bool) : base(name, declaringType)
        {
            FieldType = fieldType;
            IsProperty = isProperty;
        }

        public prop CanWrite: bool => Setter != null;

        // Valor del campo en 'obj' (los que no son objetos llegan en un Boxed<T>).
        public func GetValue(obj: object) -> object
        {
            Reflection.CheckTarget(obj, DeclaringType, Name);
            return Getter(obj);
        }

        // Cambia el valor del campo en 'obj'. InvalidCastException si 'value' no es del tipo del campo.
        public func SetValue(obj: object, value: object)
        {
            Reflection.CheckTarget(obj, DeclaringType, Name);
            if (Setter == null) throw new InvalidOperationException($"'{DeclaringType.Name}.{Name}' es de solo lectura");
            Setter(obj, value);
        }
    }

    // Un método público. Invoke recibe los argumentos en una List<object> (Reflection.Box para valores).
    public class MethodInfo : MemberInfo
    {
        public var ReturnType: Type;    // null si devuelve void
        public var IsStatic: bool;
        public var ParameterNames: List<string> = new List<string>();
        public var ParameterTypes: List<Type> = new List<Type>();
        public var Invoker: Func<object, List<object>, object>;

        public init(name: string, returnType: Type, declaringType: Type, isStatic: bool) : base(name, declaringType)
        {
            ReturnType = returnType;
            IsStatic = isStatic;
        }

        // Llama al método sobre 'obj' (null si es estático). Devuelve null si el método es void.
        public func Invoke(obj: object, args: List<object>) -> object
        {
            if (!IsStatic) Reflection.CheckTarget(obj, DeclaringType, Name);
            int n = args == null ? 0 : args.Count;
            if (n != ParameterNames.Count)
                throw new ArgumentException($"'{DeclaringType.Name}.{Name}' espera {ParameterNames.Count} argumento(s), no {n}");
            if (args == null) args = new List<object>();
            return Invoker(obj, args);
        }
        public func Invoke(obj: object) -> object => Invoke(obj, null);

        public override func ToString() -> string
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
        public var Type: Type;
        public var Fields: List<FieldInfo> = new List<FieldInfo>();
        public var Properties: List<FieldInfo> = new List<FieldInfo>();
        public var Methods: List<MethodInfo> = new List<MethodInfo>();
        public var Attributes: List<Attribute> = new List<Attribute>();
        public var Factory: Func<object>;  // null si no tiene constructor sin parámetros (o es abstracta)

        public init(type: Type) { Type = type; }
    }

    public static class Reflection
    {
        static var tabla: Dictionary<string, TypeMetadata>;

        // Valor -> object: los objetos pasan tal cual; lo demás va en un Boxed<T>.
        public static func Box<T>(value: T) -> object
        {
            comptime if (Tipo<T>.EsClase || Tipo<T>.EsInterfaz) return value;
            else return new Boxed<T>(value);
        }

        // object -> T. InvalidCastException si 'o' no es un T (o un Boxed<T>).
        public static func Unbox<T>(o: object) -> T
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

        // Tipo de un valor: el de dentro para un Boxed<T> (typeof(Punto) para un struct Punto en su caja).
        public static func TypeOf(o: object) -> Type
        {
            if (o == null) return null;
            BoxedValue b = o as BoxedValue;
            return b != null ? b.ValueType : o.GetType();
        }

        // Nombre del tipo de un valor ('int' para un Boxed<int>).
        public static func TypeName(o: object) -> string
        {
            if (o == null) return "null";
            string n = o.GetType().Name;
            if (n.StartsWith("Boxed<") && n.EndsWith(">")) return n.Substring(6, n.Length - 7);
            return n;
        }

        // Metadatos de 't'. InvalidOperationException si el tipo no los tiene.
        public static func Metadata(t: Type) -> TypeMetadata
        {
            TypeMetadata m = Find(t);
            if (m == null)
                throw new InvalidOperationException($"el tipo '{t.Name}' no tiene metadatos de reflexión: márcalo con [Reflectable]");
            return m;
        }

        // Metadatos de 't', o null si no los tiene.
        public static func Find(t: Type) -> TypeMetadata
        {
            if (tabla == null || t == null) return null;
            TypeMetadata m;
            if (tabla.TryGetValue(t.FullName, out m)) return m;
            return null;
        }

        public static func CheckTarget(obj: object, declaring: Type, member: string)
        {
            if (obj == null) throw new ArgumentNullException("obj", $"el objeto de '{declaring.Name}.{member}' es null");
            if (!declaring.IsInstanceOfType(obj) && TypeOf(obj).FullName != declaring.FullName)  // un struct llega en un Boxed<T>
                throw new ArgumentException($"'{declaring.Name}.{member}' no se puede usar sobre un '{TypeName(obj)}'");
        }

        // Lo llama el compilador (src/Reflection.cpp) una vez por tipo con metadatos, al iniciar.
        public static func Registrar<T>() -> bool
        {
            if (tabla == null) tabla = new Dictionary<string, TypeMetadata>();
            TypeMetadata info = new TypeMetadata(typeof(T));
            comptime foreach (var a in Tipo<T>.Atributos) info.Attributes.Add(a.Crear());
            comptime if (Tipo<T>.TieneConstructorVacio) info.Factory = () => Box(new T());
            comptime foreach (var f in Tipo<T>.Miembros)
            {
                FieldInfo fi = new FieldInfo(f.Nombre, typeof(f.Tipo), typeof(f.DeclaradoEn), f.EsPropiedad);
                fi.Getter = (object o) => Box(f.Get(Unbox<T>(o)));
                // Un struct se cambia dentro de su Boxed<T> (como SetValue sobre un struct en una caja en C#).
                comptime if (f.PuedeEscribir && Tipo<T>.EsStruct)
                    fi.Setter = (object o, object v) => { Boxed<T> b = (Boxed<T>)o; f.Set(b.Value, Unbox<f.Tipo>(v)); };
                else comptime if (f.PuedeEscribir) fi.Setter = (object o, object v) => { f.Set((T)o, Unbox<f.Tipo>(v)); };
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
                        else comptime if (Tipo<T>.EsStruct)
                            mi.Invoker = (object o, List<object> args) => { Boxed<T> b = (Boxed<T>)o; m.InvocarLista(b.Value, args); return null; };
                        else mi.Invoker = (object o, List<object> args) => { m.InvocarLista((T)o, args); return null; };
                    }
                    else
                    {
                        mi = new MethodInfo(m.Nombre, typeof(m.Retorno), typeof(m.DeclaradoEn), m.EsEstatico);
                        comptime if (m.EsEstatico) mi.Invoker = (object o, List<object> args) => Box(m.InvocarLista(args));
                        else comptime if (Tipo<T>.EsStruct)
                            mi.Invoker = (object o, List<object> args) => { Boxed<T> b = (Boxed<T>)o; return Box(m.InvocarLista(b.Value, args)); };
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

        public static func GetFields(this t: Type) -> List<FieldInfo> => Metadata(t).Fields;
        public static func GetProperties(this t: Type) -> List<FieldInfo> => Metadata(t).Properties;
        public static func GetMethods(this t: Type) -> List<MethodInfo> => Metadata(t).Methods;
        public static func GetCustomAttributes(this t: Type) -> List<Attribute> => Metadata(t).Attributes;
        public static func HasMetadata(this t: Type) -> bool => Find(t) != null;

        // Campos y propiedades juntos, en orden de declaración (primero los de la base).
        public static func GetMembers(this t: Type) -> List<FieldInfo>
        {
            List<FieldInfo> r = new List<FieldInfo>();
            foreach (FieldInfo f in Metadata(t).Fields) r.Add(f);
            foreach (FieldInfo f in Metadata(t).Properties) r.Add(f);
            return r;
        }

        public static func GetField(this t: Type, name: string) -> FieldInfo
        {
            foreach (FieldInfo f in Metadata(t).Fields) if (f.Name == name) return f;
            return null;
        }
        public static func GetProperty(this t: Type, name: string) -> FieldInfo
        {
            foreach (FieldInfo f in Metadata(t).Properties) if (f.Name == name) return f;
            return null;
        }
        public static func GetMethod(this t: Type, name: string) -> MethodInfo
        {
            foreach (MethodInfo m in Metadata(t).Methods) if (m.Name == name) return m;
            return null;
        }
    }

    public static class Activator
    {
        // Instancia nueva de 't' con su constructor sin parámetros.
        public static func CreateInstance(t: Type) -> object
        {
            TypeMetadata m = Reflection.Metadata(t);
            if (m.Factory == null) throw new InvalidOperationException($"'{t.Name}' no tiene un constructor público sin parámetros");
            return m.Factory();
        }

        public static func CreateInstance<T>() -> T => new T();
    }
}
