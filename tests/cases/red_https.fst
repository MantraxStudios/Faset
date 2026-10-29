// HTTPS contra servidores públicos (necesita internet). Sin red (no se resuelve
// example.com) o sin motor TLS termina con el código 77 y el test se omite.
using std.net;
using std.collections;
using std.os;

static class Program
{
    static void Show(HttpClient http, string what, string url)
    {
        Console.Write(what);
        Console.Write(": ");
        HttpResponse r = http.Get(url);
        if (r == null)
        {
            Console.Write("error [");
            Console.Write(Net.Describe(http.Error));
            Console.Write("] ");
            Console.WriteLine(http.ErrorMessage);
            return;
        }
        Console.Write(r.StatusCode);
        Console.WriteLine(r.Body.Length > 0 ? " con cuerpo" : " sin cuerpo");
        delete r;
    }

    static void Main()
    {
        List<IPAddress> addresses = new List<IPAddress>();
        bool online = Dns.GetHostAddresses("example.com", addresses);
        delete addresses;
        if (!online || !TlsStream.IsSupported)
        {
            Console.WriteLine("sin red o sin TLS: se omite");
            Environment.Exit(77);
        }
        HttpClient http = new HttpClient();
        http.Timeout = 20000;
        Show(http, "example.com", "https://example.com/");
        Show(http, "api.github.com", "https://api.github.com/zen");
        // http:// -> https:// (301 de Wikipedia)
        Show(http, "redirección", "http://wikipedia.org/");
        Show(http, "caducado", "https://expired.badssl.com/");
        Show(http, "otro nombre", "https://wrong.host.badssl.com/");
        Show(http, "autofirmado", "https://self-signed.badssl.com/");
        http.ValidateCertificate = false;   // solo para pruebas
        Show(http, "caducado sin verificar", "https://expired.badssl.com/");
        delete http;
    }
}
