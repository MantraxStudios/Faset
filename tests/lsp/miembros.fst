class Externa
{
    public class Interna { public int Valor; }
    public enum Modo { A, B }
}

class Persona
{
    public string Nombre = "";
    public required int Edad { get; set; }
}

void Saludar(string nombre = "mundo", int veces = 1) { }

void main()
{
    Saludar(veces: 2);
    var p = new Persona { Edad = 3 };
    var i = new Externa.Interna();
}
