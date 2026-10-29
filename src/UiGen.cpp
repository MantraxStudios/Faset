#include "UiGen.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <set>
#include <vector>

#include "Common.h"
#include "Xml.h"

namespace {

struct Gen {
    int fileId;
    std::string head;                // usings, namespace, clase y campos (línea 1)
    std::vector<std::string> lines;  // código por línea del XML (índice = línea - 1)
    std::vector<std::string> fields;
    std::set<std::string> names;
    int nextEvent = 1;
    int unnamed = 0;
    bool ok = true;

    void error(int line, const std::string& msg) {
        diag.error(SourceLoc{fileId, line, 1}, msg);
        ok = false;
    }

    void emit(int line, const std::string& code) {
        if ((int)lines.size() < line) lines.resize(line);
        lines[line - 1] += code;
    }

    static std::string lower(std::string s) {
        for (char& c : s) c = (char)std::tolower((unsigned char)c);
        return s;
    }

    static std::string quote(const std::string& s) {
        std::string r = "\"";
        for (char c : s) {
            if (c == '\\' || c == '"') r += '\\', r += c;
            else if (c == '\n') r += "\\n";
            else if (c == '\t') r += "\\t";
            else if (c != '\r') r += c;
        }
        return r + "\"";
    }

    static bool isIdent(const std::string& s) {
        if (s.empty() || !(std::isalpha((unsigned char)s[0]) || s[0] == '_')) return false;
        for (char c : s)
            if (!(std::isalnum((unsigned char)c) || c == '_')) return false;
        return true;
    }

    bool intAttr(const XmlNode& n, const std::string& key, std::string& out) {
        auto it = n.attrs.find(key);
        if (it == n.attrs.end()) return false;
        const std::string& v = it->second;
        bool good = !v.empty();
        for (size_t i = 0; i < v.size(); i++)
            if (!(std::isdigit((unsigned char)v[i]) || (i == 0 && v[i] == '-'))) good = false;
        if (!good) {
            error(n.line, "el atributo '" + key + "' debe ser un número entero (es '" + v + "')");
            out = "0";
            return true;
        }
        out = v;
        return true;
    }

    bool numAttr(const XmlNode& n, const std::string& key, std::string& out) {
        auto it = n.attrs.find(key);
        if (it == n.attrs.end()) return false;
        const std::string& v = it->second;
        char* end = nullptr;
        std::strtod(v.c_str(), &end);
        if (v.empty() || *end) {
            error(n.line, "el atributo '" + key + "' debe ser un número (es '" + v + "')");
            out = "0f";
            return true;
        }
        out = v + (v.find('.') == std::string::npos ? ".0f" : "f");
        return true;
    }

    // "#RGB", "#RRGGBB" o "#RRGGBBAA" -> literal 0xAARRGGBB.
    std::string colorValue(const XmlNode& n, const std::string& key, const std::string& v) {
        std::string hex = v.size() > 1 && v[0] == '#' ? v.substr(1) : "";
        bool good = hex.size() == 3 || hex.size() == 6 || hex.size() == 8;
        for (char c : hex)
            if (!std::isxdigit((unsigned char)c)) good = false;
        if (!good) {
            error(n.line, "el atributo '" + key + "' debe ser un color '#RRGGBB' o '#RRGGBBAA' (es '" + v + "')");
            return "0";
        }
        if (hex.size() == 3) hex = std::string{hex[0], hex[0], hex[1], hex[1], hex[2], hex[2]};
        std::string argb = hex.size() == 8 ? hex.substr(6, 2) + hex.substr(0, 6) : "ff" + hex;
        return "0x" + lower(argb);
    }

    static bool isColorKey(const std::string& k) {
        return k == "Background" || k == "Background2" || k == "Foreground" || k == "BorderColor" || k == "Accent";
    }

    std::string boolValue(const XmlNode& n, const std::string& key, const std::string& v) {
        std::string l = lower(v);
        if (l == "true" || l == "false") return l;
        error(n.line, "el atributo '" + key + "' debe ser 'true' o 'false'");
        return "false";
    }

    std::string enumValue(const XmlNode& n, const std::string& key, const std::string& v, const std::string& type,
                          const std::vector<std::string>& options) {
        for (const std::string& o : options)
            if (lower(o) == lower(v)) return type + "." + o;
        std::string list;
        for (const std::string& o : options) list += (list.empty() ? "" : ", ") + o;
        error(n.line, "valor no válido para '" + key + "': '" + v + "' (opciones: " + list + ")");
        return type + "." + options[0];
    }

    std::string handler(const XmlNode& n, const std::string& key) {
        const std::string& h = n.attrs.at(key);
        if (!isIdent(h)) error(n.line, "'" + key + "' debe ser el nombre de un método (es '" + h + "')");
        return h;
    }

    void widget(const XmlNode& n, const std::string& parent) {
        static const std::vector<std::string> kinds = {"Panel",    "Label",       "Button",      "TextBox",  "CheckBox",
                                                       "Slider",   "ProgressBar", "RadioButton", "ComboBox", "ListBox"};
        if (std::find(kinds.begin(), kinds.end(), n.name) == kinds.end()) {
            error(n.line, "control desconocido '<" + n.name + ">' (válidos: Panel, Label, Button, TextBox, CheckBox, Slider, "
                          "ProgressBar, RadioButton, ComboBox, ListBox)");
            return;
        }
        std::string name;
        auto nm = n.attrs.find("Name");
        if (nm != n.attrs.end()) {
            name = nm->second;
            if (!isIdent(name)) error(n.line, "'Name' debe ser un identificador válido (es '" + name + "')");
            else if (name == "Window" || !names.insert(name).second) error(n.line, "ya existe un control llamado '" + name + "'");
        } else {
            name = "__ui" + std::to_string(++unnamed);
        }
        fields.push_back(name);

        std::string x = "0", y = "0", w = "100", h = "32";
        intAttr(n, "X", x);
        intAttr(n, "Y", y);
        intAttr(n, "Width", w);
        intAttr(n, "Height", h);
        std::string code = name + " = " + parent + ".Add(Widget.Create(WidgetKind." + n.name + ", " + quote(name) + ", " + x +
                           ", " + y + ", " + w + ", " + h + "));";
        std::string events;
        std::string post;  // SelectedIndex va después de Items, esté donde esté en el XML
        int clickId = 0, changedId = 0;
        for (const std::string& key : n.attrOrder) {
            const std::string& v = n.attrs.at(key);
            std::string num;
            if (key == "Name" || key == "X" || key == "Y" || key == "Width" || key == "Height") continue;
            if (key == "Text" || key == "Placeholder" || key == "Group") code += " " + name + "." + key + " = " + quote(v) + ";";
            else if (key == "Items") code += " " + name + ".SetItems(" + quote(v) + ");";
            else if (key == "SelectedIndex") intAttr(n, key, num), post += " " + name + ".SelectedIndex = " + num + ";";
            else if (key == "FontSize") intAttr(n, key, num), code += " " + name + ".FontSize = " + num + ";";
            else if (key == "CornerRadius") intAttr(n, key, num), code += " " + name + ".CornerRadius = " + num + ";";
            else if (key == "Bold" || key == "Checked" || key == "Enabled" || key == "Visible")
                code += " " + name + "." + key + " = " + boolValue(n, key, v) + ";";
            else if (key == "Value" || key == "Min" || key == "Max") numAttr(n, key, num), code += " " + name + "." + key + " = " + num + ";";
            else if (key == "Style")
                code += " " + name + ".Style = " + enumValue(n, key, v, "WidgetStyle", {"Default", "Primary", "Subtle", "Danger"}) + ";";
            else if (isColorKey(key)) code += " " + name + "." + key + " = " + colorValue(n, key, v) + ";";
            else if (key == "GradientDirection")
                code += " " + name + ".GradientHorizontal = " +
                        (enumValue(n, key, v, "TextAlign", {"Vertical", "Horizontal"}) == "TextAlign.Horizontal" ? "true" : "false") + ";";
            else if (key == "TextAlign")
                code += " " + name + ".TextAlign = " + enumValue(n, key, v, "TextAlign", {"Left", "Center", "Right"}) + ";";
            else if (key == "Anchor") {
                std::string flags;
                size_t start = 0;
                while (start <= v.size()) {
                    size_t comma = v.find(',', start);
                    std::string part = v.substr(start, comma == std::string::npos ? std::string::npos : comma - start);
                    part.erase(0, part.find_first_not_of(" "));
                    part.erase(part.find_last_not_of(" ") + 1);
                    if (!part.empty()) flags += (flags.empty() ? "" : " | ") + enumValue(n, key, part, "Anchor", {"Left", "Top", "Right", "Bottom"});
                    if (comma == std::string::npos) break;
                    start = comma + 1;
                }
                if (!flags.empty()) code += " " + name + ".Anchor = " + flags + ";";
            } else if (key == "Click") {
                clickId = nextEvent++;
                events += " if (ev == " + std::to_string(clickId) + ") " + handler(n, key) + "(sender);";
            } else if (key == "Changed") {
                changedId = nextEvent++;
                events += " if (ev == " + std::to_string(changedId) + ") " + handler(n, key) + "(sender);";
            } else {
                error(n.line, "atributo desconocido '" + key + "' en <" + n.name + ">");
            }
        }
        code += post;
        // El enlace de eventos pasa 'this' como void*: es código memory_unsafe generado (confiable).
        if (clickId || changedId)
            code += " memory_unsafe { " + name + ".SetEvents(&__ui_event, (void*)this, " + std::to_string(clickId) + ", " +
                    std::to_string(changedId) + "); }";
        emit(n.line, " if (ev == 0) { " + code + " }" + events);
        if (!n.children.empty() && n.name != "Panel") error(n.children[0].line, "solo <Panel> puede contener otros controles");
        for (const XmlNode& c : n.children) widget(c, name);
    }
};

}  // namespace

std::string generateUiSource(const std::string& xml, int fileId) {
    XmlNode root;
    std::string err;
    Gen g;
    g.fileId = fileId;
    if (!parseXml(xml, root, err)) {
        g.error(1, "XML no válido: " + err);
        return "";
    }
    if (root.name != "Window") {
        g.error(root.line, "el elemento raíz de un .fstui debe ser <Window>");
        return "";
    }
    auto attr = [&](const std::string& k, const std::string& def) {
        auto it = root.attrs.find(k);
        return it == root.attrs.end() ? def : it->second;
    };
    std::string cls = attr("Class", "");
    if (!Gen::isIdent(cls)) {
        g.error(root.line, "<Window> necesita un atributo 'Class' con el nombre de la clase (p. ej. Class=\"MainWindow\")");
        return "";
    }
    std::string ns = attr("Namespace", "");
    std::string w = "800", h = "600";
    g.intAttr(root, "Width", w);
    g.intAttr(root, "Height", h);
    std::string code = "Window = new Window(" + Gen::quote(attr("Title", cls)) + ", " + w + ", " + h + ");";
    for (const std::string& key : root.attrOrder) {
        const std::string& v = root.attrs.at(key);
        std::string num;
        if (key == "Class" || key == "Namespace" || key == "Title" || key == "Width" || key == "Height") continue;
        if (key == "Theme") code += " Window.Theme = " + g.enumValue(root, key, v, "UiTheme", {"Dark", "Light"}) + ";";
        else if (key == "Resizable") code += " Window.Resizable = " + g.boolValue(root, key, v) + ";";
        else if (key == "MinWidth" || key == "MinHeight") g.intAttr(root, key, num), code += " Window." + key + " = " + num + ";";
        else if (key == "Background" || key == "Background2") code += " Window." + key + " = " + g.colorValue(root, key, v) + ";";
        else if (key == "GradientDirection")
            code += " Window.GradientHorizontal = " +
                    std::string(g.enumValue(root, key, v, "X", {"Vertical", "Horizontal"}) == "X.Horizontal" ? "true" : "false") + ";";
        else g.error(root.line, "atributo desconocido '" + key + "' en <Window>");
    }
    g.emit(root.line, " if (ev == 0) { " + code + " }");
    for (const XmlNode& c : root.children) g.widget(c, "Window");

    // Línea 1: todo lo que no corresponde a un control concreto.
    std::string head = "using std; using std.ui;";
    if (!ns.empty()) head += " namespace " + ns + " {";
    head += " public partial class " + cls + " { public Window Window;";
    for (const std::string& f : g.fields) head += " Widget " + f + ";";
    head += " void InitializeComponent() { __ui_build(0, null); }";
    head += " memory_unsafe static void __ui_event(void* self, Widget sender, int ev) { ((" + cls +
            ")self).__ui_build(ev, sender); }";
    head += " void __ui_build(int ev, Widget sender) {";
    std::string out = head;
    for (size_t i = 0; i < g.lines.size(); i++) {
        if (i > 0) out += "\n";
        out += g.lines[i];
    }
    out += " }" + std::string(" }") + (ns.empty() ? "" : " }") + "\n";
    return out;
}
