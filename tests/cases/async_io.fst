// E/S asíncrona: File.ReadAllTextAsync / WriteAllTextAsync, HttpClient.GetStringAsync / GetAsync /
// PostAsync y TcpClient.ConnectAsync / WriteAsync / ReadToEndAsync contra un servidor en 127.0.0.1
// del propio programa (sin internet).
using std;
using std.io;
using std.net;
using std.task;
using std.text;

public static class Program
{
    // Atiende 'n' conexiones: lee la petición hasta la línea vacía (y el cuerpo) y responde.
    static void Servidor(TcpListener server, int n)
    {
        for (int i = 0; i < n; i++)
        {
            TcpClient c = server.AcceptTcpClient(15000);
            if (c == null) return;
            c.ReceiveTimeout = 10000;
            string line;
            string first = "";
            int length = 0;
            bool any = false;
            while (c.ReadLine(out line))
            {
                if (!any) first = line;
                any = true;
                if (line.Length == 0) break;
                if (line.StartsWith("Content-Length: ")) length = line.Substring(16).ToInt();
            }
            StringBuilder body = new StringBuilder();
            while (body.Length < length && c.Read(body) > 0) { }
            string resp;
            if (first.StartsWith("ECO")) resp = "eco: " + first;
            else if (first.StartsWith("GET /falta")) resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            else
            {
                string cuerpo = first.StartsWith("POST") ? "recibido " + body.ToString() : "hola desde " + first.Substring(4, 6);
                resp = "HTTP/1.1 200 OK\r\nContent-Length: " + cuerpo.Length + "\r\nConnection: close\r\n\r\n" + cuerpo;
            }
            c.Write(resp);
            delete c;
        }
    }

    static async Task<int> Main()
    {
        // archivos
        string ruta = Path.Combine(Path.GetTempPath(), "faset_async_io.txt");
        await File.WriteAllTextAsync(ruta, "línea 1\n");
        await File.AppendAllTextAsync(ruta, "línea 2\n");
        string leido = await File.ReadAllTextAsync(ruta);
        Console.Write("archivo: " + leido);
        File.Delete(ruta);
        try
        {
            await File.ReadAllTextAsync(ruta);
        }
        catch (FileNotFoundException e)
        {
            Console.WriteLine("no existe: FileNotFoundException");
        }

        // red
        TcpListener server = new TcpListener(IPAddress.Loopback, 0);
        if (!server.Start())
        {
            Console.WriteLine("sin red: " + server.ErrorMessage);
            return 77;
        }
        int port = server.LocalEndPoint.Port;
        Task atiende = Task.Run(() => Servidor(server, 5));
        string base1 = "http://127.0.0.1:" + port;
        HttpClient http = new HttpClient();
        http.Timeout = 10000;
        Console.WriteLine("GetStringAsync: " + await http.GetStringAsync(base1 + "/datos"));
        HttpResponse r = await http.PostAsync(base1 + "/enviar", "a=1", "text/plain");
        Console.WriteLine("PostAsync: " + r.StatusCode + " " + r.Body);
        HttpResponse r2 = await http.GetAsync(base1 + "/falta");
        Console.WriteLine("GetAsync: " + r2.StatusCode);
        try
        {
            await http.GetStringAsync(base1 + "/falta");
        }
        catch (HttpRequestException e)
        {
            Console.WriteLine("GetStringAsync 404: HttpRequestException " + e.StatusCode);
        }
        TcpClient tcp = new TcpClient();
        bool ok = await tcp.ConnectAsync("127.0.0.1", port);
        await tcp.WriteAsync("ECO uno\r\n\r\n");
        Console.WriteLine("TcpClient: " + ok + " " + await tcp.ReadToEndAsync());
        delete tcp;
        await atiende;
        server.Stop();
        return 0;
    }
}
