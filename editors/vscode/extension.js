// Extensión de VS Code para Faset.
//
// Incluye un cliente LSP mínimo (sin dependencias de npm) que habla con `faset lsp`:
// errores en vivo, autocompletado, información al pasar el ratón, ir a la definición
// y esquema del documento. También añade comandos para compilar y ejecutar.
'use strict';

const vscode = require('vscode');
const cp = require('child_process');
const fs = require('fs');
const path = require('path');

const SELECTOR = [{ language: 'faset' }, { language: 'fstproj' }, { language: 'fstui' }];
const LANGUAGES = new Set(['faset', 'fstproj', 'fstui']);
const CHANGE_DELAY_MS = 150;

let client = null;
let output = null;

// ------------------------------------------------------------------ utilidades

function findFaset() {
    const configured = vscode.workspace.getConfiguration('faset').get('path');
    if (configured) return configured;
    const exe = process.platform === 'win32' ? 'faset.exe' : 'faset';
    for (const dir of (process.env.PATH || '').split(path.delimiter)) {
        const candidate = path.join(dir, exe);
        if (dir && fs.existsSync(candidate)) return candidate;
    }
    // Extensión instalada desde el repositorio (editors/vscode): el compilador está en la raíz.
    for (const rel of [['..', '..', exe], ['..', '..', 'build', exe]]) {
        const candidate = path.join(__dirname, ...rel);
        if (fs.existsSync(candidate)) return candidate;
    }
    return exe;
}

function toRange(r) {
    return new vscode.Range(r.start.line, r.start.character, r.end.line, r.end.character);
}

function toPosition(p) {
    return { line: p.line, character: p.character };
}

// ------------------------------------------------------------------ cliente LSP

class LanguageClient {
    constructor(diagnostics) {
        this.diagnostics = diagnostics;
        this.nextId = 1;
        this.pending = new Map();
        this.buffer = Buffer.alloc(0);
        this.proc = null;
        this.ready = null;
        this.opened = new Set();
        this.changeTimers = new Map();
        this.restarts = 0;
        this.stopping = false;
    }

    start() {
        const exe = findFaset();
        this.stopping = false;
        try {
            this.proc = cp.spawn(exe, ['lsp'], { stdio: ['pipe', 'pipe', 'pipe'] });
        } catch (err) {
            this.reportMissing(exe, err);
            return;
        }
        this.proc.on('error', (err) => this.reportMissing(exe, err));
        this.proc.stdout.on('data', (data) => this.onData(data));
        this.proc.stderr.on('data', (data) => output.append(data.toString()));
        this.proc.on('exit', (code) => this.onExit(code));
        this.ready = this.request('initialize', {
            processId: process.pid,
            rootUri: vscode.workspace.workspaceFolders ? vscode.workspace.workspaceFolders[0].uri.toString() : null,
            capabilities: {},
        }).then(() => {
            this.notify('initialized', {});
            this.opened.clear();
            for (const doc of vscode.workspace.textDocuments) this.didOpen(doc);
        });
        this.ready.catch(() => {});
    }

    reportMissing(exe, err) {
        if (this.reportedMissing) return;
        this.reportedMissing = true;
        output.appendLine(`No se pudo iniciar '${exe} lsp': ${err.message}`);
        vscode.window
            .showErrorMessage(
                `Faset: no se encontró el compilador ('${exe}'). Instálalo o configura 'faset.path'.`,
                'Configurar'
            )
            .then((choice) => {
                if (choice) vscode.commands.executeCommand('workbench.action.openSettings', 'faset.path');
            });
    }

    onExit(code) {
        for (const [, p] of this.pending) p.reject(new Error('el servidor de Faset terminó'));
        this.pending.clear();
        this.proc = null;
        if (this.stopping) return;
        output.appendLine(`El servidor de Faset terminó (código ${code}).`);
        if (this.restarts++ < 5 && !this.reportedMissing) setTimeout(() => this.start(), 1000 * this.restarts);
    }

    stop() {
        this.stopping = true;
        if (!this.proc) return Promise.resolve();
        const proc = this.proc;
        return this.request('shutdown', null)
            .catch(() => {})
            .then(() => {
                this.notify('exit', null);
                setTimeout(() => proc.kill(), 500);
            });
    }

    send(message) {
        if (!this.proc) return;
        const body = JSON.stringify(message);
        if (vscode.workspace.getConfiguration('faset').get('trace')) output.appendLine('--> ' + body.slice(0, 500));
        this.proc.stdin.write(`Content-Length: ${Buffer.byteLength(body, 'utf8')}\r\n\r\n${body}`);
    }

    request(method, params) {
        return new Promise((resolve, reject) => {
            if (!this.proc) return reject(new Error('el servidor de Faset no está en marcha'));
            const id = this.nextId++;
            this.pending.set(id, { resolve, reject });
            this.send({ jsonrpc: '2.0', id, method, params });
        });
    }

    notify(method, params) {
        this.send({ jsonrpc: '2.0', method, params });
    }

    onData(data) {
        this.buffer = Buffer.concat([this.buffer, data]);
        for (;;) {
            const headerEnd = this.buffer.indexOf('\r\n\r\n');
            if (headerEnd < 0) return;
            const match = /Content-Length:\s*(\d+)/i.exec(this.buffer.slice(0, headerEnd).toString('ascii'));
            if (!match) {
                this.buffer = this.buffer.slice(headerEnd + 4);
                continue;
            }
            const length = parseInt(match[1], 10);
            if (this.buffer.length < headerEnd + 4 + length) return;
            const body = this.buffer.slice(headerEnd + 4, headerEnd + 4 + length).toString('utf8');
            this.buffer = this.buffer.slice(headerEnd + 4 + length);
            let msg;
            try {
                msg = JSON.parse(body);
            } catch (e) {
                continue;
            }
            if (vscode.workspace.getConfiguration('faset').get('trace')) output.appendLine('<-- ' + body.slice(0, 500));
            this.onMessage(msg);
        }
    }

    onMessage(msg) {
        if (msg.id !== undefined && msg.method === undefined) {
            const p = this.pending.get(msg.id);
            if (!p) return;
            this.pending.delete(msg.id);
            if (msg.error) p.reject(new Error(msg.error.message));
            else p.resolve(msg.result);
            return;
        }
        if (msg.method === 'textDocument/publishDiagnostics') this.onDiagnostics(msg.params);
    }

    onDiagnostics(params) {
        const uri = vscode.Uri.parse(params.uri);
        const list = (params.diagnostics || []).map((d) => {
            const severity = d.severity === 1 ? vscode.DiagnosticSeverity.Error
                : d.severity === 2 ? vscode.DiagnosticSeverity.Warning
                : d.severity === 3 ? vscode.DiagnosticSeverity.Information
                : vscode.DiagnosticSeverity.Hint;
            const diag = new vscode.Diagnostic(toRange(d.range), d.message, severity);
            diag.source = 'faset';
            return diag;
        });
        this.diagnostics.set(uri, list);
    }

    // ---- sincronización de documentos

    didOpen(doc) {
        if (!LANGUAGES.has(doc.languageId) || doc.uri.scheme !== 'file') return;
        const key = doc.uri.toString();
        if (this.opened.has(key)) return;
        this.opened.add(key);
        this.notify('textDocument/didOpen', {
            textDocument: { uri: key, languageId: doc.languageId, version: doc.version, text: doc.getText() },
        });
    }

    didChange(doc) {
        const key = doc.uri.toString();
        if (!this.opened.has(key)) return;
        clearTimeout(this.changeTimers.get(key));
        this.changeTimers.set(key, setTimeout(() => this.flushChange(doc), CHANGE_DELAY_MS));
    }

    flushChange(doc) {
        const key = doc.uri.toString();
        if (!this.changeTimers.has(key)) return;
        clearTimeout(this.changeTimers.get(key));
        this.changeTimers.delete(key);
        this.notify('textDocument/didChange', {
            textDocument: { uri: key, version: doc.version },
            contentChanges: [{ text: doc.getText() }],
        });
    }

    didSave(doc) {
        const key = doc.uri.toString();
        if (!this.opened.has(key)) return;
        this.flushChange(doc);
        this.notify('textDocument/didSave', { textDocument: { uri: key } });
    }

    didClose(doc) {
        const key = doc.uri.toString();
        if (!this.opened.delete(key)) return;
        clearTimeout(this.changeTimers.get(key));
        this.changeTimers.delete(key);
        this.notify('textDocument/didClose', { textDocument: { uri: key } });
        this.diagnostics.delete(doc.uri);
    }

    // Antes de cada consulta se envían los cambios pendientes del documento.
    async query(method, doc, params) {
        if (!this.proc) return null;
        await this.ready;
        this.didOpen(doc);
        this.flushChange(doc);
        try {
            return await this.request(method, Object.assign({ textDocument: { uri: doc.uri.toString() } }, params));
        } catch (e) {
            return null;
        }
    }
}

// ------------------------------------------------------------------ proveedores

function hoverProvider() {
    return {
        async provideHover(doc, position) {
            const r = await client.query('textDocument/hover', doc, { position: toPosition(position) });
            if (!r || !r.contents) return null;
            const md = new vscode.MarkdownString(r.contents.value);
            return new vscode.Hover(md, r.range ? toRange(r.range) : undefined);
        },
    };
}

function definitionProvider() {
    return {
        async provideDefinition(doc, position) {
            const r = await client.query('textDocument/definition', doc, { position: toPosition(position) });
            if (!r || !r.uri) return null;
            return new vscode.Location(vscode.Uri.parse(r.uri), toRange(r.range));
        },
    };
}

function completionProvider() {
    return {
        async provideCompletionItems(doc, position, token, context) {
            const r = await client.query('textDocument/completion', doc, {
                position: toPosition(position),
                context: { triggerKind: context.triggerKind + 1, triggerCharacter: context.triggerCharacter },
            });
            if (!Array.isArray(r)) return [];
            return r.map((c) => {
                const item = new vscode.CompletionItem(c.label, Math.max(0, (c.kind || 1) - 1));
                if (c.detail) item.detail = c.detail;
                if (c.sortText) item.sortText = c.sortText;
                // Atributos y elementos de .fstproj/.fstui: fragmento con la posición del cursor ($0).
                if (c.insertText) item.insertText = c.insertTextFormat === 2 ? new vscode.SnippetString(c.insertText) : c.insertText;
                return item;
            });
        },
    };
}

function symbolProvider() {
    const convert = (s) => {
        const range = toRange(s.range);
        const sym = new vscode.DocumentSymbol(s.name, s.detail || '', Math.max(0, s.kind - 1), range, toRange(s.selectionRange));
        sym.children = (s.children || []).map(convert);
        return sym;
    };
    return {
        async provideDocumentSymbols(doc) {
            const r = await client.query('textDocument/documentSymbol', doc, {});
            return Array.isArray(r) ? r.map(convert) : [];
        },
    };
}

// Formatear documento: textDocument/formatting (faset fmt).
function formattingProvider() {
    return {
        async provideDocumentFormattingEdits(doc) {
            const r = await client.query('textDocument/formatting', doc, { options: { tabSize: 4, insertSpaces: true } });
            return Array.isArray(r) ? r.map((e) => vscode.TextEdit.replace(toRange(e.range), e.newText)) : [];
        },
    };
}

// ------------------------------------------------------------------ comandos

function projectArgs() {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.uri.scheme !== 'file') return null;
    const file = editor.document.uri.fsPath;
    // ¿Hay un .fstproj en la carpeta del archivo o en alguna superior?
    let dir = path.dirname(file);
    for (;;) {
        const proj = fs.readdirSync(dir).find((f) => f.endsWith('.fstproj'));
        if (proj) return { cwd: dir, args: [] };
        const parent = path.dirname(dir);
        if (parent === dir) break;
        dir = parent;
    }
    return { cwd: path.dirname(file), args: [file] };
}

function runInTerminal(command, extra) {
    const target = projectArgs();
    if (!target) {
        vscode.window.showWarningMessage('Faset: abre un archivo .fst para compilar.');
        return;
    }
    vscode.workspace.saveAll(false).then(() => {
        let term = vscode.window.terminals.find((t) => t.name === 'Faset');
        if (!term) term = vscode.window.createTerminal({ name: 'Faset', cwd: target.cwd });
        term.show(true);
        const quote = (s) => (/[\s"']/.test(s) ? `"${s}"` : s);
        const exe = quote(findFaset());
        term.sendText(`cd ${quote(target.cwd)}`);
        term.sendText([exe, command].concat(target.args.map(quote), extra || []).join(' '));
    });
}

// ------------------------------------------------------------------ activación

function activate(context) {
    output = vscode.window.createOutputChannel('Faset');
    const diagnostics = vscode.languages.createDiagnosticCollection('faset');
    client = new LanguageClient(diagnostics);
    client.start();

    context.subscriptions.push(
        output,
        diagnostics,
        vscode.workspace.onDidOpenTextDocument((d) => client.didOpen(d)),
        vscode.workspace.onDidChangeTextDocument((e) => client.didChange(e.document)),
        vscode.workspace.onDidSaveTextDocument((d) => client.didSave(d)),
        vscode.workspace.onDidCloseTextDocument((d) => client.didClose(d)),
        vscode.languages.registerHoverProvider(SELECTOR, hoverProvider()),
        vscode.languages.registerDefinitionProvider(SELECTOR, definitionProvider()),
        vscode.languages.registerCompletionItemProvider(SELECTOR, completionProvider(), '.', ':', '>', '<', '"', ' ', ','),
        vscode.languages.registerDocumentSymbolProvider(SELECTOR, symbolProvider()),
        vscode.languages.registerDocumentFormattingEditProvider({ language: 'faset' }, formattingProvider()),
        vscode.commands.registerCommand('faset.build', () => runInTerminal('build')),
        vscode.commands.registerCommand('faset.buildRelease', () => runInTerminal('build', ['-c', 'Release'])),
        vscode.commands.registerCommand('faset.run', () => runInTerminal('run')),
        vscode.commands.registerCommand('faset.test', () => runInTerminal('test')),
        vscode.commands.registerCommand('faset.restartServer', async () => {
            await client.stop();
            client.restarts = 0;
            client.reportedMissing = false;
            client.start();
            vscode.window.setStatusBarMessage('Faset: servidor reiniciado', 3000);
        }),
        vscode.workspace.onDidChangeConfiguration((e) => {
            if (e.affectsConfiguration('faset.path')) vscode.commands.executeCommand('faset.restartServer');
        })
    );
}

function deactivate() {
    return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
