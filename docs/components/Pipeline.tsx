import CodeBlock from "./CodeBlock";

// Fragmentos reales: docs/samples/pipeline/vec.fst, su `faset emit-c` y el desensamblado
// de la versión Release (objdump -d -M intel) con gcc 15.2 -O2 en x86-64.
const FASET = `struct Vec2
{
    public double X, Y;
    public Vec2(double x, double y) { X = x; Y = y; }
    public static Vec2 operator +(Vec2 a, Vec2 b)
        => new Vec2(a.X + b.X, a.Y + b.Y);
    public double Length => Math.Sqrt(X * X + Y * Y);
}

int main()
{
    Vec2 v = new Vec2(1, 2) + new Vec2(2, 2);
    println(v.Length);   // 5
    return 0;
}`;

const C = `struct fs_Vec2 {
    double f_X;
    double f_Y;
};

fs_Vec2 fs_Vec2__m_op_add(fs_Vec2 p_a, fs_Vec2 p_b) {
    return fs_Vec2__make0(((p_a).f_X + (p_b).f_X),
                          ((p_a).f_Y + (p_b).f_Y));
}

double fs_Vec2__m_Length(fs_Vec2* self) {
    return fs_std_Math__m_Sqrt(((self->f_X * self->f_X)
                              + (self->f_Y * self->f_Y)));
}

int32_t fs_f_main(void) {
    fs_Vec2 l_v = fs_Vec2__m_op_add(
        fs_Vec2__make0(((double)1), ((double)2)),
        fs_Vec2__make0(((double)2), ((double)2)));
    fs_std_f_println_3(fs_Vec2__m_Length((&l_v)));
    return 0;
}`;

const ASM = `; fs_f_main, faset build -c Release (x86-64)
; el operador, la propiedad y la raíz se
; resuelven al compilar: solo queda imprimir 5.0
endbr64
sub    rsp,0x8
movsd  xmm0,QWORD PTR [rip+0x2e58]   ; 5.0
call   faset_write_f64
mov    edi,0xa                       ; '\\n'
call   faset_write_char
xor    eax,eax
add    rsp,0x8
ret`;

function Stage({ x, title, sub, strong = false }: { x: number; title: string; sub: string; strong?: boolean }) {
  return (
    <g>
      <rect
        x={x}
        y={22}
        width={176}
        height={78}
        rx={12}
        fill={strong ? "var(--primary)" : "var(--elevated)"}
        stroke={strong ? "var(--primary)" : "var(--border-strong)"}
      />
      <text x={x + 88} y={56} textAnchor="middle" fontSize="16" fontWeight="650" fill={strong ? "var(--primary-text)" : "var(--text)"}>
        {title}
      </text>
      <text x={x + 88} y={78} textAnchor="middle" fontSize="12" fill={strong ? "var(--primary-text)" : "var(--text-3)"} opacity={strong ? 0.75 : 1}>
        {sub}
      </text>
    </g>
  );
}

function Arrow({ x }: { x: number }) {
  return (
    <g stroke="var(--text-3)" strokeWidth="1.5" fill="none">
      <path d={`M${x} 61 h34`} />
      <path d={`M${x + 28} 55 l6 6 l-6 6`} strokeLinecap="round" strokeLinejoin="round" />
    </g>
  );
}

export default function Pipeline() {
  return (
    <div className="pipeline">
      <svg viewBox="0 0 1000 150" role="img" aria-label="Pipeline: código Faset, el compilador faset, C11 generado, compilador de C y binario nativo">
        <Stage x={0} title=".fst / .fstui" sub="tu código" />
        <Arrow x={182} />
        <Stage x={222} title="faset" sub="lexer · parser · semántica" strong />
        <Arrow x={404} />
        <Stage x={444} title="C11" sub="portable, legible" />
        <Arrow x={626} />
        <Stage x={666} title="gcc · clang · NDK" sub="-O2, enlazado nativo" />
        <Arrow x={848} />
        <g>
          <rect x={888} y={22} width={112} height={78} rx={12} fill="none" stroke="var(--text)" strokeWidth="1.5" />
          <text x={944} y={56} textAnchor="middle" fontSize="16" fontWeight="650" fill="var(--text)">
            nativo
          </text>
          <text x={944} y={78} textAnchor="middle" fontSize="12" fill="var(--text-3)">
            ELF · EXE · .so
          </text>
        </g>
        <text x={311} y={132} textAnchor="middle" fontSize="12" fill="var(--text-3)">
          tipos, sobrecargas, plantillas, accesibilidad
        </text>
        <text x={757} y={132} textAnchor="middle" fontSize="12" fill="var(--text-3)">
          Linux · Windows (MinGW) · Android
        </text>
      </svg>
      <div className="pipe-cols">
        <div>
          <div className="pipe-col-title">1 · Faset</div>
          <CodeBlock code={FASET} lang="faset" title="vec.fst" />
        </div>
        <div>
          <div className="pipe-col-title">2 · C11 generado (faset emit-c)</div>
          <CodeBlock code={C} lang="c" title="extracto de vec.c" />
        </div>
        <div>
          <div className="pipe-col-title">3 · Código máquina (objdump)</div>
          <CodeBlock code={ASM} lang="text" title="x86-64" />
        </div>
      </div>
    </div>
  );
}
