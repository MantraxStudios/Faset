// Errores de sintaxis del azúcar: cadenas interpoladas mal formadas y patrones.
void main()
{
    int n = 1;
    string a = $"hueco vacío {}";
    string b = $"llave suelta } aquí";
    string c = $"alineación {n,x}";
    var t = (x: 1);
}
