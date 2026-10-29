// std.audio: decodificación (WAV, OGG, MP3) y el mezclador sin dispositivo ("offline").
using std.audio;
using std.collections;

void U16(List<byte> b, int v)
{
    b.Add((byte)(v & 255));
    b.Add((byte)((v >> 8) & 255));
}

void U32(List<byte> b, long v)
{
    U16(b, (int)(v & 65535));
    U16(b, (int)((v >> 16) & 65535));
}

void Tag(List<byte> b, string s)
{
    for (int i = 0; i < s.Length; i++) b.Add(s[i]);
}

// WAV con 'frames' fotogramas; cada muestra vale 'value' (-1..1) en el canal 0 y -value en el 1.
List<byte> Wav(int tag, int bits, int channels, int rate, int frames, double value)
{
    List<byte> b = new List<byte>();
    int bytes = bits / 8;
    long dataLen = (long)frames * channels * bytes;
    Tag(b, "RIFF");
    U32(b, 4 + 8 + 16 + 8 + 8 + dataLen);
    Tag(b, "WAVE");
    // Un bloque desconocido (con relleno impar) que hay que saltar.
    Tag(b, "LIST");
    U32(b, 3);
    b.Add(1); b.Add(2); b.Add(3); b.Add(0);
    Tag(b, "fmt ");
    U32(b, 16);
    U16(b, tag);
    U16(b, channels);
    U32(b, rate);
    U32(b, (long)rate * channels * bytes);
    U16(b, channels * bytes);
    U16(b, bits);
    Tag(b, "data");
    U32(b, dataLen);
    for (int f = 0; f < frames; f++)
        for (int c = 0; c < channels; c++)
        {
            double v = c == 0 ? value : -value;
            if (tag == 3)
            {
                float fv = (float)v;
                uint u = 0;
                memory_unsafe { u = *(uint*)&fv; }
                U32(b, u);
            }
            else if (bits == 8) b.Add((byte)(128 + (int)Math.Round(v * 127)));
            else
            {
                long max = (1L << (bits - 1)) - 1;
                long iv = (long)Math.Round(v * max);
                for (int k = 0; k < bytes; k++) b.Add((byte)((iv >> (8 * k)) & 255));
            }
        }
    return b;
}

string R(double v) => Convert.ToString(Math.Round(v * 1000) / 1000);

void Describe(string name, Sound s)
{
    println(name + ": " + (s.IsLoaded ? "ok" : "error") + " ch=" + Convert.ToString(s.Channels) + " rate=" +
            Convert.ToString(s.SampleRate) + " frames=" + Convert.ToString(s.Frames) + " dur=" + R(s.Duration) +
            " s0=" + R(s.Sample(0, 0)) + " s1=" + R(s.Sample(0, 1)));
}

double Peak(Sound s)
{
    double p = 0;
    for (long i = 0; i < s.Frames; i++) p = Math.Max(p, Math.Abs((double)s.Sample(i, 0)));
    return p;
}

void main()
{
    // ---- WAV
    Describe("pcm8", Sound.FromBytes(Wav(1, 8, 1, 8000, 4000, 0.5)));
    Describe("pcm16", Sound.FromBytes(Wav(1, 16, 2, 44100, 22050, 0.25)));
    Describe("pcm24", Sound.FromBytes(Wav(1, 24, 2, 48000, 96000, -0.75)));
    Describe("pcm32", Sound.FromBytes(Wav(1, 32, 1, 16000, 1600, 0.5)));
    Describe("float32", Sound.FromBytes(Wav(3, 32, 2, 22050, 11025, 0.125)));
    Sound bad = Sound.FromBytes("esto no es audio");
    println(bad.IsLoaded);
    println(bad.Error);
    Sound truncated = Sound.FromBytes(Wav(1, 12, 1, 8000, 10, 0.5));
    println(truncated.Error);
    Sound missing = Sound.Load("no/existe.wav");
    println(missing.Error);
    Voice nothing = missing.Play();
    println(nothing.IsPlaying);

    // ---- OGG Vorbis y MP3 (tonos de 440 Hz de 0,5 s con amplitud 1/8, hechos con ffmpeg)
    Sound ogg = Sound.Load("tests/cases/audio/tono.ogg");
    println("ogg: " + Convert.ToString(ogg.Channels) + " " + Convert.ToString(ogg.SampleRate) + " " + R(ogg.Duration) +
            " pico 1/8: " + (Peak(ogg) > 0.11 && Peak(ogg) < 0.14 ? "sí" : "no"));
    Sound mp3 = Sound.Load("tests/cases/audio/tono.mp3");
    println("mp3: " + Convert.ToString(mp3.Channels) + " " + Convert.ToString(mp3.SampleRate) + " dur>=0.5: " +
            (mp3.Duration >= 0.5 && mp3.Duration < 0.65 ? "sí" : "no") + " pico: " + R(Peak(mp3)) + " frames: " + Convert.ToString(mp3.Frames));
    Music song = Music.Load("tests/cases/audio/tono.ogg");
    println("music ogg: " + R(song.Duration) + " " + Convert.ToString(song.SampleRate));
    Music songMp3 = Music.Load("tests/cases/audio/tono.mp3");
    println("music mp3: " + (songMp3.Duration >= 0.5 && songMp3.Duration < 0.65 ? "sí" : "no"));

    // ---- mezclador sin dispositivo
    println(Audio.Open("offline"));
    println(Audio.Driver);
    println(Audio.SampleRate);
    List<float> ones = new List<float>();
    for (int i = 0; i < 960; i++) ones.Add(0.5f);
    Sound dc = Sound.FromSamples(ones, 1, 48000);     // 20 ms de 0,5 constante
    Voice v = dc.Play();
    println(v.IsPlaying);
    println(v.Duration);
    List<float> mix = Audio.Render(480);
    println("centro: " + R(mix[0]) + " " + R(mix[1]) + " pos=" + R(v.Position));
    mix = Audio.Render(480);
    mix = Audio.Render(480);
    println("después: " + R(mix[0]) + " activa=" + (v.IsActive ? "sí" : "no") + " voces=" + Convert.ToString(Audio.ActiveVoices));

    // Panorama, volumen y volumen general
    Voice left = dc.Play(0.5f, -1);
    mix = Audio.Render(10);
    println("izquierda: " + R(mix[0]) + " " + R(mix[1]));
    left.Stop();
    Audio.Render(480);
    Audio.MasterVolume = 0.5f;
    dc.Volume = 2;
    dc.Play();
    mix = Audio.Render(10);
    println("general: " + R(mix[0]));
    Audio.StopAll();
    Audio.Render(480);
    Audio.MasterVolume = 1;
    dc.Volume = 1;

    // Velocidad doble: 960 fotogramas duran 480; bucle: sigue sonando
    dc.Speed = 2;
    Voice fast = dc.Play();
    Audio.Render(470);
    println("rápida a 470: " + (fast.IsActive ? "sí" : "no"));
    Audio.Render(480);
    println("rápida a 950: " + (fast.IsActive ? "sí" : "no"));
    dc.Speed = 1;
    dc.Loop = true;
    Voice looped = dc.Play();
    Audio.Render(4800);
    println("bucle: " + (looped.IsPlaying ? "sí" : "no") + " pos=" + R(looped.Position));
    looped.Pause();
    Audio.Render(480);
    println("pausa: " + (looped.IsPaused ? "sí" : "no"));
    mix = Audio.Render(10);
    println("silencio: " + R(mix[0]));
    looped.Resume();
    Audio.Render(480);
    mix = Audio.Render(10);
    println("reanudada: " + R(mix[0]));
    looped.Stop();
    Audio.Render(480);
    println("parada: " + (looped.IsActive ? "sí" : "no"));
    dc.Loop = false;

    // Música en streaming (WAV de 1 s a 8 kHz, remuestreado a 48 kHz) con bucle y salto
    Music m = Music.FromBytes(Wav(1, 16, 1, 8000, 8000, 0.5));
    println("música: " + R(m.Duration));
    m.Loop = true;
    m.Play();
    Audio.Render(24000);
    println("pos: " + R(m.Position));
    mix = Audio.Render(10);
    println("valor: " + R(mix[0]));
    Audio.Render(48000);
    println("vuelta: " + R(m.Position) + " " + (m.IsPlaying ? "sí" : "no"));
    m.Position = 0.25;
    Audio.Render(4800);
    println("salto: " + R(m.Position));
    m.Loop = false;
    Audio.Render(48000);
    println("sigue sonando: " + (m.IsPlaying ? "sí" : "no") + " voces=" + Convert.ToString(Audio.ActiveVoices));
    Audio.Close();
    println(Audio.IsOpen);
}
