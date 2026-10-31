// =============================================================================
//  std.time  —  reloj, pausas, cronómetro, fechas y duraciones.
//
//    Time        TickMs/TickNs (monótonos), NowUnixMs, Sleep, zona horaria local
//    TimeSpan    duración con precisión de 100 ns (como en C#)
//    DateTime    fecha y hora (año 1 a 9999), UTC, local o sin especificar;
//                componentes, aritmética, día de la semana, ISO-8601 y
//                formatos propios ("yyyy-MM-dd HH:mm:ss")
//    TimeZone    desfase de la hora local respecto a UTC
//    Stopwatch   cronómetro de alta resolución (reloj monótono en ns)
//
//  Las funciones que devuelven 'string' (ToString, ToIsoString…) reservan
//  memoria
// =============================================================================
using std.text;

namespace std.time
{
    static extern long faset_ticks_ms();
    static extern long faset_ticks_ns();
    static extern long faset_time_unix_ms();
    static extern long faset_time_unix_ns();
    static extern void faset_sleep_ms(long ms);
    static extern int faset_tz_offset_sec(long unixSeconds);

    public memory_unsafe static class Time
    {
        // Milisegundos desde un punto arbitrario (monótono: para medir intervalos).
        public static func TickMs() -> long => faset_ticks_ms();
        // Nanosegundos desde un punto arbitrario (monótono, alta resolución).
        public static func TickNs() -> long => faset_ticks_ns();
        // Milisegundos desde 1970-01-01 UTC.
        public static func NowUnixMs() -> long => faset_time_unix_ms();
        public static func NowUnixSeconds() -> long => faset_time_unix_ms() / 1000;
        // Nanosegundos desde 1970-01-01 UTC (la precisión real depende del sistema).
        public static func NowUnixNs() -> long => faset_time_unix_ns();
        public static func Sleep(milliseconds: long) { faset_sleep_ms(milliseconds); }
        public static func Sleep(duration: TimeSpan) { faset_sleep_ms(duration.Ticks / TimeSpan.TicksPerMillisecond); }
        // Desfase actual de la hora local respecto a UTC, en segundos (p. ej. 3600 para UTC+1).
        public static func LocalOffsetSeconds() -> int => faset_tz_offset_sec(faset_time_unix_ms() / 1000);
    }

    // ---------------------------------------------------------------- TimeSpan
    // Duración (puede ser negativa) en ticks de 100 ns.
    public struct TimeSpan
    {
        public const long TicksPerMicrosecond = 10;
        public const long TicksPerMillisecond = 10000;
        public const long TicksPerSecond = 10000000;
        public const long TicksPerMinute = 600000000;
        public const long TicksPerHour = 36000000000;
        public const long TicksPerDay = 864000000000;

        var ticks: long;

        public init(ticks: long) { this.ticks = ticks; }
        public init(hours: int, minutes: int, seconds: int)
        {
            ticks = hours * TicksPerHour + minutes * TicksPerMinute + seconds * TicksPerSecond;
        }
        public init(days: int, hours: int, minutes: int, seconds: int)
        {
            ticks = days * TicksPerDay + hours * TicksPerHour + minutes * TicksPerMinute + seconds * TicksPerSecond;
        }
        public init(days: int, hours: int, minutes: int, seconds: int, milliseconds: int)
        {
            ticks = days * TicksPerDay + hours * TicksPerHour + minutes * TicksPerMinute + seconds * TicksPerSecond +
                    milliseconds * TicksPerMillisecond;
        }

        public static prop Zero: TimeSpan => new TimeSpan(0);
        public static func FromTicks(ticks: long) -> TimeSpan => new TimeSpan(ticks);
        public static func FromDays(v: double) -> TimeSpan => new TimeSpan(Round(v * TicksPerDay));
        public static func FromHours(v: double) -> TimeSpan => new TimeSpan(Round(v * TicksPerHour));
        public static func FromMinutes(v: double) -> TimeSpan => new TimeSpan(Round(v * TicksPerMinute));
        public static func FromSeconds(v: double) -> TimeSpan => new TimeSpan(Round(v * TicksPerSecond));
        public static func FromMilliseconds(v: double) -> TimeSpan => new TimeSpan(Round(v * TicksPerMillisecond));
        public static func FromMicroseconds(v: double) -> TimeSpan => new TimeSpan(Round(v * TicksPerMicrosecond));

        static func Round(v: double) -> long => (long)(v >= 0 ? v + 0.5 : v - 0.5);

        public prop Ticks: long => ticks;
        // Componentes (con el signo de la duración).
        public prop Days: int => (int)(ticks / TicksPerDay);
        public prop Hours: int => (int)(ticks / TicksPerHour % 24);
        public prop Minutes: int => (int)(ticks / TicksPerMinute % 60);
        public prop Seconds: int => (int)(ticks / TicksPerSecond % 60);
        public prop Milliseconds: int => (int)(ticks / TicksPerMillisecond % 1000);
        // Totales en la unidad indicada.
        public prop TotalDays: double => (double)ticks / TicksPerDay;
        public prop TotalHours: double => (double)ticks / TicksPerHour;
        public prop TotalMinutes: double => (double)ticks / TicksPerMinute;
        public prop TotalSeconds: double => (double)ticks / TicksPerSecond;
        public prop TotalMilliseconds: double => (double)ticks / TicksPerMillisecond;
        public prop TotalMillisecondsLong: long => ticks / TicksPerMillisecond;

        public func Add(o: TimeSpan) -> TimeSpan => new TimeSpan(ticks + o.ticks);
        public func Subtract(o: TimeSpan) -> TimeSpan => new TimeSpan(ticks - o.ticks);
        public func Negate() -> TimeSpan => new TimeSpan(-ticks);
        public func Duration() -> TimeSpan => new TimeSpan(ticks < 0 ? -ticks : ticks);
        public func CompareTo(o: TimeSpan) -> int => ticks < o.ticks ? -1 : (ticks > o.ticks ? 1 : 0);

        public operator +(a: TimeSpan, b: TimeSpan) -> TimeSpan => new TimeSpan(a.ticks + b.ticks);
        public operator -(a: TimeSpan, b: TimeSpan) -> TimeSpan => new TimeSpan(a.ticks - b.ticks);
        public operator -(a: TimeSpan) -> TimeSpan => new TimeSpan(-a.ticks);
        public operator *(a: TimeSpan, k: double) -> TimeSpan => new TimeSpan(Round(a.ticks * k));
        public operator /(a: TimeSpan, k: double) -> TimeSpan => new TimeSpan(Round(a.ticks / k));
        public operator ==(a: TimeSpan, b: TimeSpan) -> bool => a.ticks == b.ticks;
        public operator !=(a: TimeSpan, b: TimeSpan) -> bool => a.ticks != b.ticks;
        public operator <(a: TimeSpan, b: TimeSpan) -> bool => a.ticks < b.ticks;
        public operator >(a: TimeSpan, b: TimeSpan) -> bool => a.ticks > b.ticks;
        public operator <=(a: TimeSpan, b: TimeSpan) -> bool => a.ticks <= b.ticks;
        public operator >=(a: TimeSpan, b: TimeSpan) -> bool => a.ticks >= b.ticks;

        // "[-][d.]hh:mm:ss[.fffffff]" (como el formato "c" de C#).
        public func ToString() -> string
        {
            StringBuilder sb = new StringBuilder();
            long t = ticks;
            if (t < 0)
            {
                sb.Append('-');
                t = -t;
            }
            long days = t / TicksPerDay;
            if (days > 0)
            {
                sb.Append(days);
                sb.Append('.');
            }
            DateFormat.Pad(sb, t / TicksPerHour % 24, 2);
            sb.Append(':');
            DateFormat.Pad(sb, t / TicksPerMinute % 60, 2);
            sb.Append(':');
            DateFormat.Pad(sb, t / TicksPerSecond % 60, 2);
            long frac = t % TicksPerSecond;
            if (frac != 0)
            {
                sb.Append('.');
                DateFormat.Pad(sb, frac, 7);
            }
            string s = sb.ToString();
            delete sb;
            return s;
        }
    }

    // ---------------------------------------------------------------- DateTime
    public enum DateTimeKind { Unspecified, Utc, Local }
    public enum DayOfWeek { Sunday, Monday, Tuesday, Wednesday, Thursday, Friday, Saturday }

    // Fecha y hora como ticks de 100 ns desde 0001-01-01 00:00:00 (compatible con C#).
    //   DateTime d = new DateTime(2024, 2, 29, 13, 45, 0);
    //   DateTime manana = d.AddDays(1);
    //   TimeSpan dif = manana - d;
    //   string s = d.ToString("yyyy-MM-dd HH:mm:ss");   //
    public memory_unsafe struct DateTime
    {
        public const long MinTicks = 0;
        public const long MaxTicks = 3155378975999999999;     // 9999-12-31 23:59:59.9999999
        public const long UnixEpochTicks = 621355968000000000; // 1970-01-01
        const long DaysTo1970 = 719162;

        var ticks: long;
        var kind: DateTimeKind;

        public init(ticks: long) { Init(ticks, DateTimeKind.Unspecified); }
        public init(ticks: long, kind: DateTimeKind) { Init(ticks, kind); }
        public init(year: int, month: int, day: int) { InitDate(year, month, day, 0, 0, 0, 0, DateTimeKind.Unspecified); }
        public init(year: int, month: int, day: int, hour: int, minute: int, second: int)
        {
            InitDate(year, month, day, hour, minute, second, 0, DateTimeKind.Unspecified);
        }
        public init(year: int, month: int, day: int, hour: int, minute: int, second: int, millisecond: int)
        {
            InitDate(year, month, day, hour, minute, second, millisecond, DateTimeKind.Unspecified);
        }
        public init(year: int, month: int, day: int, hour: int, minute: int, second: int, millisecond: int, kind: DateTimeKind)
        {
            InitDate(year, month, day, hour, minute, second, millisecond, kind);
        }

        func Init(t: long, k: DateTimeKind)
        {
            if (t < MinTicks || t > MaxTicks) throw new ArgumentOutOfRangeException("DateTime: fuera del intervalo 0001-9999", null);
            ticks = t;
            kind = k;
        }

        func InitDate(year: int, month: int, day: int, hour: int, minute: int, second: int, ms: int, k: DateTimeKind)
        {
            if (!IsValid(year, month, day, hour, minute, second, ms)) throw new ArgumentOutOfRangeException("DateTime: fecha u hora no válida", null);
            Init(DateTicks(year, month, day) + hour * TimeSpan.TicksPerHour + minute * TimeSpan.TicksPerMinute +
                     second * TimeSpan.TicksPerSecond + ms * TimeSpan.TicksPerMillisecond, k);
        }

        // ------------------------------------------------ calendario (gregoriano proléptico)
        public static func IsLeapYear(year: int) -> bool => (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;

        public static func DaysInMonth(year: int, month: int) -> int
        {
            if (month == 2) return IsLeapYear(year) ? 29 : 28;
            if (month == 4 || month == 6 || month == 9 || month == 11) return 30;
            return 31;
        }

        public static func IsValid(year: int, month: int, day: int, hour: int, minute: int, second: int, ms: int) -> bool
        {
            if (year < 1 || year > 9999 || month < 1 || month > 12) return false;
            if (day < 1 || day > DaysInMonth(year, month)) return false;
            return hour >= 0 && hour < 24 && minute >= 0 && minute < 60 && second >= 0 && second < 60 && ms >= 0 && ms < 1000;
        }

        // Días desde 1970-01-01 (algoritmo de H. Hinnant).
        static func DaysFromCivil(y: long, m: long, d: long) -> long
        {
            if (m <= 2) y--;
            long era = (y >= 0 ? y : y - 399) / 400;
            long yoe = y - era * 400;
            long doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
            long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
            return era * 146097 + doe - 719468;
        }

        static func DateTicks(year: int, month: int, day: int) -> long => (DaysFromCivil(year, month, day) + DaysTo1970) * TimeSpan.TicksPerDay;

        // Año, mes y día de los ticks actuales.
        func Civil(out year: int, out month: int, out day: int)
        {
            long z = ticks / TimeSpan.TicksPerDay - DaysTo1970 + 719468;
            long era = (z >= 0 ? z : z - 146096) / 146097;
            long doe = z - era * 146097;
            long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
            long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
            long mp = (5 * doy + 2) / 153;
            long d = doy - (153 * mp + 2) / 5 + 1;
            long m = mp < 10 ? mp + 3 : mp - 9;
            long y = yoe + era * 400 + (m <= 2 ? 1 : 0);
            year = (int)y;
            month = (int)m;
            day = (int)d;
        }

        // ------------------------------------------------ instantes
        public static prop UtcNow: DateTime => new DateTime(UnixEpochTicks + faset_time_unix_ns() / 100, DateTimeKind.Utc);

        public static prop Now: DateTime
        {
            get
            {
                long ns = faset_time_unix_ns();
                long off = faset_tz_offset_sec(ns / 1000000000);
                return new DateTime(UnixEpochTicks + ns / 100 + off * TimeSpan.TicksPerSecond, DateTimeKind.Local);
            }
        }

        public static prop Today: DateTime => Now.Date;
        public static prop UnixEpoch: DateTime => new DateTime(UnixEpochTicks, DateTimeKind.Utc);
        public static prop MinValue: DateTime => new DateTime(MinTicks);
        public static prop MaxValue: DateTime => new DateTime(MaxTicks);

        // ------------------------------------------------ marcas de tiempo Unix (resultado en UTC)
        public static func FromUnixSeconds(seconds: long) -> DateTime => new DateTime(UnixEpochTicks + seconds * TimeSpan.TicksPerSecond, DateTimeKind.Utc);
        public static func FromUnixMs(ms: long) -> DateTime => new DateTime(UnixEpochTicks + ms * TimeSpan.TicksPerMillisecond, DateTimeKind.Utc);

        // Una hora local se convierte antes a UTC; una sin especificar se toma como UTC.
        public func ToUnixSeconds() -> long => FloorDiv(UtcTicks() - UnixEpochTicks, TimeSpan.TicksPerSecond);
        public func ToUnixMs() -> long => FloorDiv(UtcTicks() - UnixEpochTicks, TimeSpan.TicksPerMillisecond);

        static func FloorDiv(a: long, b: long) -> long
        {
            long q = a / b;
            if ((a % b != 0) && ((a < 0) != (b < 0))) q--;
            return q;
        }

        func UtcTicks() -> long => kind == DateTimeKind.Local ? ToUniversalTime().ticks : ticks;

        // ------------------------------------------------ zonas horarias
        // A UTC (una hora sin especificar se considera local, como en C#).
        public func ToUniversalTime() -> DateTime
        {
            if (kind == DateTimeKind.Utc) return this;
            long guess = ticks - TimeZone.OffsetSecondsAt((ticks - UnixEpochTicks) / TimeSpan.TicksPerSecond) * TimeSpan.TicksPerSecond;
            long off = TimeZone.OffsetSecondsAt((guess - UnixEpochTicks) / TimeSpan.TicksPerSecond);
            return new DateTime(Clamp(ticks - off * TimeSpan.TicksPerSecond), DateTimeKind.Utc);
        }

        // A hora local (una hora sin especificar se considera UTC, como en C#).
        public func ToLocalTime() -> DateTime
        {
            if (kind == DateTimeKind.Local) return this;
            long off = TimeZone.OffsetSecondsAt((ticks - UnixEpochTicks) / TimeSpan.TicksPerSecond);
            return new DateTime(Clamp(ticks + off * TimeSpan.TicksPerSecond), DateTimeKind.Local);
        }

        static func Clamp(t: long) -> long => t < MinTicks ? MinTicks : (t > MaxTicks ? MaxTicks : t);

        // Misma fecha y hora con otro tipo (no convierte).
        public func WithKind(k: DateTimeKind) -> DateTime => new DateTime(ticks, k);

        // ------------------------------------------------ componentes
        public prop Ticks: long => ticks;
        public prop Kind: DateTimeKind => kind;

        public prop Year: int
        {
            get
            {
                int y = 0;
                int m = 0;
                int d = 0;
                Civil(out y, out m, out d);
                return y;
            }
        }

        public prop Month: int
        {
            get
            {
                int y = 0;
                int m = 0;
                int d = 0;
                Civil(out y, out m, out d);
                return m;
            }
        }

        public prop Day: int
        {
            get
            {
                int y = 0;
                int m = 0;
                int d = 0;
                Civil(out y, out m, out d);
                return d;
            }
        }

        public prop Hour: int => (int)(ticks / TimeSpan.TicksPerHour % 24);
        public prop Minute: int => (int)(ticks / TimeSpan.TicksPerMinute % 60);
        public prop Second: int => (int)(ticks / TimeSpan.TicksPerSecond % 60);
        public prop Millisecond: int => (int)(ticks / TimeSpan.TicksPerMillisecond % 1000);
        public prop Microsecond: int => (int)(ticks / TimeSpan.TicksPerMicrosecond % 1000);

        // 0001-01-01 fue lunes.
        public prop DayOfWeek: DayOfWeek => (DayOfWeek)(int)((ticks / TimeSpan.TicksPerDay + 1) % 7);

        public prop DayOfYear: int
        {
            get
            {
                int y = 0;
                int m = 0;
                int d = 0;
                Civil(out y, out m, out d);
                return (int)((ticks - DateTicks(y, 1, 1)) / TimeSpan.TicksPerDay) + 1;
            }
        }

        // La fecha a las 00:00:00.
        public prop Date: DateTime => new DateTime(ticks - ticks % TimeSpan.TicksPerDay, kind);
        // Tiempo transcurrido desde medianoche.
        public prop TimeOfDay: TimeSpan => new TimeSpan(ticks % TimeSpan.TicksPerDay);

        // ------------------------------------------------ aritmética
        public func AddTicks(t: long) -> DateTime => new DateTime(ticks + t, kind);
        public func Add(span: TimeSpan) -> DateTime => new DateTime(ticks + span.Ticks, kind);
        public func Subtract(span: TimeSpan) -> DateTime => new DateTime(ticks - span.Ticks, kind);
        public func Subtract(other: DateTime) -> TimeSpan => new TimeSpan(ticks - other.ticks);
        public func AddMilliseconds(v: double) -> DateTime => AddTicks(RoundTicks(v * TimeSpan.TicksPerMillisecond));
        public func AddSeconds(v: double) -> DateTime => AddTicks(RoundTicks(v * TimeSpan.TicksPerSecond));
        public func AddMinutes(v: double) -> DateTime => AddTicks(RoundTicks(v * TimeSpan.TicksPerMinute));
        public func AddHours(v: double) -> DateTime => AddTicks(RoundTicks(v * TimeSpan.TicksPerHour));
        public func AddDays(v: double) -> DateTime => AddTicks(RoundTicks(v * TimeSpan.TicksPerDay));

        static func RoundTicks(v: double) -> long => (long)(v >= 0 ? v + 0.5 : v - 0.5);

        // Suma meses; si el día no existe en el mes de destino se usa el último (31 ene + 1 = 29 feb).
        public func AddMonths(months: int) -> DateTime
        {
            int y = 0;
            int m = 0;
            int d = 0;
            Civil(out y, out m, out d);
            long total = (long)y * 12 + (m - 1) + months;
            if (total < 12 || total >= 120000) throw new ArgumentOutOfRangeException("DateTime.AddMonths: fuera del intervalo 0001-9999", null);
            int ny = (int)(total / 12);
            int nm = (int)(total % 12) + 1;
            int dim = DaysInMonth(ny, nm);
            if (d > dim) d = dim;
            return new DateTime(DateTicks(ny, nm, d) + ticks % TimeSpan.TicksPerDay, kind);
        }

        public func AddYears(years: int) -> DateTime => AddMonths(years * 12);

        public func CompareTo(o: DateTime) -> int => ticks < o.ticks ? -1 : (ticks > o.ticks ? 1 : 0);

        // Las comparaciones usan solo los ticks (como en C#): no convierten zonas horarias.
        public operator ==(a: DateTime, b: DateTime) -> bool => a.ticks == b.ticks;
        public operator !=(a: DateTime, b: DateTime) -> bool => a.ticks != b.ticks;
        public operator <(a: DateTime, b: DateTime) -> bool => a.ticks < b.ticks;
        public operator >(a: DateTime, b: DateTime) -> bool => a.ticks > b.ticks;
        public operator <=(a: DateTime, b: DateTime) -> bool => a.ticks <= b.ticks;
        public operator >=(a: DateTime, b: DateTime) -> bool => a.ticks >= b.ticks;
        public operator +(a: DateTime, b: TimeSpan) -> DateTime => new DateTime(a.ticks + b.Ticks, a.kind);
        public operator -(a: DateTime, b: TimeSpan) -> DateTime => new DateTime(a.ticks - b.Ticks, a.kind);
        public operator -(a: DateTime, b: DateTime) -> TimeSpan => new TimeSpan(a.ticks - b.ticks);

        // ------------------------------------------------ texto
        // "yyyy-MM-dd HH:mm:ss".
        public func ToString() -> string => DateFormat.Format(this, "yyyy-MM-dd HH:mm:ss");

        // Formato propio, como en C#:
        //   yyyy yy  MMMM MMM MM M  dddd ddd dd d  HH H hh h  mm m  ss s
        //   f..fffffff (fracción)  tt t (AM/PM)  zzz zz z (desfase)  K (Z, +hh:mm o nada)
        //   'texto' o "texto" literal, \x carácter literal; el resto se copia tal cual.
        public func ToString(format: string) -> string => DateFormat.Format(this, format);

        // ISO-8601: 2024-02-29T13:45:00Z, 2024-02-29T13:45:00.250+01:00, 2024-02-29T13:45:00
        // (la fracción solo aparece si no es cero).
        public func ToIsoString() -> string
        {
            long frac = ticks % TimeSpan.TicksPerSecond;
            if (frac == 0) return DateFormat.Format(this, "yyyy-MM-ddTHH:mm:ssK");
            if (frac % TimeSpan.TicksPerMillisecond == 0) return DateFormat.Format(this, "yyyy-MM-ddTHH:mm:ss.fffK");
            return DateFormat.Format(this, "yyyy-MM-ddTHH:mm:ss.fffffffK");
        }

        // Lee ISO-8601: "YYYY-MM-DD", "YYYY-MM-DDTHH:MM[:SS[.fracción]]" (también con espacio
        // en lugar de 'T'), seguido opcionalmente de "Z" o de un desfase "+hh:mm" / "+hhmm" / "+hh".
        // Con "Z" o desfase el resultado es UTC; sin ellos, sin especificar.
        public static func TryParseIso(s: string, out result: DateTime) -> bool
        {
            result = new DateTime(0);
            return DateFormat.ParseIso(s.Trim(), out result);
        }

        public static func ParseIso(s: string) -> DateTime
        {
            DateTime d = new DateTime(0);
            if (!TryParseIso(s, out d)) throw new FormatException("DateTime.ParseIso: formato no válido");
            return d;
        }

        // Lee 's' con un formato propio (mismos especificadores que ToString, salvo
        // nombres de días). Todo el texto debe coincidir.
        public static func TryParseExact(s: string, format: string, out result: DateTime) -> bool
        {
            result = new DateTime(0);
            return DateFormat.ParseExact(s, format, out result);
        }

        // Desfase (minutos) que se escribe con 'zzz'/'K': local -> zona local, UTC -> 0.
        public func OffsetMinutes() -> int
        {
            if (kind != DateTimeKind.Local) return 0;
            return TimeZone.OffsetSecondsAt(ToUnixSeconds()) / 60;
        }
    }

    // ---------------------------------------------------------------- TimeZone
    public memory_unsafe static class TimeZone
    {
        // Desfase actual de la hora local respecto a UTC (positivo al este de Greenwich).
        public static prop LocalOffset: TimeSpan => TimeSpan.FromTicks(faset_tz_offset_sec(faset_time_unix_ms() / 1000) * TimeSpan.TicksPerSecond);

        // Desfase local en un instante UTC concreto (tiene en cuenta el horario de verano).
        public static func OffsetAt(utc: DateTime) -> TimeSpan => TimeSpan.FromTicks(OffsetSecondsAt(utc.ToUnixSeconds()) * TimeSpan.TicksPerSecond);

        public static func OffsetSecondsAt(unixSeconds: long) -> int => faset_tz_offset_sec(unixSeconds);
    }

    // ---------------------------------------------------------------- formato y lectura
    static class DateFormat
    {
        public static func Pad(sb: StringBuilder, v: long, width: int)
        {
            if (v < 0)
            {
                sb.Append('-');
                v = -v;
            }
            long p = 1;
            for (int i = 1; i < width; i++) p *= 10;
            while (p > 1 && v < p)
            {
                sb.Append('0');
                p /= 10;
            }
            sb.Append(v);
        }

        static func MonthName(m: int) -> string
        {
            switch (m)
            {
                case 1: return "January";
                case 2: return "February";
                case 3: return "March";
                case 4: return "April";
                case 5: return "May";
                case 6: return "June";
                case 7: return "July";
                case 8: return "August";
                case 9: return "September";
                case 10: return "October";
                case 11: return "November";
                default: return "December";
            }
        }

        static func DayName(d: DayOfWeek) -> string
        {
            switch (d)
            {
                case DayOfWeek.Sunday: return "Sunday";
                case DayOfWeek.Monday: return "Monday";
                case DayOfWeek.Tuesday: return "Tuesday";
                case DayOfWeek.Wednesday: return "Wednesday";
                case DayOfWeek.Thursday: return "Thursday";
                case DayOfWeek.Friday: return "Friday";
                default: return "Saturday";
            }
        }

        // Longitud de la repetición de s[i].
        static func Run(f: string, i: int) -> int
        {
            int n = 1;
            while (i + n < f.Length && f[i + n] == f[i]) n++;
            return n;
        }

        static func Offset(sb: StringBuilder, minutes: int, digits: int, colon: bool)
        {
            sb.Append(minutes < 0 ? '-' : '+');
            if (minutes < 0) minutes = -minutes;
            Pad(sb, minutes / 60, digits);
            if (!colon) return;
            sb.Append(':');
            Pad(sb, minutes % 60, 2);
        }

        public static func Format(d: DateTime, f: string) -> string
        {
            StringBuilder sb = new StringBuilder();
            int i = 0;
            while (i < f.Length)
            {
                char c = (char)f[i];
                int n = Run(f, i);
                if (c == 'y')
                {
                    if (n == 2) Pad(sb, d.Year % 100, 2);
                    else if (n == 1) sb.Append((long)(d.Year % 100));
                    else Pad(sb, d.Year, n);
                }
                else if (c == 'M')
                {
                    if (n >= 4) sb.Append(MonthName(d.Month));
                    else if (n == 3) sb.Append(MonthName(d.Month).Substring(0, 3));
                    else Pad(sb, d.Month, n);
                }
                else if (c == 'd')
                {
                    if (n >= 4) sb.Append(DayName(d.DayOfWeek));
                    else if (n == 3) sb.Append(DayName(d.DayOfWeek).Substring(0, 3));
                    else Pad(sb, d.Day, n);
                }
                else if (c == 'H') Pad(sb, d.Hour, n > 2 ? 2 : n);
                else if (c == 'h')
                {
                    int h = d.Hour % 12;
                    Pad(sb, h == 0 ? 12 : h, n > 2 ? 2 : n);
                }
                else if (c == 'm') Pad(sb, d.Minute, n > 2 ? 2 : n);
                else if (c == 's') Pad(sb, d.Second, n > 2 ? 2 : n);
                else if (c == 'f' || c == 'F')
                {
                    if (n > 7) n = 7;
                    long frac = d.Ticks % TimeSpan.TicksPerSecond;
                    for (int k = n; k < 7; k++) frac /= 10;
                    Pad(sb, frac, n);
                }
                else if (c == 't')
                {
                    string ampm = d.Hour < 12 ? "AM" : "PM";
                    sb.Append(n == 1 ? ampm.Substring(0, 1) : ampm);
                }
                else if (c == 'z')
                {
                    int off = d.Kind == DateTimeKind.Local ? d.OffsetMinutes() : 0;
                    if (n == 1) Offset(sb, off, 1, false);
                    else if (n == 2) Offset(sb, off, 2, false);
                    else Offset(sb, off, 2, true);
                }
                else if (c == 'K')
                {
                    if (d.Kind == DateTimeKind.Utc) sb.Append('Z');
                    else if (d.Kind == DateTimeKind.Local) Offset(sb, d.OffsetMinutes(), 2, true);
                    n = 1;
                }
                else if (c == '\'' || c == '"')
                {
                    int j = i + 1;
                    while (j < f.Length && (char)f[j] != c) j++;
                    sb.Append(f.Substring(i + 1, j - i - 1));
                    n = j < f.Length ? j - i + 1 : j - i;
                }
                else if (c == '\\' && i + 1 < f.Length)
                {
                    sb.Append(f.Substring(i + 1, 1));
                    n = 2;
                }
                else
                {
                    sb.Append(f.Substring(i, 1));
                    n = 1;
                }
                i += n;
            }
            string s = sb.ToString();
            delete sb;
            return s;
        }

        // ------------------------------------------------ lectura
        static func IsDigit(s: string, i: int) -> bool => i < s.Length && s[i] >= '0' && s[i] <= '9';

        // Lee entre 'min' y 'max' dígitos en s[pos].
        static bool Digits(string s, int& pos, int min, int max, out int value)
        {
            value = 0;
            int n = 0;
            while (n < max && IsDigit(s, pos))
            {
                value = value * 10 + (s[pos] - '0');
                pos++;
                n++;
            }
            return n >= min;
        }

        static bool Expect(string s, int& pos, char c)
        {
            if (pos >= s.Length || (char)s[pos] != c) return false;
            pos++;
            return true;
        }

        // Fracción de segundo -> ticks (se leen todos los dígitos, se usan 7).
        static long Fraction(string s, int& pos)
        {
            long frac = 0;
            int n = 0;
            while (IsDigit(s, pos))
            {
                if (n < 7)
                {
                    frac = frac * 10 + (s[pos] - '0');
                    n++;
                }
                pos++;
            }
            for (; n < 7; n++) frac *= 10;
            return frac;
        }

        // Desfase "+hh:mm", "+hhmm" o "+hh" (o 'Z' si allowZ) -> minutos.
        static bool ParseOffset(string s, int& pos, out int minutes, out bool present, bool allowZ)
        {
            minutes = 0;
            present = false;
            if (pos >= s.Length) return true;
            char c = (char)s[pos];
            if (allowZ && (c == 'Z' || c == 'z'))
            {
                pos++;
                present = true;
                return true;
            }
            if (c != '+' && c != '-') return true;
            pos++;
            int h = 0;
            int m = 0;
            if (!Digits(s, pos, 2, 2, out h)) return false;
            if (Expect(s, pos, ':'))
            {
                if (!Digits(s, pos, 2, 2, out m)) return false;
            }
            else if (IsDigit(s, pos))
            {
                if (!Digits(s, pos, 2, 2, out m)) return false;
            }
            if (h > 23 || m > 59) return false;
            minutes = c == '-' ? -(h * 60 + m) : h * 60 + m;
            present = true;
            return true;
        }

        static func Build(y: int, mo: int, d: int, h: int, mi: int, sec: int, frac: long, hasOffset: bool, offMinutes: int,
                          out result: DateTime) -> bool
        {
            result = new DateTime(0);
            if (!DateTime.IsValid(y, mo, d, h, mi, sec, 0)) return false;
            long t = new DateTime(y, mo, d, h, mi, sec).Ticks + frac;
            if (hasOffset)
            {
                t -= offMinutes * TimeSpan.TicksPerMinute;
                if (t < DateTime.MinTicks || t > DateTime.MaxTicks) return false;
                result = new DateTime(t, DateTimeKind.Utc);
            }
            else
            {
                result = new DateTime(t);
            }
            return true;
        }

        public static func ParseIso(s: string, out result: DateTime) -> bool
        {
            result = new DateTime(0);
            int pos = 0;
            int y = 0;
            int mo = 0;
            int d = 0;
            int h = 0;
            int mi = 0;
            int sec = 0;
            long frac = 0;
            if (!Digits(s, pos, 4, 4, out y) || !Expect(s, pos, '-') || !Digits(s, pos, 2, 2, out mo) ||
                !Expect(s, pos, '-') || !Digits(s, pos, 2, 2, out d))
                return false;
            int off = 0;
            bool hasOff = false;
            if (pos < s.Length)
            {
                char sep = (char)s[pos];
                if (sep != 'T' && sep != 't' && sep != ' ') return false;
                pos++;
                if (!Digits(s, pos, 2, 2, out h) || !Expect(s, pos, ':') || !Digits(s, pos, 2, 2, out mi)) return false;
                if (Expect(s, pos, ':'))
                {
                    if (!Digits(s, pos, 2, 2, out sec)) return false;
                    if (Expect(s, pos, '.') || Expect(s, pos, ','))
                    {
                        if (!IsDigit(s, pos)) return false;
                        frac = Fraction(s, pos);
                    }
                }
                if (!ParseOffset(s, pos, out off, out hasOff, true)) return false;
            }
            if (pos != s.Length) return false;
            return Build(y, mo, d, h, mi, sec, frac, hasOff, off, out result);
        }

        public static func ParseExact(s: string, f: string, out result: DateTime) -> bool
        {
            result = new DateTime(0);
            int pos = 0;
            int i = 0;
            int y = 1;
            int mo = 1;
            int d = 1;
            int h = 0;
            int mi = 0;
            int sec = 0;
            long frac = 0;
            int pm = -1;  // -1 sin AM/PM, 0 AM, 1 PM
            int off = 0;
            bool hasOff = false;
            while (i < f.Length)
            {
                char c = (char)f[i];
                int n = Run(f, i);
                int v = 0;
                if (c == 'y')
                {
                    if (!Digits(s, pos, n == 2 ? 2 : (n == 1 ? 1 : n), n <= 2 ? 2 : (n < 4 ? 4 : n), out v)) return false;
                    y = n <= 2 ? 2000 + v : v;
                }
                else if (c == 'M' && n <= 2)
                {
                    if (!Digits(s, pos, n, 2, out mo)) return false;
                }
                else if (c == 'M')
                {
                    int found = 0;
                    for (int m = 1; m <= 12 && found == 0; m++)
                    {
                        string name = n == 3 ? MonthName(m).Substring(0, 3) : MonthName(m);
                        if (pos + name.Length <= s.Length && s.Substring(pos, name.Length).EqualsIgnoreCase(name))
                        {
                            found = m;
                            pos += name.Length;
                        }
                    }
                    if (found == 0) return false;
                    mo = found;
                }
                else if (c == 'd' && n <= 2)
                {
                    if (!Digits(s, pos, n, 2, out d)) return false;
                }
                else if (c == 'H' || c == 'h')
                {
                    if (!Digits(s, pos, n > 2 ? 2 : n, 2, out h)) return false;
                }
                else if (c == 'm')
                {
                    if (!Digits(s, pos, n > 2 ? 2 : n, 2, out mi)) return false;
                }
                else if (c == 's')
                {
                    if (!Digits(s, pos, n > 2 ? 2 : n, 2, out sec)) return false;
                }
                else if (c == 'f' || c == 'F')
                {
                    if (n > 7) n = 7;
                    int start = pos;
                    long fv = 0;
                    int k = 0;
                    while (k < n && IsDigit(s, pos))
                    {
                        fv = fv * 10 + (s[pos] - '0');
                        pos++;
                        k++;
                    }
                    if (c == 'f' && k != n) return false;
                    for (; k < 7; k++) fv *= 10;
                    frac = fv;
                    if (pos == start && c == 'f') return false;
                }
                else if (c == 't')
                {
                    if (pos >= s.Length) return false;
                    char a = Char.ToUpper((char)s[pos]);
                    if (a != 'A' && a != 'P') return false;
                    pm = a == 'P' ? 1 : 0;
                    pos++;
                    if (n >= 2)
                    {
                        if (pos >= s.Length || Char.ToUpper((char)s[pos]) != 'M') return false;
                        pos++;
                    }
                }
                else if (c == 'z' || c == 'K')
                {
                    if (!ParseOffset(s, pos, out off, out hasOff, c == 'K')) return false;
                    if (c == 'K') n = 1;
                }
                else if (c == '\'' || c == '"')
                {
                    int j = i + 1;
                    while (j < f.Length && (char)f[j] != c) j++;
                    string lit = f.Substring(i + 1, j - i - 1);
                    if (pos + lit.Length > s.Length || s.Substring(pos, lit.Length) != lit) return false;
                    pos += lit.Length;
                    n = j < f.Length ? j - i + 1 : j - i;
                }
                else
                {
                    int len = 1;
                    if (c == '\\' && i + 1 < f.Length)
                    {
                        i++;
                        c = (char)f[i];
                    }
                    if (pos >= s.Length || s[pos] != f[i]) return false;
                    pos++;
                    n = len;
                }
                i += n;
            }
            if (pos != s.Length) return false;
            if (pm >= 0)
            {
                if (h < 1 || h > 12) return false;
                h = h % 12 + (pm == 1 ? 12 : 0);
            }
            return Build(y, mo, d, h, mi, sec, frac, hasOff, off, out result);
        }
    }

    // ---------------------------------------------------------------- Stopwatch
    // Cronómetro de alta resolución sobre un reloj monótono (nanosegundos).
    public memory_unsafe struct Stopwatch
    {
        var startNs: long;
        var accumulated: long;  // ns
        var running: bool;

        // Frecuencia del contador de ElapsedTicks/GetTimestamp (ticks por segundo).
        public const long Frequency = 1000000000;

        public static func StartNew() -> Stopwatch
        {
            Stopwatch s = new Stopwatch();
            s.Start();
            return s;
        }

        // Marca de tiempo monótona en nanosegundos.
        public static func GetTimestamp() -> long => faset_ticks_ns();

        public prop IsRunning: bool => running;

        public func Start()
        {
            if (running) return;
            startNs = faset_ticks_ns();
            running = true;
        }

        public func Stop()
        {
            if (!running) return;
            accumulated += faset_ticks_ns() - startNs;
            running = false;
        }

        public func Reset()
        {
            accumulated = 0;
            running = false;
        }

        public func Restart()
        {
            accumulated = 0;
            running = true;
            startNs = faset_ticks_ns();
        }

        public prop ElapsedNs: long => running ? accumulated + faset_ticks_ns() - startNs : accumulated;
        public prop ElapsedTicks: long => ElapsedNs;
        public prop ElapsedMicroseconds: long => ElapsedNs / 1000;
        public prop ElapsedMs: long => ElapsedNs / 1000000;
        public prop ElapsedSeconds: double => ElapsedNs / 1000000000.0;
        public prop Elapsed: TimeSpan => TimeSpan.FromTicks(ElapsedNs / 100);
    }
}
