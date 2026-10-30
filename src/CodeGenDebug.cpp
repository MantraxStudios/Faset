// Faset - información de depuración del C generado.
//
// En Debug (o con 'faset build -g') el C lleva directivas '#line N "archivo.fst"' delante de
// cada línea que sale de una sentencia de Faset. gcc/clang las copian a DWARF, así que gdb y
// lldb ponen puntos de interrupción, avanzan paso a paso y muestran la pila en las líneas
// de los .fst. El código que no viene de ninguna sentencia (main, inicialización estática,
// constructores auxiliares) vuelve al C generado con '#line @C', que finishLineDirectives
// sustituye por la línea real dentro de "faset_generado.c".
//
// Los nombres del C son reconocibles: variables locales l_<nombre>, parámetros p_<nombre>,
// 'this' = self, campos f_<nombre> y métodos <ns>_<Clase>__m_<Método>; FasetStudio los
// traduce de vuelta al mostrarlos (studio/src/Ide/Debugger.fst).
#include <filesystem>

#include "CodeGen.h"
#include "Frontend.h"  // nativeToUtf8

namespace {
const char* const kResetMarker = "#line @C";
const char* const kGeneratedName = "faset_generado.c";
}  // namespace

void CodeGen::setLoc(SourceLoc l) {
    if (lineDirectives && l.file >= 0 && l.line > 0) curLoc_ = l;
}

void CodeGen::lineDirective(SourceLoc l) {
    if (!lineDirectives || l.file < 0 || l.line <= 0 || l.file >= (int)diag.files.size()) return;
    // Ruta absoluta: gdb la usa tal cual para 'break /ruta/archivo.fst:12' desde el IDE.
    std::string path = (size_t)l.file < diag.paths.size() && !diag.paths[l.file].empty() ? diag.paths[l.file]
                                                                                        : diag.files[l.file];
    std::error_code ec;
    std::filesystem::path abs = std::filesystem::absolute(path, ec);
    if (!ec) path = abs.lexically_normal().generic_string();
    out_ << "#line " << l.line << " " << cstring(nativeToUtf8(path)) << "\n";
}

void CodeGen::resetLoc() {
    if (!lineDirectives) return;
    curLoc_ = SourceLoc{-1, 0, 0};
    out_ << kResetMarker << "\n";
}

// Con información de depuración cada enum de Faset tiene también un tipo enum de C con sus
// miembros (Color__Verde = 1, ...) y las variables locales de ese tipo se declaran con él: gdb
// muestra "fs_Color__Verde" en vez de 1. El miembro negativo hace que el tipo compatible sea
// 'int' (igual que int32_t), así que punteros y conversiones siguen siendo válidos.
void CodeGen::emitDebugEnums() {
    if (!lineDirectives) return;
    for (ClassDecl* c : prog_.types) {
        if (c->kind != ClassKind::Enum || c->isTemplate() || c->cname.empty()) continue;
        out_ << "typedef enum " << c->cname << "__e { ";
        for (EnumMember& m : c->enumMembers) out_ << c->cname << "__" << m.name << " = " << m.val << ", ";
        out_ << c->cname << "__fs_neg = -1 } " << c->cname << "__e;\n";
    }
    out_ << "\n";
}

// También para los campos: mismo tamaño y tipo compatible con int32_t.
std::string CodeGen::localType(Type* t) {
    if (lineDirectives && t->isEnum() && t->decl && !t->decl->cname.empty()) return t->decl->cname + "__e";
    return ctype(t);
}

std::string CodeGen::finishLineDirectives(const std::string& c) {
    if (!lineDirectives) return c;
    std::string r;
    r.reserve(c.size() + 4096);
    size_t pos = 0;
    long lineNo = 1;
    const size_t mlen = std::char_traits<char>::length(kResetMarker);
    while (pos < c.size()) {
        size_t nl = c.find('\n', pos);
        size_t end = nl == std::string::npos ? c.size() : nl;
        if (end - pos == mlen && c.compare(pos, mlen, kResetMarker) == 0) {
            // La línea siguiente a la directiva es la lineNo + 1 del archivo final.
            r += "#line " + std::to_string(lineNo + 1) + " \"" + kGeneratedName + "\"";
        } else {
            r.append(c, pos, end - pos);
        }
        if (nl == std::string::npos) break;
        r += '\n';
        pos = nl + 1;
        lineNo++;
    }
    return r;
}
