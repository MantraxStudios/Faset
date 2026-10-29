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

    // ---- excepciones: hover de la variable de un catch y miembros de la excepción
    lines[0] = 'using std::collections;';
    const exc = ['void Probar()', '{', '    try { Doble(1); }', '    catch (FormatException error) when (error.Message.Length > 0)',
                 '    {', '        error.', '    }', '    finally { }', '}'];
    const b = lines.length;
    change(lines.concat(exc).join('\n'));
    const eh = await request('textDocument/hover', at(b + 3, exc[3].indexOf('error') + 2));
    assert.match(eh.contents.value, /variable local\) FormatException error/, 'hover de la variable del catch');
    const et = await request('textDocument/hover', at(b + 3, exc[3].indexOf('FormatException') + 2));
    assert.match(et.contents.value, /FormatException/, 'hover del tipo del catch');
    items = await request('textDocument/completion', { ...at(b + 5, 14), context: { triggerKind: 2, triggerCharacter: '.' } });
    assert.ok(['Message', 'InnerException', 'StackTrace', 'TypeName', 'ToString'].every((m) => items.some((i) => i.label === m)),
              'miembros de una excepción');
    // ---- azúcar: hover y autocompletado dentro de los huecos de $"..." y en foreach/tuplas
    lines[0] = 'using std::collections;';
    lines[16] = '    string s = $"total {lista.Count} y {p.X}"; foreach (var n in lista) { var t = (a: n, b: 2); println(t.a); }';
    change(lines.join('\n'));
    const holeHover = await request('textDocument/hover', at(16, lines[16].indexOf('Count') + 1));
    assert.match(holeHover.contents.value, /int List<int>\.Count/, 'hover dentro de un hueco');
    const loopVar = await request('textDocument/hover', at(16, lines[16].indexOf('var n') + 4));
    assert.match(loopVar.contents.value, /variable local\) int n/, 'hover de la variable de foreach');
    lines[16] = '    string s = $"total {lista.Count} y {p.}";';
    change(lines.join('\n'));
    items = await request('textDocument/completion', { ...at(16, lines[16].indexOf('{p.') + 3), context: { triggerKind: 2, triggerCharacter: '.' } });
    assert.ok(items.some((i) => i.label === 'X') && items.some((i) => i.label === 'Suma'), 'autocompletado dentro de un hueco');
    lines[16] = '';

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
    // std.audio: componentes no visuales <Sound> y <Music>
    assert.ok(labels(items).includes('Sound') && labels(items).includes('Music'), 'componentes de audio tras <');
    t = ui.t.replace('</Window>', '  <Sound Name="sndClic"  />\n</Window>');
    edit(ui.u, t);
    items = await complete(ui.u, t, 'Name="sndClic" ', 15, ' ');
    assert.ok(['Source', 'Volume', 'Loop', 'AutoPlay'].every((a) => labels(items).includes(a)) && !labels(items).includes('Width'), 'atributos de <Sound>');
    const sndHover = await request('textDocument/hover', pos(ui.u, t, 'sndClic', 2));
    assert.match(sndHover.contents.value, /Sound Ventana\.sndClic/, 'campo Sound generado por el .fstui');
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

    // ---- lambdas: tipos de los parámetros inferidos (hover y autocompletado)
    const lam = { u: 'file://' + path.join(__dirname, 'lambdas.fst'), t: fs.readFileSync(path.join(__dirname, 'lambdas.fst'), 'utf8') };
    notify('textDocument/didOpen', { textDocument: { uri: lam.u, languageId: 'faset', version: 1, text: lam.t } });
    let lh = await request('textDocument/hover', pos(lam.u, lam.t, 'p.Precio', 0));
    assert.match(lh.contents.value, /\(parámetro\) Producto p/, 'hover del parámetro de una lambda');
    lh = await request('textDocument/hover', pos(lam.u, lam.t, 'x * 2', 0));
    assert.match(lh.contents.value, /\(parámetro\) int x/, 'hover del parámetro desde el delegado');
    lh = await request('textDocument/hover', pos(lam.u, lam.t, 'caros', 1));
    assert.match(lh.contents.value, /List<string> caros/, 'tipo inferido de Select');
    t = lam.t.replace('p.Precio > 10', 'p.');
    edit(lam.u, t);
    items = await complete(lam.u, t, 'p => p.', 7, '.');
    assert.ok(labels(items).includes('Nombre') && labels(items).includes('Precio'), 'miembros del parámetro de una lambda');
    // ---- herencia: miembros heredados, override -> miembro de la base, base.Metodo(), interfaces
    const oo = (() => {
        const p = path.join(__dirname, 'herencia.fst');
        const u = 'file://' + p;
        const t = fs.readFileSync(p, 'utf8');
        notify('textDocument/didOpen', { textDocument: { uri: u, languageId: 'faset', version: 1, text: t } });
        return { u, t };
    })();
    const ovr = await request('textDocument/hover', pos(oo.u, oo.t, 'Sonido() => "guau"', 1));
    assert.match(ovr.contents.value, /reemplaza string Animal\.Sonido\(\)/, 'hover de un override');
    const ovrDef = await request('textDocument/definition', pos(oo.u, oo.t, 'Hablar() => base', 1));
    assert.strictEqual(ovrDef.range.start.line, 9, 'override -> declaración de la base');
    const baseDef = await request('textDocument/definition', pos(oo.u, oo.t, 'base.Hablar', 6));
    assert.strictEqual(baseDef.range.start.line, 9, 'base.Hablar() -> Animal.Hablar');
    const inh = await request('textDocument/hover', pos(oo.u, oo.t, 'nombre = "Rex"', 1));
    assert.match(inh.contents.value, /string Animal\.nombre/, 'hover de un campo heredado');
    const cls = await request('textDocument/hover', pos(oo.u, oo.t, 'Perro p', 1));
    assert.match(cls.contents.value, /class Perro : Animal/, 'hover de la clase con su base');
    t = oo.t.replace('p.Jugar();', 'p.');
    edit(oo.u, t);
    items = await complete(oo.u, t, 'p.\n', 2, '.');
    assert.ok(['Jugar', 'Hablar', 'Sonido', 'ToString', 'GetType'].every((n) => labels(items).includes(n)), 'miembros heredados');
    assert.ok(!labels(items).includes('nombre'), 'protegido fuera de la jerarquía');
    t = oo.t.replace('nombre = "Rex";', 'this.');
    edit(oo.u, t);
    items = await complete(oo.u, t, 'this.', 5, '.');
    assert.ok(labels(items).includes('nombre') && labels(items).includes('Jugar'), 'protegido en la derivada');
    const ooSymbols = await request('textDocument/documentSymbol', { textDocument: { uri: oo.u } });
    assert.strictEqual(ooSymbols.find((s) => s.name === 'ISonido').kind, 11, 'símbolo de interfaz');

    // ---- async / await: hover de Task<T> con el tipo que da 'await', del propio 'await' y palabras clave
    const asy = (() => {
        const p = path.join(__dirname, 'async.fst');
        const u = 'file://' + p;
        const t = fs.readFileSync(p, 'utf8');
        notify('textDocument/didOpen', { textDocument: { uri: u, languageId: 'faset', version: 1, text: t } });
        return { u, t };
    })();
    const ah = await request('textDocument/hover', pos(asy.u, asy.t, 'Calcular(3)', 2));
    assert.match(ah.contents.value, /async Task<int> Programa\.Calcular\(int x\)  \(await: int\)/, 'hover de un método async');
    const av = await request('textDocument/hover', pos(asy.u, asy.t, 'tarea = ', 1));
    assert.match(av.contents.value, /Task<int> tarea  \(await: int\)/, 'hover de una variable Task<T>');
    const aw = await request('textDocument/hover', pos(asy.u, asy.t, 'await tarea', 1));
    assert.match(aw.contents.value, /await: espera a 'Task<int>' y da 'int'/, "hover de 'await'");
    t = asy.t.replace('Console.WriteLine(valor);', 'aw');
    edit(asy.u, t);
    items = await complete(asy.u, t, 'aw\n', 2);
    assert.ok(labels(items).includes('await') && labels(items).includes('async'), 'palabras clave async/await');

    await request('shutdown');
    notify('exit');
    console.log('ok');
})().catch((e) => { console.error(e.message); srv.kill(); process.exit(1); });
