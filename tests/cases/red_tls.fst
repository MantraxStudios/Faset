// TLS de extremo a extremo sin internet: el programa abre un servidor TLS en 127.0.0.1
// (certificado de tests/cases/red_tls/, firmado por una autoridad de pruebas que solo sirve
// para esto) y se lanza a sí mismo como cliente ("cliente <puerto>"). El cliente prueba la
// verificación del certificado: con la autoridad de pruebas, sin ella, con otro nombre y
// sin verificar. Si no hay motor TLS (Linux sin OpenSSL) termina con el código 77 (omitido).
using std.net;
using std.text;
using std.os;
using std.time;

static class Program
{
    const string Ca = "tests/cases/red_tls/ca.pem";
    const string Cert = "tests/cases/red_tls/servidor.pem";
    const string Key = "tests/cases/red_tls/servidor.key";
    const int Conexiones = 7;

    // ---------------------------------------------------------------- cliente (proceso hijo)

    static void Report(string what, TlsStream tls, bool ok)
    {
        Console.Write(what);
        Console.Write(": ");
        if (!ok)
        {
            Console.Write("error [");
            Console.Write(Net.Describe(tls.Error));
            Console.Write("] ");
            Console.WriteLine(tls.ErrorMessage);
            return;
        }
        tls.WriteLine("hola");
        string line;
        if (tls.ReadLine(out line)) Console.WriteLine(line);
        else Console.WriteLine("sin respuesta");
        String.Free(line);
    }

    static void Eco(string what, string host, int port, string name, string caFile, bool validate)
    {
        TcpClient c = new TcpClient();
        c.ReceiveTimeout = 10000;
        c.SendTimeout = 10000;
        if (!c.Connect(host, port, 10000))
        {
            Console.Write(what);
            Console.Write(": no conecta: ");
            Console.WriteLine(c.ErrorMessage);
            delete c;
            return;
        }
        TlsStream tls = new TlsStream(c);   // toma la conexión TCP
        tls.CertificateAuthorityFile = caFile;
        tls.ValidateCertificate = validate;
        Report(what, tls, tls.AuthenticateAsClient(name));
        delete tls;
    }

    static void Get(HttpClient http, string url)
    {
        HttpResponse r = http.Get(url);
        Console.Write("https: ");
        if (r == null)
        {
            Console.Write("error [");
            Console.Write(Net.Describe(http.Error));
            Console.Write("] ");
            Console.WriteLine(http.ErrorMessage);
            return;
        }
        Console.Write(r.StatusCode);
        Console.Write(" ");
        Console.WriteLine(r.Body);
        delete r;
    }

    static void Client(int port)
    {
        // 1) con la autoridad de pruebas: TlsStream.Connect
        TlsStream tls = new TlsStream();
        tls.ReceiveTimeout = 10000;
        tls.CertificateAuthorityFile = Ca;
        Report("verificado", tls, tls.Connect("localhost", port));
        Console.Write("versión: ");
        Console.WriteLine(tls.Protocol.StartsWith("TLSv1.") ? "TLSv1.x" : tls.Protocol);
        delete tls;
        // 2) sin la autoridad: el certificado no es de confianza
        Eco("sin autoridad", "127.0.0.1", port, "localhost", "", true);
        // 3) el certificado no es de ese nombre
        Eco("otro nombre", "127.0.0.1", port, "otro.ejemplo", Ca, true);
        // 4) sin verificar (solo para pruebas)
        Eco("sin verificar", "127.0.0.1", port, "otro.ejemplo", "", false);
        // 5) dirección IP (el certificado la incluye)
        Eco("por IP", "127.0.0.1", port, "127.0.0.1", Ca, true);
        // 6) y 7) HttpClient con https://
        HttpClient http = new HttpClient();
        http.Timeout = 10000;
        http.CertificateAuthorityFile = Ca;
        string url = String.Concat("https://localhost:", Environment.GetArg(2), "/datos");
        Get(http, url);
        http.CertificateAuthorityFile = "";
        Get(http, url);
        String.Free(url);
        delete http;
    }

    // ---------------------------------------------------------------- servidor (proceso padre)

    static void Serve(TcpListener server)
    {
        TcpClient c = server.AcceptTcpClient(15000);
        if (c == null)
        {
            Console.WriteLine("servidor: el cliente no se conectó");
            return;
        }
        TlsStream tls = new TlsStream(c);
        tls.ReceiveTimeout = 10000;
        tls.SendTimeout = 10000;
        if (!tls.AuthenticateAsServer(Cert, Key))
        {
            // el cliente rechazó el certificado (o no se pudo leer)
            if (tls.Error == SocketError.InvalidArgument) Console.WriteLine(tls.ErrorMessage);
            else Console.WriteLine("servidor: negociación rechazada");
            delete tls;
            return;
        }
        string line;
        if (tls.ReadLine(out line))
        {
            if (line.StartsWith("GET "))
            {
                Console.Write("servidor: ");
                Console.WriteLine(line);
                string h;
                while (tls.ReadLine(out h))
                {
                    bool end = h.Length == 0;
                    String.Free(h);
                    if (end) break;
                }
                tls.Write("HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nseguro");
            }
            else
            {
                Console.Write("servidor: recibido ");
                Console.WriteLine(line);
                tls.Write("eco: ");
                tls.WriteLine(line);
            }
        }
        String.Free(line);
        delete tls;
    }

    static void Main()
    {
        if (!TlsStream.IsSupported)
        {
            Console.WriteLine("sin motor TLS: se omite");
            Environment.Exit(77);
        }
        if (Environment.ArgCount() >= 3 && Environment.GetArg(1) == "cliente")
        {
            Client(Environment.GetArg(2).ToInt());
            return;
        }
        TcpListener server = new TcpListener(IPAddress.Loopback, 0);
        if (!server.Start())
        {
            Console.WriteLine(server.ErrorMessage);
            return;
        }
        int port = server.LocalEndPoint.Port;
        StringBuilder cmd = new StringBuilder();
        cmd.Append("'").Append(Environment.GetArg(0)).Append("' cliente ").Append((long)port);
        ChildProcess child = new ChildProcess();
        if (!child.Start(cmd.View(), ""))
        {
            Console.WriteLine("no se pudo lanzar el cliente");
            return;
        }
        delete cmd;
        for (int i = 0; i < Conexiones; i++) Serve(server);

        StringBuilder output = new StringBuilder();
        long deadline = Time.TickMs() + 15000;
        while (!child.HasExited && Time.TickMs() < deadline)
        {
            child.ReadAvailable(output);
            Time.Sleep(5);
        }
        child.ReadAvailable(output);
        Console.WriteLine("--- cliente ---");
        Console.Write(output.View());
        Console.Write("código de salida del cliente: ");
        Console.WriteLine(child.ExitCode);
        delete output;
        delete child;
        delete server;
    }
}
