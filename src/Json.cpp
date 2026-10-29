#include "Json.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>

const std::string& Json::asString() const {
    static const std::string empty;
    return kind_ == Kind::String ? s_ : empty;
}

Json& Json::operator[](const std::string& key) {
    if (kind_ != Kind::Object) {
        *this = object();
    }
    for (auto& kv : obj_)
        if (kv.first == key) return kv.second;
    obj_.emplace_back(key, Json());
    return obj_.back().second;
}

const Json& Json::get(const std::string& key) const {
    static const Json null;
    if (kind_ != Kind::Object) return null;
    for (auto& kv : obj_)
        if (kv.first == key) return kv.second;
    return null;
}

bool Json::has(const std::string& key) const {
    if (kind_ != Kind::Object) return false;
    for (auto& kv : obj_)
        if (kv.first == key) return true;
    return false;
}

void Json::push(Json v) {
    if (kind_ != Kind::Array) *this = array();
    arr_.push_back(std::move(v));
}

static void escapeTo(std::string& out, const std::string& s) {
    out += '"';
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof buf, "\\u%04x", c);
                    out += buf;
                } else {
                    out += (char)c;
                }
        }
    }
    out += '"';
}

void Json::dumpTo(std::string& out) const {
    switch (kind_) {
        case Kind::Null: out += "null"; break;
        case Kind::Bool: out += b_ ? "true" : "false"; break;
        case Kind::Number: {
            if (std::floor(n_) == n_ && std::fabs(n_) < 1e15) {
                out += std::to_string((long long)n_);
            } else {
                char buf[32];
                std::snprintf(buf, sizeof buf, "%.17g", n_);
                out += buf;
            }
            break;
        }
        case Kind::String: escapeTo(out, s_); break;
        case Kind::Array:
            out += '[';
            for (size_t i = 0; i < arr_.size(); i++) {
                if (i) out += ',';
                arr_[i].dumpTo(out);
            }
            out += ']';
            break;
        case Kind::Object:
            out += '{';
            for (size_t i = 0; i < obj_.size(); i++) {
                if (i) out += ',';
                escapeTo(out, obj_[i].first);
                out += ':';
                obj_[i].second.dumpTo(out);
            }
            out += '}';
            break;
    }
}

std::string Json::dump() const {
    std::string s;
    dumpTo(s);
    return s;
}

namespace {

struct JsonParser {
    const std::string& s;
    size_t i = 0;
    std::string err;

    explicit JsonParser(const std::string& t) : s(t) {}

    void ws() {
        while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++;
    }
    bool fail(const char* m) {
        if (err.empty()) err = std::string(m) + " en la posición " + std::to_string(i);
        return false;
    }
    static void utf8(std::string& o, uint32_t cp) {
        if (cp < 0x80) o += (char)cp;
        else if (cp < 0x800) {
            o += (char)(0xC0 | (cp >> 6));
            o += (char)(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            o += (char)(0xE0 | (cp >> 12));
            o += (char)(0x80 | ((cp >> 6) & 0x3F));
            o += (char)(0x80 | (cp & 0x3F));
        } else {
            o += (char)(0xF0 | (cp >> 18));
            o += (char)(0x80 | ((cp >> 12) & 0x3F));
            o += (char)(0x80 | ((cp >> 6) & 0x3F));
            o += (char)(0x80 | (cp & 0x3F));
        }
    }
    bool hex4(uint32_t& v) {
        if (i + 4 > s.size()) return false;
        v = 0;
        for (int k = 0; k < 4; k++) {
            char c = s[i++];
            v <<= 4;
            if (c >= '0' && c <= '9') v |= (uint32_t)(c - '0');
            else if (c >= 'a' && c <= 'f') v |= (uint32_t)(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') v |= (uint32_t)(c - 'A' + 10);
            else return false;
        }
        return true;
    }
    bool str(std::string& out) {
        i++;  // "
        while (i < s.size() && s[i] != '"') {
            char c = s[i++];
            if (c != '\\') {
                out += c;
                continue;
            }
            if (i >= s.size()) return fail("escape incompleto");
            char e = s[i++];
            switch (e) {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u': {
                    uint32_t cp;
                    if (!hex4(cp)) return fail("\\u no válido");
                    if (cp >= 0xD800 && cp < 0xDC00 && i + 1 < s.size() && s[i] == '\\' && s[i + 1] == 'u') {
                        i += 2;
                        uint32_t lo;
                        if (!hex4(lo)) return fail("\\u no válido");
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    }
                    utf8(out, cp);
                    break;
                }
                default: return fail("escape desconocido");
            }
        }
        if (i >= s.size()) return fail("cadena sin cerrar");
        i++;
        return true;
    }
    bool value(Json& out) {
        ws();
        if (i >= s.size()) return fail("fin inesperado");
        char c = s[i];
        if (c == '{') {
            i++;
            out = Json::object();
            ws();
            if (i < s.size() && s[i] == '}') {
                i++;
                return true;
            }
            for (;;) {
                ws();
                if (i >= s.size() || s[i] != '"') return fail("se esperaba una clave");
                std::string key;
                if (!str(key)) return false;
                ws();
                if (i >= s.size() || s[i] != ':') return fail("se esperaba ':'");
                i++;
                Json v;
                if (!value(v)) return false;
                out[key] = std::move(v);
                ws();
                if (i < s.size() && s[i] == ',') {
                    i++;
                    continue;
                }
                if (i < s.size() && s[i] == '}') {
                    i++;
                    return true;
                }
                return fail("se esperaba ',' o '}'");
            }
        }
        if (c == '[') {
            i++;
            out = Json::array();
            ws();
            if (i < s.size() && s[i] == ']') {
                i++;
                return true;
            }
            for (;;) {
                Json v;
                if (!value(v)) return false;
                out.push(std::move(v));
                ws();
                if (i < s.size() && s[i] == ',') {
                    i++;
                    continue;
                }
                if (i < s.size() && s[i] == ']') {
                    i++;
                    return true;
                }
                return fail("se esperaba ',' o ']'");
            }
        }
        if (c == '"') {
            std::string v;
            if (!str(v)) return false;
            out = Json(std::move(v));
            return true;
        }
        if (s.compare(i, 4, "true") == 0) {
            i += 4;
            out = Json(true);
            return true;
        }
        if (s.compare(i, 5, "false") == 0) {
            i += 5;
            out = Json(false);
            return true;
        }
        if (s.compare(i, 4, "null") == 0) {
            i += 4;
            out = Json();
            return true;
        }
        const char* start = s.c_str() + i;
        char* end = nullptr;
        double d = std::strtod(start, &end);
        if (end == start) return fail("valor no válido");
        i += (size_t)(end - start);
        out = Json(d);
        return true;
    }
};

}  // namespace

bool Json::parse(const std::string& text, Json& out, std::string* error) {
    JsonParser p(text);
    bool ok = p.value(out);
    if (ok) {
        p.ws();
        if (p.i != text.size()) ok = p.fail("contenido sobrante");
    }
    if (!ok && error) *error = p.err;
    return ok;
}
