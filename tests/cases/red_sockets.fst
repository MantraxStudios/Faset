// std.net con sockets reales en 127.0.0.1 (sin hilos: el cliente conecta y el
// servidor acepta después, porque la conexión espera en la cola del sistema).
using std.net;
using std.text;

static class Program
{
    static void Say(string a, string b) { Console.Write(a); Console.WriteLine(b); }
    static void Say(string a, string b, string c) { Console.Write(a); Console.Write(b); Console.WriteLine(c); }

    static void Check(string what, bool ok)
    {
        Console.Write(ok ? "ok    " : "FALLO ");
        Console.WriteLine(what);
    }

    static void Tcp()
    {
        TcpListener server = new TcpListener(IPAddress.Loopback, 0);
        Check("listener en puerto efímero", server.Start());
        int port = server.LocalEndPoint.Port;
        Check("puerto asignado", port > 0);
        Check("sin conexiones pendientes", !server.Pending());

        TcpClient client = new TcpClient();
        client.ReceiveTimeout = 5000;
        Check("connect", client.Connect("127.0.0.1", port, 5000));
        Check("pending", server.Pending(2000));
        TcpClient peer = server.AcceptTcpClient(2000);
        Check("accept", peer != null);
        peer.ReceiveTimeout = 5000;
        Check("extremos", peer.RemoteEndPoint == client.LocalEndPoint && client.RemoteEndPoint.Port == port);
        Check("nodelay", client.SetNoDelay(true));

        // Cliente -> servidor, por líneas.
        Check("write", client.Write("hola servidor\r\nsegunda línea\nsin final"));
        Check("shutdown envío", client.Shutdown(SocketShutdown.Send));
        string line;
        while (peer.ReadLine(out line))
        {
            Say("  servidor leyó: [", line, "]");
            String.Free(line);
        }
        String.Free(line);
        Check("fin de datos sin error", peer.Error == SocketError.Success);

        // Servidor -> cliente, datos binarios y lectura hasta el cierre.
        byte* data = new byte[20000];
        for (int i = 0; i < 20000; i++) data[i] = (byte)(i * 7);
        Check("write binario", peer.Write(data, 20000));
        peer.Close();
        string all = client.ReadToEnd();
        bool same = all.Length == 20000;
        for (int i = 0; same && i < 20000; i++) same = all[i] == data[i];
        Check("20000 bytes recibidos intactos", same);
        String.Free(all);
        delete[] data;
        delete peer;
        delete client;

        // Tiempo de espera al recibir.
        TcpClient c2 = new TcpClient();
        c2.Connect(new IPEndPoint(IPAddress.Loopback, port), 2000);
        TcpClient p2 = server.AcceptTcpClient(2000);
        c2.ReceiveTimeout = 50;
        byte* buf = new byte[16];
        Check("receive con tiempo agotado", c2.Receive(buf, 16) == -1 && c2.Error == SocketError.TimedOut);
        p2.Write("x");
        Check("receive tras el tiempo agotado", c2.Receive(buf, 16) == 1 && buf[0] == 'x');
        delete[] buf;
        delete p2;
        delete c2;

        // Accept no bloqueante y con tiempo de espera.
        Check("accept con tiempo agotado", server.AcceptTcpClient(30) == null && server.Error == SocketError.TimedOut);
        server.Server.Blocking = false;
        Check("accept no bloqueante", server.AcceptSocket() == null && server.Error == SocketError.WouldBlock);

        // Connect no bloqueante + Poll.
        Socket s = new Socket(AddressFamily.InterNetwork, SocketType.Stream);
        s.Blocking = false;
        bool immediate = s.Connect(new IPEndPoint(IPAddress.Loopback, port));
        Check("connect no bloqueante en curso", immediate || s.Error == SocketError.InProgress);
        Check("poll de escritura", s.Poll(2000, SelectMode.Write) && s.FinishConnect());
        Check("poll de lectura sin datos", !s.Poll(0, SelectMode.Read));
        byte* nb = new byte[4];
        Check("receive no bloqueante", s.Receive(nb, 4) == -1 && s.Error == SocketError.WouldBlock);
        delete[] nb;
        Check("aceptar la conexión no bloqueante", server.Pending(2000));
        Socket accepted = server.AcceptSocket();
        Check("socket aceptado es bloqueante", accepted != null && accepted.Blocking);
        accepted.SendAll("ping");
        Check("datos disponibles", s.Poll(2000, SelectMode.Read) && s.Available == 4);
        delete accepted;
        delete s;

        server.Stop();
        delete server;

        // Puerto cerrado: conexión rechazada.
        TcpClient c3 = new TcpClient();
        Check("conexión rechazada", !c3.Connect("127.0.0.1", port, 2000) && c3.Error == SocketError.ConnectionRefused);
        Say("  mensaje: ", c3.ErrorMessage);
        delete c3;

        // Puerto en uso.
        TcpListener a = new TcpListener(IPAddress.Loopback, 0);
        a.Start();
        TcpListener b = new TcpListener(a.LocalEndPoint);
        Check("dirección en uso", !b.Start() && b.Error == SocketError.AddressInUse);
        delete a;
        delete b;
    }

    static void Udp()
    {
        UdpClient rx = new UdpClient();
        Check("udp bind", rx.Bind(new IPEndPoint(IPAddress.Loopback, 0)));
        IPEndPoint rxEp = rx.LocalEndPoint;
        UdpClient tx = new UdpClient();
        tx.Bind(new IPEndPoint(IPAddress.Loopback, 0));
        Check("udp send", tx.Send("datagrama 1", rxEp) == 11);
        Check("udp send 2", tx.Send("otro", rxEp) == 4);
        rx.ReceiveTimeout = 2000;
        string text;
        IPEndPoint from;
        Check("udp receive", rx.Receive(out text, out from));
        Say("  recibido: ", text);
        Check("udp remitente", from == tx.LocalEndPoint);
        String.Free(text);
        byte* buf = new byte[2];
        Check("udp datagrama truncado", rx.Receive(buf, 2, out from) == 2 && buf[0] == 'o');
        delete[] buf;
        rx.ReceiveTimeout = 30;
        Check("udp tiempo agotado", !rx.Receive(out text, out from) && rx.Error == SocketError.TimedOut);
        String.Free(text);
        delete rx;
        delete tx;
    }

    static void IPv6()
    {
        // Algunas máquinas (contenedores) no tienen IPv6: en ese caso solo se comprueba el error.
        TcpListener server = new TcpListener(IPAddress.IPv6Loopback, 0);
        if (!server.Start())
        {
            Check("ipv6", server.Error == SocketError.AddressNotAvailable || server.Error == SocketError.Unsupported);
            delete server;
            return;
        }
        TcpClient c = new TcpClient();
        bool ok = c.Connect("::1", server.LocalEndPoint.Port, 2000);
        TcpClient p = server.AcceptTcpClient(2000);
        ok = ok && p != null && c.Write("v6") && p.RemoteEndPoint.Address.IsIPv6;
        Check("ipv6", ok);
        if (p != null) delete p;
        delete c;
        delete server;
    }

    static void Main()
    {
        Tcp();
        Udp();
        IPv6();
    }
}
