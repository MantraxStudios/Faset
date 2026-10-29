#!/usr/bin/env python3
# Compila ui.vert y ui.frag con glslc y genera src/Gfx/Shaders.fst (mismo formato que compile.mjs).
#   python3 shaders/compile.py   (desde studio/)
import os, struct, subprocess, sys, tempfile
here = os.path.dirname(os.path.abspath(__file__))
# glslc: variable GLSLC, PATH o el que trae el Android NDK.
import glob, shutil
glslc = os.environ.get('GLSLC') or shutil.which('glslc') or next(iter(sorted(glob.glob(os.path.expanduser('~/Android/Sdk/ndk/*/shader-tools/*/glslc')))), None)
if not glslc: sys.exit('no se encontró glslc (instala shaderc o el Android NDK)')
out = []
for src, name in (('ui.vert', 'Vertex'), ('ui.frag', 'Fragment')):
    with tempfile.NamedTemporaryFile(suffix='.spv', delete=False) as tmp:
        path = tmp.name
    subprocess.check_call([glslc, '-O', os.path.join(here, src), '-o', path])
    data = open(path, 'rb').read()
    os.unlink(path)
    out.append((name, list(struct.unpack('<%dI' % (len(data) // 4), data))))
s = '// Generado a partir de shaders/ui.vert y shaders/ui.frag (SPIR-V). No editar a mano.\n'
s += '// Para regenerarlo: python3 studio/shaders/compile.py (necesita glslc)\nnamespace FasetStudio.Gfx\n{\n    public static class Shaders\n    {\n'
for name, words in out:
    s += f'        public const int {name}Words = {len(words)};\n\n'
    s += '        // Devuelve una copia en el heap (libérala con Memory.Free tras crear el módulo).\n'
    s += f'        public static uint* {name}()\n        {{\n            uint* w = new uint[{len(words)}];\n'
    for i in range(0, len(words), 6):
        s += '            ' + ' '.join(f'w[{i + k}] = 0x{v:08x}u;' for k, v in enumerate(words[i:i + 6])) + '\n'
    s += '            return w;\n        }\n\n'
s += '    }\n}\n'
open(os.path.join(here, '..', 'src', 'Gfx', 'Shaders.fst'), 'w').write(s)
print('\n'.join(f'{n}: {len(w)} palabras' for n, w in out))
