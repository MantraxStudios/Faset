// std.time: TimeSpan, DateTime (componentes, aritmética, ISO-8601, formatos), Stopwatch.
using std.time;

void Mostrar(string s)
{
    println(s);
    String.Free(s);
}

int main()
{
    // ---- TimeSpan
    TimeSpan a = new TimeSpan(1, 2, 3, 4, 500);
    Mostrar(a.ToString());
    println(a.Days);
    println(a.Hours);
    println(a.Minutes);
    println(a.Seconds);
    println(a.Milliseconds);
    println(a.TotalHours);
    TimeSpan b = TimeSpan.FromMinutes(90);
    Mostrar((a - b).ToString());
    Mostrar((-b).ToString());
    Mostrar((b * 2.5).ToString());
    Mostrar(TimeSpan.FromMilliseconds(0.25).ToString());
    println(b < a);
    println(b == TimeSpan.FromHours(1.5));
    println(TimeSpan.Zero.Ticks);

    // ---- DateTime: componentes
    DateTime d = new DateTime(2024, 2, 29, 13, 45, 30, 250);
    println(d.Year);
    println(d.Month);
    println(d.Day);
    println(d.Hour);
    println(d.Minute);
    println(d.Second);
    println(d.Millisecond);
    println((int)d.DayOfWeek);       // jueves = 4
    println(d.DayOfYear);
    println(d.Ticks);
    Mostrar(d.ToString());
    Mostrar(d.ToIsoString());
    Mostrar(d.TimeOfDay.ToString());
    Mostrar(d.Date.ToString());

    // ---- aritmética
    Mostrar(d.AddDays(1).ToString());
    Mostrar(d.AddYears(1).ToString());          // 2025-02-28
    Mostrar(d.AddMonths(-1).ToString());        // 2024-01-29
    Mostrar(new DateTime(2024, 1, 31).AddMonths(1).ToString("yyyy-MM-dd"));
    Mostrar(d.AddHours(-14).ToString());
    Mostrar((d + TimeSpan.FromSeconds(30)).ToString());
    DateTime e = new DateTime(2000, 1, 1);
    TimeSpan dif = d - e;
    println(dif.Days);
    Mostrar(dif.ToString());
    println(d > e);
    println(d.CompareTo(e));
    println(new DateTime(1, 1, 1).Ticks);
    println((int)new DateTime(1, 1, 1).DayOfWeek);   // lunes
    println((int)new DateTime(1970, 1, 1).DayOfWeek); // jueves
    println(DateTime.IsLeapYear(1900));
    println(DateTime.IsLeapYear(2000));
    println(DateTime.DaysInMonth(2023, 2));

    // ---- Unix
    DateTime u = DateTime.FromUnixSeconds(1700000000);
    Mostrar(u.ToIsoString());
    println(u.ToUnixSeconds());
    println(DateTime.FromUnixMs(-1).ToUnixMs());
    Mostrar(DateTime.FromUnixMs(-1).ToIsoString());
    println(DateTime.UnixEpoch.Ticks == DateTime.UnixEpochTicks);

    // ---- formatos propios
    Mostrar(d.ToString("dd/MM/yyyy HH:mm"));
    Mostrar(d.ToString("dddd, d 'de' MMMM 'de' yyyy"));
    Mostrar(d.ToString("ddd MMM d yy h:mm:ss tt"));
    Mostrar(d.ToString("HH\\h mm\\m ss.fff"));
    Mostrar(u.ToString("yyyy-MM-ddTHH:mm:sszzz"));
    Mostrar(new DateTime(2024, 1, 5, 0, 7, 9).ToString("h:m:s t"));

    // ---- ISO-8601: lectura
    DateTime p = new DateTime(0);
    println(DateTime.TryParseIso("2024-02-29T13:45:30.250Z", out p));
    Mostrar(p.ToIsoString());
    println(p == d);
    println(p.Kind == DateTimeKind.Utc);
    println(DateTime.TryParseIso("2024-02-29T15:45:30+02:00", out p));
    Mostrar(p.ToIsoString());
    println(DateTime.TryParseIso("2024-02-29 08:15", out p));
    Mostrar(p.ToIsoString());
    println(p.Kind == DateTimeKind.Unspecified);
    println(DateTime.TryParseIso("1999-12-31", out p));
    Mostrar(p.ToString());
    println(DateTime.TryParseIso("2023-02-29", out p));      // no existe
    println(DateTime.TryParseIso("2024-13-01", out p));
    println(DateTime.TryParseIso("2024-01-01T10:00:00Zx", out p));
    println(DateTime.TryParseIso("2024-01-01T10:00:00.1234567-0530", out p));
    Mostrar(p.ToIsoString());
    Mostrar(DateTime.ParseIso("  2020-06-15T12:00:00Z ").ToString("yyyy-MM-dd HH:mm:ss K"));

    // ---- lectura con formato
    println(DateTime.TryParseExact("29/02/2024 13:45", "dd/MM/yyyy HH:mm", out p));
    Mostrar(p.ToString());
    println(DateTime.TryParseExact("7 Mar 2021 9:05 PM", "d MMM yyyy h:mm tt", out p));
    Mostrar(p.ToString());
    println(DateTime.TryParseExact("2021-03-07", "dd/MM/yyyy", out p));
    println(DateTime.TryParseExact("20210307-081500.5", "yyyyMMdd-HHmmss.f", out p));
    Mostrar(p.ToIsoString());

    // ---- zona horaria: Local <-> UTC (con TZ=UTC el desfase es cero)
    DateTime local = d.WithKind(DateTimeKind.Local);
    DateTime utc = local.ToUniversalTime();
    println((local - utc).Ticks == TimeZone.OffsetAt(utc).Ticks);
    println(utc.ToLocalTime() == local);
    println(local.ToUnixSeconds() == utc.ToUnixSeconds());

    // ---- relojes (sin salida dependiente del momento)
    DateTime ahora = DateTime.UtcNow;
    println(ahora.Year >= 2024);
    println(Math.Abs(ahora.ToUnixMs() - Time.NowUnixMs()) < 5000);
    DateTime ahoraLocal = DateTime.Now;
    println(Math.Abs((ahoraLocal - ahora).Ticks - TimeZone.LocalOffset.Ticks) < TimeSpan.TicksPerSecond * 5);
    println(DateTime.Today.Hour);

    Stopwatch sw = Stopwatch.StartNew();
    Time.Sleep(20);
    sw.Stop();
    long ms = sw.ElapsedMs;
    println(ms >= 19 && ms < 2000);
    println(sw.ElapsedNs >= 19000000);
    println(sw.Elapsed.TotalMilliseconds >= 19.0);
    println(sw.IsRunning);
    sw.Reset();
    println(sw.ElapsedNs);
    long t0 = Time.TickNs();
    println(Time.TickNs() >= t0);
    return 0;
}
