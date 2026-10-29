// std.net sin red: direcciones IP, URL, codificación por porcentajes y análisis HTTP.
using std.net;
using std.text;
using std.collections;

static class Program
{
    static void Say(string a, string b) { Console.Write(a); Console.WriteLine(b); }
    static void Say(string a, string b, string c) { Console.Write(a); Console.Write(b); Console.WriteLine(c); }

    static void Ip(string text)
    {
        IPAddress a;
        if (!IPAddress.TryParse(text, out a))
        {
            Say(text, " -> no válida");
            return;
        }
        string s = a.ToString();
        Console.Write(text);
        Console.Write(" -> ");
        Console.Write(s);
        Console.Write(a.IsIPv6 ? " (v6" : " (v4");
        if (a.IsLoopback) Console.Write(", loopback");
        Console.WriteLine(")");
        String.Free(s);
    }

    static void Url(string text)
    {
        Uri u = Uri.Parse(text);
        if (u == null)
        {
            Say(text, " -> no válida");
            return;
        }
        StringBuilder sb = new StringBuilder();
        sb.Append(text).Append("\n  scheme=").Append(u.Scheme).Append(" user=").Append(u.UserInfo);
        sb.Append(" host=").Append(u.Host).Append(" port=").Append((long)u.Port);
        sb.Append(" path=").Append(u.Path).Append(" query=").Append(u.Query).Append(" frag=").Append(u.Fragment);
        string pq = u.PathAndQuery();
        string auth = u.Authority();
        sb.Append("\n  pathAndQuery=").Append(pq).Append(" authority=").Append(auth);
        Console.WriteLine(sb.View());
        String.Free(pq);
        String.Free(auth);
        delete sb;
        delete u;
    }

    static void Resolve(string baseUrl, string reference)
    {
        Uri u = Uri.Parse(baseUrl);
        string r = u.Resolve(reference);
        Say(reference, " => ", r);
        String.Free(r);
        delete u;
    }

    static void Show(HttpResponse r)
    {
        if (r == null)
        {
            Console.WriteLine("respuesta: null");
            return;
        }
        Console.Write("respuesta: ");
        Console.Write(r.StatusCode);
        Console.Write(" [");
        Console.Write(r.ReasonPhrase);
        Console.Write("] ");
        Console.Write(r.Version);
        Console.Write(" cabeceras=");
        Console.Write(r.Headers.Count);
        Console.Write(" cuerpo=[");
        Console.Write(r.Body);
        Console.WriteLine("]");
        delete r;
    }

    static void Main()
    {
        // ---- IPv4
        Ip("192.168.1.20");
        Ip("127.0.0.1");
        Ip("0.0.0.0");
        Ip("255.255.255.255");
        Ip("256.1.1.1");
        Ip("1.2.3");
        Ip("1.2.3.4.5");
        Ip("01.2.3.4");
        Ip("1..2.3");
        Ip("");
        // ---- IPv6
        Ip("::1");
        Ip("::");
        Ip("2001:0db8:0000:0000:0000:ff00:0042:8329");
        Ip("2001:db8::1:0:0:1");
        Ip("2001:db8:0:0:1:0:0:1");
        Ip("fe80::1%3");
        Ip("[::ffff:192.0.2.128]");
        Ip("::ffff:127.0.0.1");
        Ip("1:2:3:4:5:6:7:8");
        Ip("1::");
        Ip("1:2:3:4:5:6:7::");
        Ip("::1.2.3.4");
        Ip("1:2:3:4:5:6:7:8:9");
        Ip("1:::2");
        Ip("1::2::3");
        Ip("12345::");
        Ip("g::1");
        Ip(":1::2");
        Ip("[1.2.3.4]");

        IPAddress a = IPAddress.V4(10, 0, 0, 7);
        Console.WriteLine(a == IPAddress.Parse("10.0.0.7"));
        Console.WriteLine(a != IPAddress.Loopback);
        Console.WriteLine(a.GetByte(3));
        IPAddress m = a.MapToIPv6();
        string ms = m.ToString();
        Console.WriteLine(ms);
        String.Free(ms);
        Console.WriteLine(m.MapToIPv4() == a);
        Console.WriteLine(IPAddress.IPv6Loopback.IsLoopback);

        IPEndPoint ep;
        Console.WriteLine(IPEndPoint.TryParse("[2001:db8::5]:8080", out ep));
        string eps = ep.ToString();
        Console.WriteLine(eps);
        String.Free(eps);
        Console.WriteLine(IPEndPoint.TryParse("1.2.3.4:65536", out ep));
        Console.WriteLine(IPEndPoint.TryParse("1.2.3.4:443", out ep) && ep.Port == 443);

        // ---- DNS sin red: literales y localhost
        List<IPAddress> lista = new List<IPAddress>();
        Console.WriteLine(Dns.GetHostAddresses("127.0.0.1", lista) && lista.Count == 1);
        delete lista;
        IPAddress local;
        Console.WriteLine(Dns.TryResolve("localhost", out local) && local.IsLoopback);
        Console.WriteLine(Dns.TryResolve("nombre.invalid", out local));
        Console.WriteLine(Dns.LastError == SocketError.HostNotFound);
        string hn = Dns.GetHostName();
        Console.WriteLine(hn.Length > 0);
        String.Free(hn);

        // ---- URL
        Url("http://example.com");
        Url("HTTP://Usuario:clave@Example.com:8080/a/b.html?x=1&y=2#arriba");
        Url("https://[2001:db8::1]:8443/ruta");
        Url("http://[::1]/");
        Url("ftp://ftp.example.org/pub/");
        Url("mailto:alguien@example.com");
        Url("http://h?solo=consulta");
        Url("http://host:80/");
        Url("http:///sin-host");
        Url("http://host:99999/");
        Url("http://host:8a/");
        Url("://sin-esquema");
        Url("http://con espacio/");
        Url("http://[::1/");

        Resolve("http://a.com/x/y/z?q=1", "/abs");
        Resolve("http://a.com/x/y/z?q=1", "rel");
        Resolve("http://a.com:8080/x/y", "//otro.com/p");
        Resolve("http://a.com/x", "https://b.com/");
        Resolve("http://a.com/x?q=1", "?r=2");
        Resolve("http://a.com/x?q=1", "#frag");

        string e = Uri.Escape("año 2026/€?&=");
        Console.WriteLine(e);
        string d = Uri.Unescape(e);
        Console.WriteLine(d);
        String.Free(e);
        String.Free(d);
        string f = Uri.UnescapeForm("a+b%20c%zz%4");
        Console.WriteLine(f);
        String.Free(f);
        string v;
        Console.WriteLine(Uri.GetQueryParameter("nombre=Ana+Mar%C3%ADa&edad=30&vacio", "nombre", out v));
        Console.WriteLine(v);
        String.Free(v);
        Console.WriteLine(Uri.GetQueryParameter("nombre=Ana&edad=30&vacio", "vacio", out v) && v.Length == 0);
        String.Free(v);
        Console.WriteLine(Uri.GetQueryParameter("nombre=Ana", "otro", out v));
        String.Free(v);

        // ---- HTTP: respuestas de ejemplo
        Show(HttpResponse.Parse("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nholaXYZ"));
        Show(HttpResponse.Parse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5;ext=1\r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\nX-Trailer: si\r\n\r\n"));
        Show(HttpResponse.Parse("HTTP/1.0 404 Not Found\nServer: prueba\n\nhasta el final"));
        Show(HttpResponse.Parse("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 204 No Content\r\nX-A: 1\r\n\r\n"));
        Show(HttpResponse.Parse("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\ncorto"));
        Show(HttpResponse.Parse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n"));
        Show(HttpResponse.Parse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"));
        Show(HttpResponse.Parse("HTTP/1.1 2x0 Mal\r\n\r\n"));
        Show(HttpResponse.Parse("basura\r\n\r\n"));
        Show(HttpResponse.Parse("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nabcd", true));
        Show(HttpResponse.Parse("HTTP/1.1 301 Moved Permanently\r\nLocation: /nuevo\r\nX-Larga: uno\r\n  dos\r\nContent-Length: 0\r\n\r\n"));

        HttpResponse h = HttpResponse.Parse("HTTP/1.1 200 OK\r\ncontent-type: text/html; charset=utf-8\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nContent-Length: 0\r\n\r\n");
        Console.WriteLine(h.ContentType);
        Console.WriteLine(h.Headers.Get("SET-COOKIE"));
        Console.WriteLine(h.Headers.ValueAt(2));
        Console.WriteLine(h.Headers.Contains("x-falta"));
        Console.WriteLine(h.IsSuccess);
        delete h;

        string body;
        Console.WriteLine(HttpResponse.DecodeChunked("3\r\nabc\r\n0\r\n\r\n", out body));
        Console.WriteLine(body);
        String.Free(body);

        // Lector incremental: los datos llegan en trozos.
        HttpResponseReader reader = new HttpResponseReader(false);
        Console.WriteLine(reader.Feed("HTTP/1.1 200 OK\r\nTransfer-Enc"));
        Console.WriteLine(reader.Feed("oding: chunked\r\n\r\n3\r\nab"));
        Console.WriteLine(reader.Feed("c\r\n2\r\nde\r\n0\r\n"));
        Console.WriteLine(reader.Feed("\r\n"));
        Show(reader.Take());
        delete reader;

        // Petición generada
        Uri u = Uri.Parse("http://[::1]:8080/api/v1?x=%20y");
        HttpHeaders hs = new HttpHeaders();
        hs.Add("User-Agent", "prueba");
        hs.Add("Content-Type", "application/json");
        hs.Set("content-type", "text/plain");
        string wire = HttpClient.BuildRequest("POST", u, hs, "{}");
        string shown = Text.Replace(wire, "\r\n", "|\n");
        Console.Write(shown);
        String.Free(shown);
        Console.WriteLine();
        String.Free(wire);
        delete hs;
        delete u;

        HttpClient http = new HttpClient();
        Show(http.Get("ftp://example.com/"));
        Console.WriteLine(http.ErrorMessage);
        Show(http.Get("no es una url"));
        Console.WriteLine(http.Error == SocketError.InvalidUrl);
        delete http;
    }
}
