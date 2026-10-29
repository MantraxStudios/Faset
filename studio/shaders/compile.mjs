import fs from 'fs';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const ModuleFactory = require('./node_modules/@webgpu/glslang/dist/node-devel/glslang.js');
const glslang = await new Promise((resolve) => {
  const opts = { onRuntimeInitialized() { setTimeout(() => { const m = opts.self; delete m.then; resolve(m); }, 0); } };
  opts.self = ModuleFactory(opts);
});
const out = [];
for (const [file, stage, name] of [[process.argv[2], 'vertex', 'Vertex'], [process.argv[3], 'fragment', 'Fragment']]) {
  const spv = glslang.compileGLSL(fs.readFileSync(file, 'utf8'), stage, false, '1.0');
  out.push({ name, words: Array.from(spv) });
}
let s = '// Generado a partir de shaders/ui.vert y shaders/ui.frag (SPIR-V). No editar a mano.\n';
s += '// Para regenerarlo: make -C studio shaders\nnamespace FasetStudio.Gfx\n{\n    public static class Shaders\n    {\n';
for (const { name, words } of out) {
  s += `        public const int ${name}Words = ${words.length};\n\n`;
  s += `        // Devuelve una copia en el heap (libérala con Memory.Free tras crear el módulo).\n`;
  s += `        public static uint* ${name}()\n        {\n            uint* w = new uint[${words.length}];\n`;
  for (let i = 0; i < words.length; i += 6)
    s += '            ' + words.slice(i, i + 6).map((v, k) => `w[${i + k}] = 0x${(v >>> 0).toString(16).padStart(8, '0')}u;`).join(' ') + '\n';
  s += '            return w;\n        }\n\n';
}
s += '    }\n}\n';
fs.writeFileSync(process.argv[4], s);
console.log(out.map(o => `${o.name}: ${o.words.length} palabras, magic 0x${(o.words[0]>>>0).toString(16)}`).join('\n'));
