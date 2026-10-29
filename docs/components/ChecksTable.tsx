// Coste de las comprobaciones en ejecución, medido por docs/benchmarks/run_checks.py
// con examples/benchmark_checks.fst (nunca se escribe a mano).
import Link from "next/link";
import checks from "@/benchmarks/checks.json";
import { formatNum } from "@/lib/util";

const LABELS: Record<string, string> = {
  objetos: "Objetos (campos y métodos)",
  listas: "List<T> y división",
  cadenas: "Índices de cadenas",
  total: "Total",
};

export default function ChecksTable() {
  const [y, m, d] = checks.date.split("-");
  const pairs = [
    ["Release", checks.configs[0], checks.configs[1]],
    ["Debug", checks.configs[2], checks.configs[3]],
  ] as const;
  return (
    <>
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Prueba</th>
              {pairs.map(([conf]) => [
                <th key={conf + "a"} style={{ textAlign: "right" }}>
                  {conf} --no-checks
                </th>,
                <th key={conf + "b"} style={{ textAlign: "right" }}>
                  {conf} --checks
                </th>,
                <th key={conf + "c"} style={{ textAlign: "right" }}>
                  Coste
                </th>,
              ])}
            </tr>
          </thead>
          <tbody>
            {checks.rows.map((r) => (
              <tr key={r}>
                <td>{r === "total" ? <strong>{LABELS[r]}</strong> : LABELS[r] ?? r}</td>
                {pairs.map(([conf, off, on]) => {
                  const a = (off.ms as Record<string, number>)[r];
                  const b = (on.ms as Record<string, number>)[r];
                  const pct = a > 0 ? ((b - a) / a) * 100 : 0;
                  return [
                    <td key={conf + "a"} style={{ textAlign: "right", fontVariantNumeric: "tabular-nums" }}>
                      {a} ms
                    </td>,
                    <td key={conf + "b"} style={{ textAlign: "right", fontVariantNumeric: "tabular-nums" }}>
                      {b} ms
                    </td>,
                    <td key={conf + "c"} style={{ textAlign: "right", fontVariantNumeric: "tabular-nums" }}>
                      {conf === "Debug" ? `${formatNum(b / a, 2)}×` : `${pct >= 0 ? "+" : ""}${formatNum(pct, 0)} %`}
                    </td>,
                  ];
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p style={{ fontSize: 13, color: "var(--text-3)" }}>
        Mediana de {checks.runs} ejecuciones por configuración, medido el {d}/{m}/{y} en la misma máquina que la página de{" "}
        <Link href="/rendimiento/">rendimiento</Link>. Los milisegundos los mide el propio programa con <code>Time.TickMs()</code>, así que
        las pruebas cortas tienen una resolución de ±1 ms. Las comprobaciones de nulos, índices y divisiones están en todas las columnas;{" "}
        <code>--checks</code> añade los diagnósticos de <code>delete</code>. Se repite con <code>python3 docs/benchmarks/run_checks.py</code>.
      </p>
    </>
  );
}
