// Resultados medidos por docs/benchmarks/run.py (nunca se escriben a mano).
import results from "@/benchmarks/results.json";
import { formatBytes, formatNum } from "@/lib/util";

type Result = { lang: string; seconds: number; runs: number };

export const bench = results;

function fmtTime(s: number) {
  return s < 1 ? `${formatNum(s * 1000, 0)} ms` : `${formatNum(s, 2)} s`;
}

export function BenchBars() {
  return (
    <div className="bench-grid">
      {results.cpu.map((b) => {
        const max = Math.max(...b.results.map((r: Result) => r.seconds));
        const faset = b.results.find((r: Result) => r.lang === "Faset")!;
        return (
          <figure className="bench-card" key={b.id} style={{ margin: 0 }}>
            <figcaption>
              <div className="bench-title">{b.title}</div>
              <div className="bench-note">Tiempo de pared, mediana · menos es mejor</div>
            </figcaption>
            {b.results.map((r: Result) => {
              const ratio = r.seconds / faset.seconds;
              const tip = `${r.lang}: ${fmtTime(r.seconds)} (mediana de ${r.runs} ejecuciones)${
                r.lang !== "Faset" ? ` · ${formatNum(ratio, ratio < 10 ? 2 : 0)}× el tiempo de Faset` : ""
              }`;
              return (
                <div className={`bar-row${r.lang === "Faset" ? " is-faset" : ""}`} key={r.lang} title={tip}>
                  <span className="bar-label">{r.lang.replace(" (gcc -O2)", "")}</span>
                  <span className="bar-track">
                    <span className="bar-fill" style={{ width: `${(r.seconds / max) * 100}%`, display: "block" }} />
                  </span>
                  <span className="bar-value">{fmtTime(r.seconds)}</span>
                </div>
              );
            })}
          </figure>
        );
      })}
    </div>
  );
}

export function BuildTable() {
  return (
    <div className="mini-table">
      <table>
        <thead>
          <tr>
            <th>Proyecto (faset build -c Release)</th>
            <th className="num">Líneas</th>
            <th className="num">Compilación</th>
            <th className="num">Ejecutable</th>
          </tr>
        </thead>
        <tbody>
          {results.build.map((b) => (
            <tr key={b.title}>
              <td>{b.title}</td>
              <td className="num">{b.lines.toLocaleString("es-ES")}</td>
              <td className="num">{formatNum(b.seconds, 2)} s</td>
              <td className="num">{formatBytes(b.bytes)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function StartupTable() {
  return (
    <div className="mini-table">
      <table>
        <thead>
          <tr>
            <th>«Hola, mundo»</th>
            <th className="num">Arranque</th>
            <th className="num">Tamaño</th>
          </tr>
        </thead>
        <tbody>
          {results.startup.map((s) => (
            <tr key={s.lang}>
              <td>{s.lang}</td>
              <td className="num">{formatNum(s.ms, 2)} ms</td>
              <td className="num">{formatBytes(s.bytes)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function CpuTable() {
  const langs = results.cpu[0].results.map((r: Result) => r.lang);
  return (
    <div className="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Prueba</th>
            {langs.map((l: string) => (
              <th key={l} style={{ textAlign: "right" }}>
                {l}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {results.cpu.map((b) => (
            <tr key={b.id}>
              <td>
                {b.title}
                <br />
                <code>{b.output}</code>
              </td>
              {b.results.map((r: Result) => (
                <td key={r.lang} style={{ textAlign: "right", fontVariantNumeric: "tabular-nums" }}>
                  {fmtTime(r.seconds)}
                  <br />
                  <span style={{ color: "var(--text-3)", fontSize: 12 }}>n = {r.runs}</span>
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function Machine() {
  const m = results.machine;
  const [y, mo, d] = results.date.split("-");
  return (
    <p className="bench-foot">
      Medido el {d}/{mo}/{y} en {m.cpu} ({m.cores} hilos, {m.memoryGB} GB), {m.os}, kernel {m.kernel}. {m.gcc}; {m.python};
      Node.js {m.node}; {m.faset}.
    </p>
  );
}
