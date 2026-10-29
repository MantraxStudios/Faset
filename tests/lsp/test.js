// Prueba del servidor de lenguaje: node tests/lsp/test.js <ruta a faset>
'use strict';
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const file = path.join(__dirname, 'demo.fst');
const uri = 'file://' + file;
let text = fs.readFileSync(file, 'utf8');
const srv = spawn(process.argv[2], ['lsp']);
let buf = Buffer.alloc(0), nextId = 0;
const pending = {}, diagnostics = [];

srv.stdout.on('data', (d) => {
    buf = Buffer.concat([buf, d]);
    for (;;) {
        const h = buf.indexOf('\r\n\r\n');
        if (h < 0) return;
        const len = +/Content-Length: (\d+)/.exec(buf.slice(0, h).toString())[1];
        if (buf.length < h + 4 + len) return;
        const msg = JSON.parse(buf.slice(h + 4, h + 4 + len).toString());
        buf = buf.slice(h + 4 + len);
        if (msg.id !== undefined && pending[msg.id]) pending[msg.id](msg.result);
        else if (msg.method === 'textDocument/publishDiagnostics') diagnostics.push(msg.params);
    }
});
const send = (m) => { const s = JSON.stringify(m); srv.stdin.write(`Content-Length: ${Buffer.byteLength(s)}\r\n\r\n${s}`); };
const request = (method, params) => new Promise((r) => { const id = ++nextId; pending[id] = r; send({ jsonrpc: '2.0', id, method, params }); });
const notify = (method, params) => send({ jsonrpc: '2.0', method, params });
const at = (line, character) => ({ textDocument: { uri }, position: { line, character } });
const change = (t) => { text = t; notify('textDocument/didChange', { textDocument: { uri, version: 2 }, contentChanges: [{ text }] }); };

(async () => {
    const init = await request('initialize', { capabilities: {} });
    assert.ok(init.capabilities.completionProvider, 'capacidades');
    notify('initialized', {});
    notify('textDocument/didOpen', { textDocument: { uri, languageId: 'faset', version: 1, text } });

    const hover = await request('textDocument/hover', at(16, 18));
    assert.match(hover.contents.value, /int List<int>\.Count/, 'hover de propiedad');
    const local = await request('textDocument/hover', at(12, 10));
    assert.match(local.contents.value, /variable local\) List<int> lista/, 'hover de variable');
    const def = await request('textDocument/definition', at(13, 15));
    assert.strictEqual(def.range.start.line, 8, 'definición de Doble');
    assert.ok(diagnostics.some((d) => d.diagnostics.some((x) => /'string' en 'int'/.test(x.message))), 'diagnóstico');

    const lines = text.split('\n');
    lines.splice(16, 0, '    lista.');
    change(lines.join('\n'));
    let items = await request('textDocument/completion', { ...at(16, 10), context: { triggerKind: 2, triggerCharacter: '.' } });
    assert.ok(items.some((i) => i.label === 'Add') && items.some((i) => i.label === 'Count'), 'miembros de List<int>');
    lines[16] = '    p.';
    change(lines.join('\n'));
    items = await request('textDocument/completion', { ...at(16, 6), context: { triggerKind: 2, triggerCharacter: '.' } });
    assert.deepStrictEqual(items.map((i) => i.label).sort(), ['Suma', 'X', 'Y'], 'miembros de Punto');
    lines[16] = '';
    lines[0] = 'using std.';
    change(lines.join('\n'));
    items = await request('textDocument/completion', { ...at(0, 10), context: { triggerKind: 2, triggerCharacter: '.' } });
    assert.ok(items.some((i) => i.label === 'collections') && items.some((i) => i.label === 'io'), 'módulos de std');
    const symbols = await request('textDocument/documentSymbol', { textDocument: { uri } });
    assert.deepStrictEqual(symbols.map((s) => s.name), ['Punto', 'Doble', 'main'], 'esquema');

    await request('shutdown');
    notify('exit');
    console.log('ok');
})().catch((e) => { console.error(e.message); srv.kill(); process.exit(1); });
