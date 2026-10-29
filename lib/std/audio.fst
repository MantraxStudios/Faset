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
        public static bool Open(string driver) => Native.faset_audio_open(driver) != 0;
        public static bool Open() => Native.faset_audio_open("") != 0;

        // Cierra la salida y para todas las voces.
        public static void Close() { Native.faset_audio_close(); }

        public static bool IsOpen => Native.faset_audio_is_open() != 0;

        // Controlador en uso ("" si la salida está cerrada).
        public static string Driver => Native.Text(Native.faset_audio_driver());

        // Frecuencia de la salida en Hz (48000 salvo que el dispositivo pida otra).
        public static int SampleRate => Native.faset_audio_rate();

        // Último error de la biblioteca de audio en este hilo ("" si no hubo).
        public static string Error => Native.Text(Native.faset_audio_error());

        // Volumen general (1 = normal, 0 = silencio; puede pasar de 1).
        public static float MasterVolume
        {
            get => Native.faset_audio_master();
            set { Native.faset_audio_set_master(value); }
        }

        // Para todas las voces.
        public static void StopAll() { Native.faset_audio_stop_source(null); }

        // Pausa o reanuda todo a la vez (p. ej. al minimizar un juego).
        public static void PauseAll() { Native.faset_audio_pause_all(1); }
        public static void ResumeAll() { Native.faset_audio_pause_all(0); }

        // Voces sonando o en pausa.
        public static int ActiveVoices => Native.faset_audio_voice_count();

        // Solo con Open("offline"): mezcla 'frames' fotogramas y los devuelve como
        // muestras estéreo entrelazadas (izquierda, derecha, ...) entre -1 y 1.
        public static List<float> Render(int frames)
        {
            List<float> buffer = new List<float>(frames * 2);
            for (int i = 0; i < frames * 2; i++) buffer.Add(0);
            if (frames > 0) Native.faset_audio_render(buffer.Data, frames);
            return buffer;
        }

        // Abre la salida si aún no lo está.
        public static void EnsureOpen()
        {
            if (Native.faset_audio_is_open() == 0) Native.faset_audio_open("");
        }
    }

    // ======================================================================= Voice

    // Una reproducción de un Sound o de una Music. Cuando termina (o se para), el
    // identificador deja de ser válido y todo lo de abajo se ignora sin error.
    public memory_unsafe class Voice
    {
        long id;
        double duration;

        public Voice(long id, double duration)
        {
            this.id = id;
            this.duration = duration;
        }

        // Sonando (no en pausa y sin terminar).
        public bool IsPlaying => id != 0 && Native.faset_voice_state(id) == 1;
        public bool IsPaused => id != 0 && Native.faset_voice_state(id) == 2;
        // Sonando o en pausa.
        public bool IsActive => id != 0 && Native.faset_voice_state(id) != 0;

        public void Stop() { if (id != 0) Native.faset_voice_stop(id); }
        public void Pause() { if (id != 0) Native.faset_voice_set_paused(id, 1); }
        public void Resume() { if (id != 0) Native.faset_voice_set_paused(id, 0); }

        // 1 = volumen original.
        public float Volume
        {
            get => Native.faset_voice_get(id, 0);
            set { Native.faset_voice_set(id, 0, value); }
        }

        // -1 izquierda, 0 centro, 1 derecha.
        public float Pan
        {
            get => Native.faset_voice_get(id, 1);
            set { Native.faset_voice_set(id, 1, value); }
        }

        // Velocidad de reproducción (también cambia el tono): 1 normal, 2 el doble.
        public float Speed
        {
            get => Native.faset_voice_get(id, 2);
            set { Native.faset_voice_set(id, 2, value); }
        }

        public bool Loop
        {
            get => Native.faset_voice_get(id, 3) != 0;
            set { Native.faset_voice_set(id, 3, value ? 1 : 0); }
        }

        // Posición en segundos (al repetir vuelve a 0). Asignarla salta a ese punto.
        public double Position
        {
            get => id != 0 ? Native.faset_voice_position(id) : 0;
            set { if (id != 0) Native.faset_voice_seek(id, value); }
        }

        // Duración de la fuente en segundos.
        public double Duration => duration;
    }

    // ======================================================================= Sound

    // Sonido decodificado entero en memoria: ideal para efectos cortos que suenan
    // muchas veces, incluso a la vez.
    public memory_unsafe class Sound
    {
        void* handle;
        string error = "";
        float volume = 1;

        // Valores para las próximas reproducciones (Play()).
        public float Pan;
        public float Speed = 1;
        public bool Loop;

        ~Sound()
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
        public static Sound Load(string path) => Wrap(Native.faset_sound_load(path));

        // Archivo de audio completo ya leído en memoria (WAV, OGG o MP3).
        public static Sound FromBytes(List<byte> data) => Wrap(Native.faset_sound_from_memory(data.Data, data.Count));

        // Como FromBytes, desde los bytes de una cadena (p. ej. File.ReadAllText de un binario).
        public static Sound FromBytes(string data) => Wrap(Native.faset_sound_from_memory(data.Ptr, data.Length));

        // Muestras entre -1 y 1 (entrelazadas si channels = 2).
        public static Sound FromSamples(List<float> samples, int channels, int sampleRate)
        {
            long frames = channels > 0 ? samples.Count / channels : 0;
            return Wrap(Native.faset_sound_from_samples(samples.Data, frames, channels, sampleRate));
        }

        // Tono senoidal (con 5 ms de entrada y salida suaves): útil para pitidos y pruebas.
        public static Sound Tone(double frequency, double seconds, float volume)
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
        public static Sound Tone(double frequency, double seconds) => Tone(frequency, seconds, 0.5f);

        public bool IsLoaded => handle != null;
        // Por qué no se cargó ("" si se cargó bien).
        public string Error => error;

        public long Frames => handle != null ? Native.faset_source_frames(handle) : 0;
        public int Channels => handle != null ? Native.faset_source_channels(handle) : 0;
        public int SampleRate => handle != null ? Native.faset_source_rate(handle) : 0;
        // Duración en segundos.
        public double Duration => handle != null ? (double)Frames / SampleRate : 0;

        // Volumen del sonido: afecta también a las voces que ya están sonando.
        public float Volume
        {
            get => volume;
            set
            {
                volume = value < 0 ? 0 : value;
                if (handle != null) Native.faset_source_set_gain(handle, volume);
            }
        }

        // Muestra del canal 'channel' en el fotograma 'frame' (-1..1; 0 fuera de rango).
        public float Sample(long frame, int channel) => handle != null ? Native.faset_sound_sample(handle, frame, channel) : 0;

        // Empieza a sonar con Pan, Speed y Loop; puede sonar varias veces a la vez.
        public Voice Play() => PlayWith(1, Pan, false);
        // Con un volumen propio para esta voz (que se multiplica por Volume).
        public Voice Play(float voiceVolume) => PlayWith(voiceVolume, Pan, false);
        // Con volumen y panorama propios.
        public Voice Play(float voiceVolume, float pan) => PlayWith(voiceVolume, pan, false);
        // Prepara una voz en pausa (para ajustarla y luego Resume()).
        public Voice PlayPaused() => PlayWith(1, Pan, true);

        Voice PlayWith(float v, float pan, bool paused)
        {
            if (handle == null) return new Voice(0, 0);
            Audio.EnsureOpen();
            long id = Native.faset_source_play(handle, v, pan, Speed, Loop ? 1 : 0, paused ? 1 : 0);
            return new Voice(id, Duration);
        }

        // Para todas las voces de este sonido.
        public void Stop() { if (handle != null) Native.faset_audio_stop_source(handle); }
    }

    // ======================================================================= Music

    // Pista larga (OGG, MP3 o WAV): se guarda el archivo codificado y se decodifica
    // mientras suena. Play() reinicia la pista (una sola voz "actual" con Pause, Resume,
    // Position...); PlayOverlay() lanza otra voz independiente.
    public memory_unsafe class Music
    {
        void* handle;
        string error = "";
        float volume = 1;
        Voice current = new Voice(0, 0);

        public float Pan;
        public float Speed = 1;
        bool loop;

        ~Music()
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

        public static Music Load(string path) => Wrap(Native.faset_music_load(path));
        public static Music FromBytes(List<byte> data) => Wrap(Native.faset_music_from_memory(data.Data, data.Count));
        public static Music FromBytes(string data) => Wrap(Native.faset_music_from_memory(data.Ptr, data.Length));

        public bool IsLoaded => handle != null;
        public string Error => error;
        public int Channels => handle != null ? Native.faset_source_channels(handle) : 0;
        public int SampleRate => handle != null ? Native.faset_source_rate(handle) : 0;
        // Duración en segundos (0 si no se conoce).
        public double Duration
        {
            get
            {
                if (handle == null) return 0;
                long f = Native.faset_source_frames(handle);
                return f > 0 ? (double)f / SampleRate : 0;
            }
        }

        public float Volume
        {
            get => volume;
            set
            {
                volume = value < 0 ? 0 : value;
                if (handle != null) Native.faset_source_set_gain(handle, volume);
            }
        }

        // Repetir al llegar al final (también cambia la voz actual).
        public bool Loop
        {
            get => loop;
            set
            {
                loop = value;
                current.Loop = value;
            }
        }

        // La voz de Play() (puede haber terminado).
        public Voice Current => current;

        // Empieza desde el principio (para la reproducción anterior de Play()).
        public Voice Play()
        {
            current.Stop();
            current = Start(false);
            return current;
        }

        // Otra voz independiente de la actual.
        public Voice PlayOverlay() => Start(false);

        Voice Start(bool paused)
        {
            if (handle == null) return new Voice(0, 0);
            Audio.EnsureOpen();
            long id = Native.faset_source_play(handle, 1, Pan, Speed, loop ? 1 : 0, paused ? 1 : 0);
            return new Voice(id, Duration);
        }

        public bool IsPlaying => current.IsPlaying;
        public bool IsPaused => current.IsPaused;
        public void Pause() { current.Pause(); }
        // Reanuda la pausa; si no estaba sonando, empieza.
        public void Resume()
        {
            if (current.IsActive) current.Resume();
            else Play();
        }
        // Para todas las voces de esta música.
        public void Stop() { if (handle != null) Native.faset_audio_stop_source(handle); }

        // Posición de la voz actual en segundos.
        public double Position
        {
            get => current.Position;
            set { current.Position = value; }
        }
    }
}
