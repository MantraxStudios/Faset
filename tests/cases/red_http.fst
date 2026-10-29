// HttpClient de extremo a extremo sin internet: el programa abre un servidor en
// 127.0.0.1 y se lanza a sí mismo como proceso hijo ("cliente <puerto>"), que hace
// las peticiones con HttpClient. El padre atiende cada conexión y al final muestra
// lo que imprimió el hijo.
using std.net;
using std.text;
using std.os;
using std.time;

static class Program
{
    // ---------------------------------------------------------------- cliente (proceso hijo)

    static void Show(HttpClient http, HttpResponse r)
    {
        if (r == null)
        {
            Console.Write("error: ");
            Console.WriteLine(http.ErrorMessage);
            return;
        }
        Console.Write(r.StatusCode);
        Console.Write(" ");
        Console.Write(r.ReasonPhrase);
        Console.Write(" | X-Prueba=");
        Console.Write(r.Headers.Get("X-Prueba"));
        Console.Write(" | cuerpo=[");
        Console.Write(r.Body);
        Console.WriteLine("]");
        delete r;
    }

    static void Client(int port)
    {
        HttpClient http = new HttpClient();
        http.Timeout = 10000;
        http.DefaultHeaders.Add("X-Cliente", "faset");
        string base1 = String.Concat("http://127.0.0.1:", Environment.GetArg(2), "/inicio");
        string base2 = String.Concat("http://localhost:", Environment.GetArg(2), "/datos");
        Show(http, http.Get(base1));
        Show(http, http.Post(base2, "a=1&b=dos", "application/x-www-form-urlencoded"));
        Show(http, http.Get(base1));
        http.FollowRedirects = false;
        Show(http, http.Get(base1));
        String.Free(base1);
        String.Free(base2);
        delete http;
    }

    // ---------------------------------------------------------------- servidor (proceso padre)

    // Lee una petición y muestra su línea, sus cabeceras (salvo Host) y su cuerpo.
    static bool ReadRequest(TcpClient c, int port)
    {
        string line;
        if (!c.ReadLine(out line))
        {
            String.Free(line);
            return false;
        }
        Console.WriteLine(String.FromBytes(line.Ptr, line.Length));
        String.Free(line);
        int length = 0;
        while (c.ReadLine(out line))
        {
            if (line.Length == 0)
            {
                String.Free(line);
                break;
            }
            if (line.StartsWith("Host: "))
            {
                string p = String.FromInt(port);
                Console.WriteLine(line.EndsWith(p) && line.Contains(":") ? "  Host: <equipo>:<puerto>" : line);
                String.Free(p);
            }
            else
            {
                Console.Write("  ");
                Console.WriteLine(line);
            }
            if (line.StartsWith("Content-Length: ")) length = line.Substring(16).ToInt();
            String.Free(line);
        }
        if (length > 0)
        {
            byte* body = new byte[length];
            int got = 0;
            while (got < length)
            {
                int n = c.Receive(body + got, length - got);
                if (n <= 0) break;
                got += n;
            }
            Console.Write("  cuerpo: ");
            Console.WriteLine(String.FromBytes(body, got));
            delete[] body;
        }
        return true;
    }

    static void Serve(TcpListener server, int port, string response)
    {
        TcpClient c = server.AcceptTcpClient(15000);
        if (c == null)
        {
            Console.Write("el cliente no se conectó: ");
            Console.WriteLine(server.ErrorMessage);
            return;
        }
        c.ReceiveTimeout = 10000;
        if (!ReadRequest(c, port)) Console.WriteLine("petición vacía");
        c.Write(response);
        delete c;
    }

    static void Main()
    {
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

        // 1) redirección  2) destino, cuerpo chunked
        Serve(server, port, "HTTP/1.1 302 Found\r\nLocation: /final?x=1\r\nContent-Length: 0\r\n\r\n");
        Serve(server, port, "HTTP/1.1 200 OK\r\nX-Prueba: si\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhola \r\n11\r\ndesde el servidor\r\n0\r\n\r\n");
        // 3) POST, respuesta sin longitud (hasta el cierre)
        Serve(server, port, "HTTP/1.0 201 Created\r\nX-Prueba: post\r\n\r\ncreado");
        // 4) respuesta no válida
        Serve(server, port, "esto no es HTTP\r\n\r\n");
        // 5) sin seguir redirecciones
        Serve(server, port, "HTTP/1.1 301 Moved Permanently\r\nLocation: http://127.0.0.1:1/\r\nContent-Length: 4\r\n\r\nfin!");

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
