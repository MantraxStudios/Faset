import cli from "@/generated/cli.json";
import CodeBlock from "./CodeBlock";

// Tablas generadas a partir de `faset help` (scripts/extract-cli.mjs).
export function CliCommands() {
  return (
    <div className="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Orden</th>
            <th>Descripción</th>
          </tr>
        </thead>
        <tbody>
          {cli.commands.map((c) => (
            <tr key={c.usage}>
              <td>
                <code>{c.usage}</code>
              </td>
              <td>{c.description || "Muestra la versión o esta ayuda"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function CliOptions() {
  return (
    <div className="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Opción</th>
            <th>Descripción</th>
          </tr>
        </thead>
        <tbody>
          {cli.options.map((o) => (
            <tr key={o.flag}>
              <td>
                <code>{o.flag}</code>
              </td>
              <td>{o.description}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function CliHelp() {
  return <CodeBlock code={`$ faset help\n${cli.text}`} lang="text" title={`faset help · v${cli.version}`} />;
}
