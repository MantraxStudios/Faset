// Faset - generación de C para los arreglos T[] (std.Array<T>, ver Arrays.cpp y lib/std/arrays.fst).
//
// a[i] sobre un T[] no llama a operator[]: se emite una función 'static inline' por tipo de arreglo
// que comprueba la referencia y el índice y devuelve la dirección del elemento:
//
//   (*fs_std_Array_G_3__at(a, i, fs__f1, 12))
//
//   FASET_CHECK_FN int32_t* fs_std_Array_G_3__at(fs_std_Array_G_3* a, int64_t i, const char* f, int32_t l) {
//       a = faset_chk_obj(a, f, l);
//       if (FASET_UNLIKELY((uint64_t)i >= (uint64_t)a->f_length)) faset_panic_index(i, a->f_length, f, l);
//       return a->f_items + i;
//   }
//
// En un bucle queda una comparación y un acceso directo (el compilador de C la expande en línea).
// Fuera de rango: IndexOutOfRangeException dentro de un 'try'; si no, panic. a.Length lee el campo.
#include "Arrays.h"
#include "CodeGen.h"

namespace {
FieldDecl* fieldNamed(ClassDecl* c, const char* name) {
    for (FieldDecl* f : c->fields)
        if (!f->isStatic() && f->name == name) return f;
    return nullptr;
}
}  // namespace

std::string CodeGen::arrayHelper(ClassDecl* c) {
    std::string fn = c->cname + "__at";
    if (!arrayHelpers_.insert(c).second) return fn;
    FieldDecl* items = fieldNamed(c, "items");
    FieldDecl* len = fieldNamed(c, "length");
    std::string ip = fieldPath(c, items), lp = fieldPath(c, len);
    helpers_ += "FASET_CHECK_FN " + localType(items->type) + " " + fn + "(" + c->cname +
                "* a, int64_t i, const char* f, int32_t l) {\n"
                "    a = (" + c->cname + "*)faset_chk_obj((void*)a, f, l);\n"
                "    if (FASET_UNLIKELY((uint64_t)i >= (uint64_t)a->" + lp + ")) faset_panic_index(i, a->" + lp + ", f, l);\n"
                "    return a->" + ip + " + i;\n"
                "}\n\n";
    return fn;
}

bool CodeGen::arrayIndexCode(IndexExpr* ix, std::string& out) {
    MethodDecl* m = ix->opMethod;
    if (!m || m->params.size() != 1 || !m->params[0].type || !vectorElemOf(ix->obj->type)) return false;
    Type* pt = m->params[0].type;
    if (!pt->is(TK::Int) && !pt->is(TK::Long)) return false;  // a[^1], a[1..3]: operator[] normal
    ClassDecl* c = ix->obj->type->decl;
    if (!fieldNamed(c, "items") || !fieldNamed(c, "length")) return false;
    std::string fn = arrayHelper(c);
    // a[i]: primero 'a', después 'i' (EvalOrder.cpp)
    std::vector<EvalOp> ops = {{ix->obj, expr(ix->obj), ctype(ix->obj->type)},
                               {ix->index, expr(ix->index), ctype(ix->index->type)}};
    std::string pre = sequence(ops);
    out = seqWrapLv(pre, "(*" + fn + "(" + ops[0].code + ", " + ops[1].code + ", " + callerLoc(ix->loc) + "))");
    return true;
}

bool CodeGen::arrayLengthCode(MemberExpr* m, std::string& out) {
    if (!m->getter || m->getter->name != "Length" || m->arrow || !m->obj || m->obj->vk != ValKind::Value ||
        m->obj->kind == EK::This || !vectorElemOf(m->obj->type))
        return false;
    ClassDecl* c = m->obj->type->decl;
    FieldDecl* len = fieldNamed(c, "length");
    if (!len) return false;
    out = "((int32_t)" + memberAccess(m->obj, false, fieldPath(c, len)) + ")";
    return true;
}
