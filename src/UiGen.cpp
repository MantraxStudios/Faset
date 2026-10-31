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
    int windowWidth = 800;
    std::vector<std::pair<std::string, std::string>> typedFields;  // (tipo, nombre): nodos de TreeView, VideoPlayer, Sound...
    bool audio = false;                                            // hay <Sound>/<Music>: using std.audio
    std::string late;                                              // código que va después de crear todo
    std::set<std::string> contextMenus;                            // nombres de los <ContextMenu>
    std::vector<std::pair<int, std::string>> menuRefs;             // ContextMenu="..." (línea, nombre)
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
            error(n.line, "attribute '" + key + "' must be an integer (it is '" + v + "')");
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
            error(n.line, "attribute '" + key + "' must be a number (it is '" + v + "')");
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
            error(n.line, "attribute '" + key + "' must be a color '#RRGGBB' or '#RRGGBBAA' (it is '" + v + "')");
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
        error(n.line, "attribute '" + key + "' must be 'true' or 'false'");
        return "false";
    }

    std::string enumValue(const XmlNode& n, const std::string& key, const std::string& v, const std::string& type,
                          const std::vector<std::string>& options) {
        for (const std::string& o : options)
            if (lower(o) == lower(v)) return type + "." + o;
        std::string list;
        for (const std::string& o : options) list += (list.empty() ? "" : ", ") + o;
        error(n.line, "invalid value for '" + key + "': '" + v + "' (options: " + list + ")");
        return type + "." + options[0];
    }

    std::string handler(const XmlNode& n, const std::string& key) {
        const std::string& h = n.attrs.at(key);
        if (!isIdent(h)) error(n.line, "'" + key + "' must be the name of a method (it is '" + h + "')");
        return h;
    }

    // Tipos de elemento: controles visuales, páginas, elementos de menú, componentes y nodos.
    static bool isVisual(const std::string& k) {
        static const std::set<std::string> v = {"Panel",    "Label",   "Button",     "TextBox",    "CheckBox",
                                                "Slider",   "ProgressBar", "RadioButton", "ComboBox", "ListBox",
                                                "PictureBox", "TabControl", "TreeView", "MenuBar",  "Canvas",
                                                "WebView",  "VideoPlayer"};
        return v.count(k) != 0;
    }
    static bool isMenuEntry(const std::string& k) { return k == "Menu" || k == "MenuItem" || k == "Separator"; }
    static bool isComponent(const std::string& k) { return k == "Timer" || k == "ContextMenu"; }
    static bool isAudio(const std::string& k) { return k == "Sound" || k == "Music"; }
    static bool isMenuOwner(const std::string& k) { return k == "MenuBar" || k == "Menu" || k == "MenuItem" || k == "ContextMenu"; }

    // Comprueba que 'n' puede ir dentro de un elemento 'parentKind'.
    bool placementOk(const XmlNode& n, const std::string& parentKind) {
        const std::string& k = n.name;
        bool known = isVisual(k) || isMenuEntry(k) || isComponent(k) || isAudio(k) || k == "TabPage" || k == "TreeNode";
        if (!known) {
            error(n.line, "unknown control '<" + k + ">' (valid: Panel, Label, Button, TextBox, CheckBox, Slider, "
                          "ProgressBar, RadioButton, ComboBox, ListBox, PictureBox, TabControl, TreeView, MenuBar, Canvas, "
                          "WebView, VideoPlayer, Timer, ContextMenu, Sound and Music)");
            return false;
        }
        std::string where;
        if (k == "TabPage") {
            if (parentKind != "TabControl") where = "<TabPage> can only go inside <TabControl>";
        } else if (k == "TreeNode") {
            if (parentKind != "TreeView" && parentKind != "TreeNode") where = "<TreeNode> can only go inside <TreeView> or another <TreeNode>";
        } else if (isMenuEntry(k)) {
            if (!isMenuOwner(parentKind)) where = "<" + k + "> can only go inside <MenuBar>, <ContextMenu>, or another <Menu>";
        } else if (isComponent(k) || isAudio(k)) {
            if (parentKind != "Window") where = "<" + k + "> is a component: it goes directly inside <Window>";
        } else if (parentKind == "TabControl") {
            where = "<TabControl> can only contain <TabPage> (put <" + k + "> inside a page)";
        } else if (parentKind == "TreeView" || parentKind == "TreeNode") {
            where = "<" + parentKind + "> can only contain <TreeNode>";
        } else if (isMenuOwner(parentKind)) {
            where = "<" + parentKind + "> can only contain <Menu>, <MenuItem>, and <Separator>";
        } else if (parentKind != "Window" && parentKind != "Panel" && parentKind != "TabPage") {
            where = "only <Window>, <Panel>, and <TabPage> can contain controls (<" + parentKind + "> cannot)";
        }
        if (!where.empty()) {
            error(n.line, where);
            return false;
        }
        return true;
    }

    void node(const XmlNode& n, const std::string& parent, const std::string& parentKind) {
        if (!placementOk(n, parentKind)) return;
        if (isAudio(n.name)) component(n);
        else if (n.name == "TreeNode") treeNode(n, parent, parentKind == "TreeView");
        else widget(n, parent, parentKind);
    }

    std::string fieldName(const XmlNode& n, const std::string& prefix) {
        auto nm = n.attrs.find("Name");
        if (nm != n.attrs.end()) {
            const std::string& name = nm->second;
            if (!isIdent(name)) error(n.line, "'Name' must be a valid identifier (it is '" + name + "')");
            else if (name == "Window" || !names.insert(name).second) error(n.line, "a control named '" + name + "' already exists");
            return name;
        }
        return prefix + std::to_string(++unnamed);
    }

    // <TreeNode Text="..." Expanded="true" Tag="..." Name="...">: campo TreeNode (no es un Widget).
    void treeNode(const XmlNode& n, const std::string& parent, bool parentIsView) {
        std::string name = fieldName(n, "__tn");
        typedFields.push_back({"TreeNode", name});
        auto t = n.attrs.find("Text");
        std::string code = name + " = " + parent + (parentIsView ? ".AddNode(" : ".Add(") +
                           quote(t == n.attrs.end() ? "" : t->second) + ");";
        for (const std::string& key : n.attrOrder) {
            const std::string& v = n.attrs.at(key);
            if (key == "Name" || key == "Text") continue;
            if (key == "Tag") code += " " + name + ".Tag = " + quote(v) + ";";
            else if (key == "Expanded") code += " " + name + ".Expanded = " + boolValue(n, key, v) + ";";
            else error(n.line, "unknown attribute '" + key + "' on <TreeNode> (valid: Name, Text, Expanded, Tag)");
        }
        emit(n.line, " if (ev == 0) { " + code + " }");
        for (const XmlNode& c : n.children) node(c, name, "TreeNode");
    }

    // <VideoPlayer>: atributos propios del reproductor. Devuelve true si 'key' era uno de ellos.
    bool videoAttr(const XmlNode& n, const std::string& name, const std::string& key, const std::string& v, std::string& vcode,
                   std::string& vpost, std::string& events, int ids[3]) {
        std::string num;
        if (key == "Source") vcode += " " + name + ".Source = " + quote(v) + ";";
        else if (key == "AutoPlay") vpost += " " + name + ".AutoPlay = " + boolValue(n, key, v) + ";";
        else if (key == "Loop" || key == "ShowControls") vcode += " " + name + "." + key + " = " + boolValue(n, key, v) + ";";
        else if (key == "Volume") numAttr(n, key, num), vcode += " " + name + ".Volume = " + num + ";";
        else if (key == "Stretch")
            vcode += " " + name + ".Stretch = " + enumValue(n, key, v, "VideoStretch", {"Uniform", "Fill", "None"}) + ";";
        else if (key == "Opened" || key == "Ended" || key == "Failed") {
            int slot = key == "Opened" ? 0 : key == "Ended" ? 1 : 2;
            ids[slot] = nextEvent++;
            events += " if (ev == " + std::to_string(ids[slot]) + ") " + handler(n, key) + "(sender);";
        } else return false;
        return true;
    }

    // El campo de un <VideoPlayer> es un VideoPlayer: los atributos comunes van a su control (.View).
    static std::string videoCode(const std::string& name, const std::string& code) {
        std::string out = code, from = " " + name + ".", to = " " + name + ".View.";
        for (size_t k = out.find(from); k != std::string::npos; k = out.find(from, k + to.size())) out.replace(k, from.size(), to);
        std::string add = name + " = ";
        if (out.rfind(add, 0) == 0) {
            size_t semi = out.find(");");
            out = add + "new VideoPlayer(" + out.substr(add.size(), semi + 1 - add.size()) + ")" + out.substr(semi + 1);
        }
        return out;
    }

    // <Sound Name="Click" Source="click.wav" Volume="0.8" Loop="false" AutoPlay="false"/> y <Music .../>:
    // campo de tipo Sound o Music (std.audio) cargado en InitializeComponent.
    bool component(const XmlNode& n) {
        if (n.name != "Sound" && n.name != "Music") return false;
        std::string name = fieldName(n, "__ui");
        typedFields.push_back({n.name, name});
        audio = true;
        auto src = n.attrs.find("Source");
        if (src == n.attrs.end() || src->second.empty())
            error(n.line, "<" + n.name + "> needs a 'Source' attribute with the audio file (WAV, OGG, or MP3)");
        std::string code = name + " = " + n.name + ".Load(" + quote(src == n.attrs.end() ? "" : src->second) + ");";
        std::string autoPlay;
        for (const std::string& key : n.attrOrder) {
            const std::string& v = n.attrs.at(key);
            std::string num;
            if (key == "Name" || key == "Source") continue;
            if (key == "Volume" || key == "Pan" || key == "Speed") numAttr(n, key, num), code += " " + name + "." + key + " = " + num + ";";
            else if (key == "Loop") code += " " + name + ".Loop = " + boolValue(n, key, v) + ";";
            else if (key == "AutoPlay") autoPlay = boolValue(n, key, v) == "true" ? " " + name + ".Play();" : "";
            else error(n.line, "unknown attribute '" + key + "' on <" + n.name + "> (valid: Name, Source, Volume, Pan, Speed, Loop, AutoPlay)");
        }
        emit(n.line, " if (ev == 0) { " + code + autoPlay + " }");
        if (!n.children.empty()) error(n.children[0].line, "<" + n.name + "> cannot contain other elements");
        return true;
    }

    static std::string eventCall(const std::string& ev, const std::string& h) {
        if (ev == "Paint") return h + "(sender, sender.Graphics);";
        if (ev == "MouseDown" || ev == "MouseMove" || ev == "MouseUp") return h + "(sender, sender.Mouse);";
        return h + "(sender);";
    }

    void widget(const XmlNode& n, const std::string& parent, const std::string& parentKind) {
        std::string kind = isMenuEntry(n.name) ? "MenuItem" : n.name;
        std::string name = fieldName(n, "__ui");
        bool video = kind == "VideoPlayer";
        if (video) typedFields.push_back({"VideoPlayer", name});
        else fields.push_back(name);
        std::string vcode, vpost;  // VideoPlayer: código propio (AutoPlay va al final, tras Source)
        int videoIds[3] = {0, 0, 0};
        int webEvents[3] = {0, 0, 0};  // WebView: Navigated, TitleChanged, MessageReceived

        std::string x = "0", y = "0", w = "100", h = "32";
        bool sized = kind != "TabPage" && kind != "MenuItem" && !isComponent(kind);
        if (kind == "MenuBar") w = std::to_string(windowWidth), h = "30";
        if (sized) {
            intAttr(n, "X", x);
            intAttr(n, "Y", y);
            intAttr(n, "Width", w);
            intAttr(n, "Height", h);
        } else {
            x = y = w = h = "0";
        }
        std::string create = "Widget.Create(WidgetKind." + kind + ", " + quote(name) + ", " + x + ", " + y + ", " + w + ", " + h + ")";
        std::string code = name + " = " + (isComponent(kind) ? "Window.AddComponent(" : parent + ".Add(") + create + ");";
        if (n.name == "Separator") code += " " + name + ".Text = \"-\";";
        if (kind == "MenuBar" && !n.attrs.count("Anchor")) code += " " + name + ".Anchor = Anchor.Left | Anchor.Top | Anchor.Right;";
        std::string events;
        std::string post;  // SelectedIndex va después de Items, esté donde esté en el XML
        std::vector<std::pair<std::string, int>> wired;  // (evento, número)
        for (const std::string& key : n.attrOrder) {
            const std::string& v = n.attrs.at(key);
            std::string num;
            if (key == "Name" || key == "X" || key == "Y" || key == "Width" || key == "Height") {
                if (!sized && key != "Name") error(n.line, "<" + n.name + "> does not allow '" + key + "' (its size is decided by its container)");
                continue;
            }
            if (video && videoAttr(n, name, key, v, vcode, vpost, events, videoIds)) continue;
            if (kind == "WebView" && key == "Html") {
                code += " " + name + ".LoadHtml(" + quote(v) + ");";
                continue;
            }
            if (kind == "WebView" && (key == "Navigated" || key == "TitleChanged" || key == "MessageReceived")) {
                int k = key == "Navigated" ? 0 : key == "TitleChanged" ? 1 : 2;
                webEvents[k] = nextEvent++;
                // MessageReceived recibe también el texto: void Nombre(Widget sender, string message).
                events += " if (ev == " + std::to_string(webEvents[k]) + ") " + handler(n, key) +
                          (k == 2 ? "(sender, sender.Message);" : "(sender);");
                continue;
            }
            if (n.name == "Separator") {
                if (key != "Visible") error(n.line, "<Separator> only allows Name and Visible");
                else code += " " + name + ".Visible = " + boolValue(n, key, v) + ";";
                continue;
            }
            if (key == "Text" || key == "Placeholder" || key == "Group" || key == "Shortcut" || key == "Source")
                code += " " + name + "." + key + " = " + quote(v) + ";";
            else if (key == "Icon") code += " " + name + ".Icon = Image.FromFile(" + quote(v) + ");";
            else if (key == "Items") code += " " + name + ".SetItems(" + quote(v) + ");";
            else if (key == "SelectedIndex") {
                intAttr(n, key, num);
                // Las páginas de un TabControl se añaden después: se elige al final.
                if (kind == "TabControl") late += " " + name + ".SelectedIndex = " + num + ";";
                else post += " " + name + ".SelectedIndex = " + num + ";";
            } else if (key == "FontSize") intAttr(n, key, num), code += " " + name + ".FontSize = " + num + ";";
            else if (key == "CornerRadius") intAttr(n, key, num), code += " " + name + ".CornerRadius = " + num + ";";
            else if (key == "Interval") intAttr(n, key, num), code += " " + name + ".Interval = " + num + ";";
            else if (key == "Bold" || key == "Checked" || key == "Enabled" || key == "Visible")
                code += " " + name + "." + key + " = " + boolValue(n, key, v) + ";";
            else if (key == "Value" || key == "Min" || key == "Max") numAttr(n, key, num), code += " " + name + "." + key + " = " + num + ";";
            else if (key == "Style")
                code += " " + name + ".Style = " + enumValue(n, key, v, "WidgetStyle", {"Default", "Primary", "Subtle", "Danger"}) + ";";
            else if (key == "SizeMode")
                code += " " + name + ".SizeMode = " + enumValue(n, key, v, "PictureSizeMode", {"Normal", "Stretch", "Zoom", "Center", "Cover"}) + ";";
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
            } else if (key == "ContextMenu") {
                if (!isIdent(v)) error(n.line, "'ContextMenu' must be the (Name) of a <ContextMenu> (it is '" + v + "')");
                else {
                    late += " " + name + ".ContextMenu = " + v + ";";
                    menuRefs.push_back({n.line, v});
                }
            } else if (key == "Click" || key == "Changed" || key == "SelectedChanged" || key == "NodeActivated" || key == "Tick" ||
                       key == "Paint" || key == "MouseDown" || key == "MouseMove" || key == "MouseUp") {
                std::string bad;
                if ((key == "Paint" || key == "MouseDown" || key == "MouseMove" || key == "MouseUp") && kind != "Canvas")
                    bad = "only <Canvas>";
                else if (key == "Tick" && kind != "Timer") bad = "only <Timer>";
                else if (key == "NodeActivated" && kind != "TreeView") bad = "only <TreeView>";
                else if (key == "SelectedChanged" && kind != "TabControl" && kind != "TreeView" && kind != "ListBox" && kind != "ComboBox")
                    bad = "only <TabControl>, <TreeView>, <ListBox>, and <ComboBox>";
                if (!bad.empty()) {
                    error(n.line, "event '" + key + "' does not exist on <" + n.name + "> (" + bad + " has it)");
                    continue;
                }
                int id = nextEvent++;
                wired.push_back({key, id});
                events += " if (ev == " + std::to_string(id) + ") " + eventCall(key, handler(n, key));
            } else {
                error(n.line, "unknown attribute '" + key + "' on <" + n.name + ">");
            }
        }
        code += post;
        if (kind == "ContextMenu") contextMenus.insert(name);
        // El enlace de eventos pasa 'this' como void*: es código memory_unsafe generado (confiable).
        bool web = webEvents[0] || webEvents[1] || webEvents[2];
        if (!wired.empty() || web) {
            code += " memory_unsafe { " + name + ".SetEvents(&__ui_event, (void*)this, 0, 0);";
            for (auto& [ev, id] : wired) code += " " + name + ".SetEvent(WidgetEvent." + ev + ", " + std::to_string(id) + ");";
            code += " }";
        }
        if (web)
            code += " " + name + ".SetWebEvents(" + std::to_string(webEvents[0]) + ", " + std::to_string(webEvents[1]) + ", " +
                    std::to_string(webEvents[2]) + ");";
        if (video) {
            code = videoCode(name, code) + vcode + vpost;
            if (videoIds[0] || videoIds[1] || videoIds[2])
                code += " memory_unsafe { " + name + ".SetEvents(&__ui_event, (void*)this, " + std::to_string(videoIds[0]) + ", " +
                        std::to_string(videoIds[1]) + ", " + std::to_string(videoIds[2]) + "); }";
        }
        emit(n.line, " if (ev == 0) { " + code + " }" + events);
        for (const XmlNode& c : n.children) node(c, name, n.name);
    }
};

}  // namespace

std::string generateUiSource(const std::string& xml, int fileId) {
    XmlNode root;
    std::string err;
    Gen g;
    g.fileId = fileId;
    if (!parseXml(xml, root, err)) {
        g.error(1, "invalid XML: " + err);
        return "";
    }
    if (root.name != "Window") {
        g.error(root.line, "the root element of a .fstui must be <Window>");
        return "";
    }
    auto attr = [&](const std::string& k, const std::string& def) {
        auto it = root.attrs.find(k);
        return it == root.attrs.end() ? def : it->second;
    };
    std::string cls = attr("Class", "");
    if (!Gen::isIdent(cls)) {
        g.error(root.line, "<Window> needs a 'Class' attribute with the class name (e.g. Class=\"MainWindow\")");
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
        else g.error(root.line, "unknown attribute '" + key + "' on <Window>");
    }
    g.emit(root.line, " if (ev == 0) { " + code + " }");
    g.windowWidth = std::atoi(w.c_str());
    for (const XmlNode& c : root.children) g.node(c, "Window", "Window");
    for (auto& [line, name] : g.menuRefs)
        if (!g.contextMenus.count(name)) g.error(line, "there is no <ContextMenu Name='" + name + "'> in the window");
    // Referencias entre controles (ContextMenu, páginas elegidas): cuando ya existen todos.
    if (!g.late.empty()) g.emit(std::max<int>(1, (int)g.lines.size()), " if (ev == 0) {" + g.late + " }");

    // Línea 1: todo lo que no corresponde a un control concreto.
    std::string head = "using std; using std.ui;";
    if (g.audio) head += " using std.audio;";
    if (!ns.empty()) head += " namespace " + ns + " {";
    head += " public partial class " + cls + " { public Window Window;";
    for (const std::string& f : g.fields) head += " Widget " + f + ";";
    for (auto& [type, f] : g.typedFields) head += " " + type + " " + f + ";";
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
