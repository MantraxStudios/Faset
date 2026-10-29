// Faset - JSON mínimo (para el servidor de lenguaje).
#pragma once
#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

class Json {
public:
    enum class Kind { Null, Bool, Number, String, Array, Object };

    Json() = default;
    Json(std::nullptr_t) {}
    Json(bool b) : kind_(Kind::Bool), b_(b) {}
    Json(int n) : kind_(Kind::Number), n_(n) {}
    Json(int64_t n) : kind_(Kind::Number), n_((double)n) {}
    Json(double n) : kind_(Kind::Number), n_(n) {}
    Json(const char* s) : kind_(Kind::String), s_(s) {}
    Json(std::string s) : kind_(Kind::String), s_(std::move(s)) {}

    static Json array() {
        Json j;
        j.kind_ = Kind::Array;
        return j;
    }
    static Json object() {
        Json j;
        j.kind_ = Kind::Object;
        return j;
    }

    Kind kind() const { return kind_; }
    bool isNull() const { return kind_ == Kind::Null; }
    bool isObject() const { return kind_ == Kind::Object; }
    bool isArray() const { return kind_ == Kind::Array; }
    bool isString() const { return kind_ == Kind::String; }
    bool isNumber() const { return kind_ == Kind::Number; }

    bool asBool() const { return kind_ == Kind::Bool && b_; }
    double asNumber() const { return kind_ == Kind::Number ? n_ : 0; }
    int asInt() const { return (int)asNumber(); }
    const std::string& asString() const;

    // Objeto
    Json& operator[](const std::string& key);  // crea la clave si no existe
    const Json& get(const std::string& key) const;  // Null si no existe
    bool has(const std::string& key) const;
    const std::vector<std::pair<std::string, Json>>& items() const { return obj_; }

    // Arreglo
    void push(Json v);
    size_t size() const { return kind_ == Kind::Array ? arr_.size() : obj_.size(); }
    const Json& at(size_t i) const { return arr_[i]; }
    const std::vector<Json>& elements() const { return arr_; }

    std::string dump() const;
    static bool parse(const std::string& text, Json& out, std::string* error = nullptr);

private:
    Kind kind_ = Kind::Null;
    bool b_ = false;
    double n_ = 0;
    std::string s_;
    std::vector<Json> arr_;
    std::vector<std::pair<std::string, Json>> obj_;  // conserva el orden

    void dumpTo(std::string& out) const;
};
