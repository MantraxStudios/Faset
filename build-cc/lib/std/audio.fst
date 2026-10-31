// =============================================================================
//  std.audio  —  sonidos y música: WAV, OGG Vorbis y MP3 con un mezclador propio.
//
//    Sound    sonido corto decodificado entero en memoria (efectos, clics, disparos)
//    Music    pista larga: el archivo se guarda codificado y se decodifica al sonar
//    Voice    una reproducción en curso: Stop, Pause, Resume, Volume, Pan, Speed,
//             Loop, Position, IsPlaying
//    Audio    salida: volumen general, parar o pausar todo, elegir el controlador
//
//      Sound click = Sound.Load("click.wav");
//      click.Play();                          // suena en paralelo con lo demás
//      Music music = Music.Load("tema.ogg");
//      music.Loop = true;
//      music.Play();
//      Voice v = click.Play();
//      v.Pan = -0.5f;                         // un poco a la izquierda
//      Audio.MasterVolume = 0.8f;
//
//  Rutas: se prueba la ruta tal cual (relativa a la carpeta actual), luego junto al
//  ejecutable y, en Android, dentro del APK (los <Asset Include="..."/> del .fstproj
//  se copian a assets/ con la misma ruta relativa).
//
//  Errores: Load nunca devuelve null; si falla, IsLoaded es false, Error dice por qué
//  y Play() no hace nada (devuelve una Voice que ya ha terminado).
//
//  El mezclador corre en su propio hilo de C (lib/audio/faset_audio.c): no llama a
//  código de Faset, así que no hay nada que sincronizar desde el programa. La salida
//  se abre sola en el primer Play(): PulseAudio o ALSA en Linux (con dlopen, no hacen
//  falta paquetes -dev), waveOut en Windows y AAudio u OpenSL ES en Android. Si no hay
//  dispositivo se usa "null": no suena, pero el tiempo avanza y las voces terminan.
// =============================================================================
using std.collections;

namespace std.audio
{
    memory_unsafe static class Native
    {
        public static extern byte* faset_audio_error();
        public static extern int faset_audio_open(string driver);
        public static extern void faset_audio_close();
        public static extern int faset_audio_is_open();
        public static extern byte* faset_audio_driver();
        public static extern int faset_audio_rate();
        public static extern int faset_audio_render(float* output, int frames);
        public static extern void faset_audio_set_master(float volume);
        public static extern float faset_audio_master();
        public static extern void faset_audio_pause_all(int on);
        public static extern void faset_audio_stop_source(void* source);
        public static extern int faset_audio_voice_count();

        public static extern void* faset_sound_load(string path);
        public static extern void* faset_sound_from_memory(byte* data, long length);
        public static extern void* faset_sound_from_samples(float* samples, long frames, int channels, int rate);
        public static extern float faset_sound_sample(void* sound, long frame, int channel);
        public static extern void* faset_music_load(string path);
        public static extern void* faset_music_from_memory(byte* data, long length);
        public static extern long faset_source_frames(void* source);
        public static extern int faset_source_channels(void* source);
        public static extern int faset_source_rate(void* source);
        public static extern void faset_source_set_gain(void* source, float gain);
        public static extern void faset_source_release(void* source);
        public static extern long faset_source_play(void* source, float volume, float pan, float speed, int loop, int paused);

        public static extern void faset_voice_stop(long id);
        public static extern void faset_voice_set_paused(long id, int on);
        public static extern int faset_voice_state(long id);
        public static extern void faset_voice_set(long id, int what, float value);
        public static extern float faset_voice_get(long id, int what);
        public static extern double faset_voice_position(long id);
        public static extern void faset_voice_seek(long id, double seconds);

        // Copia de un texto de C (las cadenas de C cambian en la siguiente llamada).
        public static string Text(byte* p) => String.Copy(String.FromCString(p));
    }

    // ======================================================================= Audio

    // La salida de audio del programa.
    public memory_unsafe static class Audio
    {
        // Abre la salida (lo hace solo el primer Play). driver: "" (automático), "pulse",
        // "alsa", "winmm", "aaudio", "opensl", "null" (sin sonido) u "offline" (sin hilo:
        // el programa mezcla con Render). También se puede elegir con FASET_AUDIO_DRIVER.
        // Devuelve false si no se pudo abrir la pedida (entonces se usa "null").
        public static func Open(driver: string) -> bool => Native.faset_audio_open(driver) != 0;
        public static func Open() -> bool => Native.faset_audio_open("") != 0;

        // Cierra la salida y para todas las voces.
        public static func Close() { Native.faset_audio_close(); }

        public static prop IsOpen: bool => Native.faset_audio_is_open() != 0;

        // Controlador en uso ("" si la salida está cerrada).
        public static prop Driver: string => Native.Text(Native.faset_audio_driver());

        // Frecuencia de la salida en Hz (48000 salvo que el dispositivo pida otra).
        public static prop SampleRate: int => Native.faset_audio_rate();

        // Último error de la biblioteca de audio en este hilo ("" si no hubo).
        public static prop Error: string => Native.Text(Native.faset_audio_error());

        // Volumen general (1 = normal, 0 = silencio; puede pasar de 1).
        public static prop MasterVolume: float
        {
            get => Native.faset_audio_master();
            set { Native.faset_audio_set_master(value); }
        }

        // Para todas las voces.
        public static func StopAll() { Native.faset_audio_stop_source(null); }

        // Pausa o reanuda todo a la vez (p. ej. al minimizar un juego).
        public static func PauseAll() { Native.faset_audio_pause_all(1); }
        public static func ResumeAll() { Native.faset_audio_pause_all(0); }

        // Voces sonando o en pausa.
        public static prop ActiveVoices: int => Native.faset_audio_voice_count();

        // Solo con Open("offline"): mezcla 'frames' fotogramas y los devuelve como
        // muestras estéreo entrelazadas (izquierda, derecha, ...) entre -1 y 1.
        public static func Render(frames: int) -> List<float>
        {
            List<float> buffer = new List<float>(frames * 2);
            for (int i = 0; i < frames * 2; i++) buffer.Add(0);
            if (frames > 0) Native.faset_audio_render(buffer.Data, frames);
            return buffer;
        }

        // Abre la salida si aún no lo está.
        public static func EnsureOpen()
        {
            if (Native.faset_audio_is_open() == 0) Native.faset_audio_open("");
        }
    }

    // ======================================================================= Voice

    // Una reproducción de un Sound o de una Music. Cuando termina (o se para), el
    // identificador deja de ser válido y todo lo de abajo se ignora sin error.
    public memory_unsafe class Voice
    {
        var id: long;
        var duration: double;

        public init(id: long, duration: double)
        {
            this.id = id;
            this.duration = duration;
        }

        // Sonando (no en pausa y sin terminar).
        public prop IsPlaying: bool => id != 0 && Native.faset_voice_state(id) == 1;
        public prop IsPaused: bool => id != 0 && Native.faset_voice_state(id) == 2;
        // Sonando o en pausa.
        public prop IsActive: bool => id != 0 && Native.faset_voice_state(id) != 0;

        public func Stop() { if (id != 0) Native.faset_voice_stop(id); }
        public func Pause() { if (id != 0) Native.faset_voice_set_paused(id, 1); }
        public func Resume() { if (id != 0) Native.faset_voice_set_paused(id, 0); }

        // 1 = volumen original.
        public prop Volume: float
        {
            get => Native.faset_voice_get(id, 0);
            set { Native.faset_voice_set(id, 0, value); }
        }

        // -1 izquierda, 0 centro, 1 derecha.
        public prop Pan: float
        {
            get => Native.faset_voice_get(id, 1);
            set { Native.faset_voice_set(id, 1, value); }
        }

        // Velocidad de reproducción (también cambia el tono): 1 normal, 2 el doble.
        public prop Speed: float
        {
            get => Native.faset_voice_get(id, 2);
            set { Native.faset_voice_set(id, 2, value); }
        }

        public prop Loop: bool
        {
            get => Native.faset_voice_get(id, 3) != 0;
            set { Native.faset_voice_set(id, 3, value ? 1 : 0); }
        }

        // Posición en segundos (al repetir vuelve a 0). Asignarla salta a ese punto.
        public prop Position: double
        {
            get => id != 0 ? Native.faset_voice_position(id) : 0;
            set { if (id != 0) Native.faset_voice_seek(id, value); }
        }

        // Duración de la fuente en segundos.
        public prop Duration: double => duration;
    }

    // ======================================================================= Sound

    // Sonido decodificado entero en memoria: ideal para efectos cortos que suenan
    // muchas veces, incluso a la vez.
    public memory_unsafe class Sound
    {
        void* handle;
        var error: string = "";
        var volume: float = 1;

        // Valores para las próximas reproducciones (Play()).
        public var Pan: float;
        public var Speed: float = 1;
        public var Loop: bool;

        deinit
        {
            if (handle != null) Native.faset_source_release(handle);
            handle = null;
        }

        static Sound Wrap(void* h)
        {
            Sound s = new Sound();
            s.handle = h;
            if (h == null) s.error = Native.Text(Native.faset_audio_error());
            return s;
        }

        // Carga un WAV, OGG o MP3 (ver las reglas de rutas al principio del archivo).
        public static func Load(path: string) -> Sound => Wrap(Native.faset_sound_load(path));

        // Archivo de audio completo ya leído en memoria (WAV, OGG o MP3).
        public static func FromBytes(data: List<byte>) -> Sound => Wrap(Native.faset_sound_from_memory(data.Data, data.Count));

        // Como FromBytes, desde los bytes de una cadena (p. ej. File.ReadAllText de un binario).
        public static func FromBytes(data: string) -> Sound => Wrap(Native.faset_sound_from_memory(data.Ptr, data.Length));

        // Muestras entre -1 y 1 (entrelazadas si channels = 2).
        public static func FromSamples(samples: List<float>, channels: int, sampleRate: int) -> Sound
        {
            long frames = channels > 0 ? samples.Count / channels : 0;
            return Wrap(Native.faset_sound_from_samples(samples.Data, frames, channels, sampleRate));
        }

        // Tono senoidal (con 5 ms de entrada y salida suaves): útil para pitidos y pruebas.
        public static func Tone(frequency: double, seconds: double, volume: float) -> Sound
        {
            int rate = 48000;
            int n = (int)(seconds * rate);
            if (n < 0) n = 0;
            List<float> samples = new List<float>(n);
            int fade = rate / 200;
            for (int i = 0; i < n; i++)
            {
                double env = 1;
                if (i < fade) env = (double)i / fade;
                if (n - 1 - i < fade) env = Math.Min(env, (double)(n - 1 - i) / fade);
                samples.Add((float)(Math.Sin(Math.Tau * frequency * i / rate) * volume * env));
            }
            return FromSamples(samples, 1, rate);
        }
        public static func Tone(frequency: double, seconds: double) -> Sound => Tone(frequency, seconds, 0.5f);

        public prop IsLoaded: bool => handle != null;
        // Por qué no se cargó ("" si se cargó bien).
        public prop Error: string => error;

        public prop Frames: long => handle != null ? Native.faset_source_frames(handle) : 0;
        public prop Channels: int => handle != null ? Native.faset_source_channels(handle) : 0;
        public prop SampleRate: int => handle != null ? Native.faset_source_rate(handle) : 0;
        // Duración en segundos.
        public prop Duration: double => handle != null ? (double)Frames / SampleRate : 0;

        // Volumen del sonido: afecta también a las voces que ya están sonando.
        public prop Volume: float
        {
            get => volume;
            set
            {
                volume = value < 0 ? 0 : value;
                if (handle != null) Native.faset_source_set_gain(handle, volume);
            }
        }

        // Muestra del canal 'channel' en el fotograma 'frame' (-1..1; 0 fuera de rango).
        public func Sample(frame: long, channel: int) -> float => handle != null ? Native.faset_sound_sample(handle, frame, channel) : 0;

        // Empieza a sonar con Pan, Speed y Loop; puede sonar varias veces a la vez.
        public func Play() -> Voice => PlayWith(1, Pan, false);
        // Con un volumen propio para esta voz (que se multiplica por Volume).
        public func Play(voiceVolume: float) -> Voice => PlayWith(voiceVolume, Pan, false);
        // Con volumen y panorama propios.
        public func Play(voiceVolume: float, pan: float) -> Voice => PlayWith(voiceVolume, pan, false);
        // Prepara una voz en pausa (para ajustarla y luego Resume()).
        public func PlayPaused() -> Voice => PlayWith(1, Pan, true);

        func PlayWith(v: float, pan: float, paused: bool) -> Voice
        {
            if (handle == null) return new Voice(0, 0);
            Audio.EnsureOpen();
            long id = Native.faset_source_play(handle, v, pan, Speed, Loop ? 1 : 0, paused ? 1 : 0);
            return new Voice(id, Duration);
        }

        // Para todas las voces de este sonido.
        public func Stop() { if (handle != null) Native.faset_audio_stop_source(handle); }
    }

    // ======================================================================= Music

    // Pista larga (OGG, MP3 o WAV): se guarda el archivo codificado y se decodifica
    // mientras suena. Play() reinicia la pista (una sola voz "actual" con Pause, Resume,
    // Position...); PlayOverlay() lanza otra voz independiente.
    public memory_unsafe class Music
    {
        void* handle;
        var error: string = "";
        var volume: float = 1;
        var current: Voice = new Voice(0, 0);

        public var Pan: float;
        public var Speed: float = 1;
        var loop: bool;

        deinit
        {
            if (handle != null) Native.faset_source_release(handle);
            handle = null;
        }

        static Music Wrap(void* h)
        {
            Music m = new Music();
            m.handle = h;
            if (h == null) m.error = Native.Text(Native.faset_audio_error());
            return m;
        }

        public static func Load(path: string) -> Music => Wrap(Native.faset_music_load(path));
        public static func FromBytes(data: List<byte>) -> Music => Wrap(Native.faset_music_from_memory(data.Data, data.Count));
        public static func FromBytes(data: string) -> Music => Wrap(Native.faset_music_from_memory(data.Ptr, data.Length));

        public prop IsLoaded: bool => handle != null;
        public prop Error: string => error;
        public prop Channels: int => handle != null ? Native.faset_source_channels(handle) : 0;
        public prop SampleRate: int => handle != null ? Native.faset_source_rate(handle) : 0;
        // Duración en segundos (0 si no se conoce).
        public prop Duration: double
        {
            get
            {
                if (handle == null) return 0;
                long f = Native.faset_source_frames(handle);
                return f > 0 ? (double)f / SampleRate : 0;
            }
        }

        public prop Volume: float
        {
            get => volume;
            set
            {
                volume = value < 0 ? 0 : value;
                if (handle != null) Native.faset_source_set_gain(handle, volume);
            }
        }

        // Repetir al llegar al final (también cambia la voz actual).
        public prop Loop: bool
        {
            get => loop;
            set
            {
                loop = value;
                current.Loop = value;
            }
        }

        // La voz de Play() (puede haber terminado).
        public prop Current: Voice => current;

        // Empieza desde el principio (para la reproducción anterior de Play()).
        public func Play() -> Voice
        {
            current.Stop();
            current = Start(false);
            return current;
        }

        // Otra voz independiente de la actual.
        public func PlayOverlay() -> Voice => Start(false);

        func Start(paused: bool) -> Voice
        {
            if (handle == null) return new Voice(0, 0);
            Audio.EnsureOpen();
            long id = Native.faset_source_play(handle, 1, Pan, Speed, loop ? 1 : 0, paused ? 1 : 0);
            return new Voice(id, Duration);
        }

        public prop IsPlaying: bool => current.IsPlaying;
        public prop IsPaused: bool => current.IsPaused;
        public func Pause() { current.Pause(); }
        // Reanuda la pausa; si no estaba sonando, empieza.
        public func Resume()
        {
            if (current.IsActive) current.Resume();
            else Play();
        }
        // Para todas las voces de esta música.
        public func Stop() { if (handle != null) Native.faset_audio_stop_source(handle); }

        // Posición de la voz actual en segundos.
        public prop Position: double
        {
            get => current.Position;
            set { current.Position = value; }
        }
    }
}
