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

    // ---- .fstui (clase partial generada) y .fstproj
    const dir = path.join(__dirname, 'ui');
    const open = (name, languageId) => {
        const u = 'file://' + path.join(dir, name);
        const t = fs.readFileSync(path.join(dir, name), 'utf8');
        notify('textDocument/didOpen', { textDocument: { uri: u, languageId, version: 1, text: t } });
        return { u, t };
    };
    const edit = (u, t) => notify('textDocument/didChange', { textDocument: { uri: u, version: 2 }, contentChanges: [{ text: t }] });
    const pos = (u, t, needle, delta) => {
        const off = t.indexOf(needle) + (delta || 0);
        const before = t.slice(0, off).split('\n');
        return { textDocument: { uri: u }, position: { line: before.length - 1, character: before[before.length - 1].length } };
    };
    const complete = (u, t, needle, delta, ch) =>
        request('textDocument/completion', { ...pos(u, t, needle, delta), context: { triggerKind: ch ? 2 : 1, triggerCharacter: ch } });
    const labels = (items) => items.map((i) => i.label);
    const waitDiag = async (u, test, what) => {
        for (let i = 0; i < 100; i++) {
            const last = diagnostics.filter((d) => d.uri === u).pop();
            if (last && test(last.diagnostics)) return last.diagnostics;
            await new Promise((r) => setTimeout(r, 50));
        }
        throw new Error('sin diagnóstico: ' + what);
    };

    const code = open('Ventana.fst', 'faset');
    const field = await request('textDocument/hover', pos(code.u, code.t, 'btnAceptar.Text', 2));
    assert.match(field.contents.value, /Widget Ventana\.btnAceptar/, 'campo generado por el .fstui');
    const fieldDef = await request('textDocument/definition', pos(code.u, code.t, 'btnAceptar.Text', 2));
    assert.ok(fieldDef.uri.endsWith('Ventana.fstui') && fieldDef.range.start.line === 1, 'definición del control en el .fstui');

    const ui = open('Ventana.fstui', 'fstui');
    items = await complete(ui.u, ui.t, 'OnAceptar', 0);
    assert.ok(labels(items).includes('OnAceptar'), 'manejadores del código de la ventana');
    const handler = await request('textDocument/hover', pos(ui.u, ui.t, 'OnAceptar', 2));
    assert.match(handler.contents.value, /OnAceptar\(Widget sender\)/, 'hover del manejador');
    const handlerDef = await request('textDocument/definition', pos(ui.u, ui.t, 'OnAceptar', 2));
    assert.ok(handlerDef.uri.endsWith('Ventana.fst') && handlerDef.range.start.line === 8, 'definición del manejador');
    let t = ui.t.replace('<Button Name', '<Button  Name');
    edit(ui.u, t);
    items = await complete(ui.u, t, '<Button  ', 8, ' ');
    assert.ok(labels(items).includes('Style') && labels(items).includes('Anchor') && !labels(items).includes('Name') && !labels(items).includes('Click'), 'atributos de <Button>');
    assert.ok(items.find((i) => i.label === 'Style').insertText === 'Style="$0"', 'fragmento del atributo');
    t = ui.t.replace('</Window>', '  <\n</Window>');
    edit(ui.u, t);
    items = await complete(ui.u, t, '  <\n</Window>', 3, '<');
    assert.ok(['Button', 'Panel', 'TextBox', 'CheckBox'].every((c) => labels(items).includes(c)), 'controles tras <');
    t = ui.t.replace('Text="Aceptar"', 'Text="Aceptar" Anchor="Left,"');
    edit(ui.u, t);
    items = await complete(ui.u, t, 'Anchor="Left,', 13, ',');
    assert.deepStrictEqual(labels(items).sort(), ['Bottom', 'Right', 'Top'], 'valores de Anchor');
    t = ui.t.replace('Text="Aceptar"', 'Text="Aceptar" Colour="1"');
    edit(ui.u, t);
    let list = await waitDiag(ui.u, (l) => l.some((d) => /Colour/.test(d.message)), 'atributo desconocido');
    const bad = list.find((d) => /Colour/.test(d.message));
    assert.strictEqual(bad.range.start.line, 1, 'línea del atributo desconocido');
    assert.strictEqual(bad.range.start.character, t.split('\n')[1].indexOf('Colour'), 'columna del atributo desconocido');

    const proj = open('PruebaUi.fstproj', 'fstproj');
    t = proj.t.replace('<OutputType>WinExe', '<OutputType>Program').replace('</PropertyGroup>', '  <Optimise>true</Optimise>\n  </PropertyGroup>');
    edit(proj.u, t);
    list = await waitDiag(proj.u, (l) => l.length >= 2, 'proyecto');
    assert.ok(list.some((d) => /OutputType/.test(d.message) && d.range.start.line === 2), 'valor de OutputType');
    assert.ok(list.some((d) => /Optimise/.test(d.message) && d.range.start.line === 5), 'propiedad desconocida');
    items = await complete(proj.u, t, '<Configuration>Debug', 15);
    assert.deepStrictEqual(labels(items).sort(), ['Debug', 'Release'], 'valores de Configuration');
    t = proj.t.replace('</PropertyGroup>', '  <\n  </PropertyGroup>');
    edit(proj.u, t);
    items = await complete(proj.u, t, '  <\n  </PropertyGroup>', 3, '<');
    assert.ok(labels(items).includes('TargetPlatform') && !labels(items).includes('OutputType'), 'propiedades del proyecto');
    const doc = await request('textDocument/hover', pos(proj.u, proj.t, 'OutputType', 2));
    assert.match(doc.contents.value, /WinExe/, 'documentación de la propiedad');

    await request('shutdown');
    notify('exit');
    console.log('ok');
})().catch((e) => { console.error(e.message); srv.kill(); process.exit(1); });
