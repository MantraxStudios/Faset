#include "XmlIntel.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <filesystem>
#include <set>

#include "Xml.h"

namespace fs = std::filesystem;

namespace {

// ================================================================== esquemas

enum { kElement = 7, kProperty = 10, kValue = 20, kMethod = 2, kFile = 17 };

struct AttrSpec {
    const char* name;
    const char* doc;
    std::vector<std::string> values;  // valores fijos (vacío = libre)
    bool flags = false;               // lista separada por comas (Anchor)
    bool handler = false;             // nombre de un método del código de la ventana
};

struct ElemSpec {
    const char* name;
    const char* doc;
    std::vector<std::string> attrs;     // atributos que se sugieren
    std::vector<std::string> values;    // valores del texto del elemento (propiedades del .fstproj)
    bool isBool = false;
};

const std::vector<std::string> kBool = {"true", "false"};

// ---- .fstproj (ver src/Project.cpp)

const std::vector<ElemSpec>& projectProps() {
    static const std::vector<ElemSpec> v = {
        {"OutputType", "Tipo de salida: Exe (consola), WinExe (aplicación de ventana) o Library (biblioteca).", {}, {"Exe", "WinExe", "Library"}},
        {"AssemblyName", "Nombre del ejecutable o de la biblioteca que se genera (por defecto, el del proyecto).", {}, {}},
        {"RootNamespace", "Namespace principal del proyecto (lo usan las plantillas y el diseñador).", {}, {}},
        {"TargetPlatform", "Plataforma de destino: native (la del sistema), linux, windows, android o macos.", {}, {"native", "linux", "windows", "android", "macos"}},
        {"TargetArch", "Arquitectura de destino: x86_64, x86, arm64 o armv7 (por defecto, la del sistema).", {}, {"x86_64", "x86", "arm64", "armv7"}},
        {"AndroidApi", "Nivel de API de Android (por defecto 24).", {}, {"24", "26", "28", "29", "30", "31", "33", "34"}},
        {"Configuration", "Configuración por defecto: Debug (con símbolos de depuración) o Release (optimizada).", {}, {"Debug", "Release"}},
        {"OutputPath", "Carpeta de salida, relativa al proyecto (por defecto 'bin').", {}, {"bin"}},
        {"StaticLink", "Enlaza las bibliotecas de C de forma estática (true o false).", {}, kBool, true},
        {"EnableDefaultCompileItems", "Compila automáticamente todos los .fst y .fstui de la carpeta (true por defecto).", {}, kBool, true},
        {"Version", "Versión del proyecto (informativa).", {}, {}},
        {"Description", "Descripción del proyecto (informativa).", {}, {}},
        {"Authors", "Autores del proyecto (informativo).", {}, {}},
        {"Optimize", "Fuerza la optimización (true o false).", {}, kBool, true},
        {"DebugSymbols", "Fuerza los símbolos de depuración (true o false).", {}, kBool, true},
        {"RuntimeChecks", "Comprobaciones en ejecución (límites, nulos, delete doble...): por defecto en Debug sí y en Release no.", {}, kBool, true},
        {"AllowUnsafe", "Permite código memory_unsafe en todo el proyecto sin marcarlo (true o false).", {}, kBool, true},
        // Android (APK)
        {"AndroidPackage", "Paquete de la app Android (p. ej. com.empresa.app; por defecto com.faset.<nombre>).", {}, {}},
        {"AppName", "Nombre visible de la app en Android.", {}, {}},
        {"VersionCode", "Número de versión interno de Android (entero que crece en cada publicación).", {}, {"1"}},
        {"VersionName", "Versión visible de la app Android (p. ej. 1.0).", {}, {"1.0"}},
        {"AndroidAbis", "ABIs del APK separadas por ';' (por defecto arm64-v8a;x86_64).", {},
         {"arm64-v8a;x86_64", "arm64-v8a", "x86_64", "armeabi-v7a", "x86"}},
        {"AndroidTargetSdk", "SDK objetivo de Android (por defecto, la plataforma más nueva instalada).", {}, {"34", "35", "36"}},
        {"AndroidOrientation", "Orientación de la app Android.", {}, {"portrait", "landscape", "sensor", "unspecified"}},
        {"AndroidIcon", "Icono de la app Android (PNG, relativo al proyecto).", {}, {"icon.png"}},
        {"AndroidKeystore", "Almacén de claves para firmar el APK (por defecto ~/.android/debug.keystore).", {}, {}},
        {"AndroidKeyAlias", "Alias de la clave de firma del APK.", {}, {}},
        {"AndroidKeystorePassword", "Contraseña del almacén (mejor: variable FASET_ANDROID_KEYSTORE_PASSWORD).", {}, {}},
        {"AndroidKeyPassword", "Contraseña de la clave (mejor: variable FASET_ANDROID_KEY_PASSWORD).", {}, {}},
    };
    return v;
}

const std::vector<ElemSpec>& projectItems() {
    static const std::vector<ElemSpec> v = {
        {"Compile", "Archivos que se compilan: Include añade (admite '*' y '**'), Remove excluye.", {"Include", "Remove"}, {}},
        {"NativeLibrary", "Biblioteca nativa con la que se enlaza (p. ej. 'm', 'user32'); Platform la limita a un sistema.",
         {"Include", "Platform"}, {}},
        {"LibraryPath", "Carpeta donde buscar bibliotecas nativas, relativa al proyecto.", {"Include"}, {}},
        {"ProjectReference", "Otro proyecto Faset (.fstproj) cuyo código se compila junto con este.", {"Include"}, {}},
        {"AndroidPermission", "Permiso de Android que pide la app (p. ej. INTERNET, CAMERA).", {"Include"}, {}},
    };
    return v;
}

const std::vector<AttrSpec>& projectAttrs() {
    static const std::vector<AttrSpec> v = {
        {"Include", "Elementos que se añaden (lista separada por ';').", {}},
        {"Remove", "Elementos que se excluyen (lista separada por ';', admite '*' y '**').", {}},
        {"Platform", "Sistema en el que se aplica: linux, windows, android o macos.", {"linux", "windows", "android", "macos"}},
    };
    return v;
}

const ElemSpec kProjectRoot = {"Project", "Proyecto de Faset: grupos <PropertyGroup> con propiedades y <ItemGroup> con archivos y referencias.", {}, {}};
const ElemSpec kPropertyGroup = {"PropertyGroup", "Propiedades del proyecto (OutputType, AssemblyName, TargetPlatform...).", {}, {}};
const ElemSpec kItemGroup = {"ItemGroup", "Elementos del proyecto: Compile, NativeLibrary, LibraryPath y ProjectReference.", {}, {}};

// ---- .fstui (ver src/UiGen.cpp)

const std::vector<AttrSpec>& uiAttrs() {
    static const std::vector<AttrSpec> v = {
        {"Class", "Nombre de la clase 'partial' que genera la ventana (el código va en Nombre.fst).", {}},
        {"Namespace", "Namespace de la clase de la ventana.", {}},
        {"Title", "Título de la ventana.", {}},
        {"Theme", "Tema de colores de la ventana.", {"Dark", "Light"}},
        {"Resizable", "Si el usuario puede cambiar el tamaño de la ventana.", kBool},
        {"MinWidth", "Ancho mínimo de la ventana, en píxeles.", {}},
        {"MinHeight", "Alto mínimo de la ventana, en píxeles.", {}},
        {"Name", "Nombre del control: se genera un campo 'Widget' con este nombre en la clase.", {}},
        {"X", "Posición horizontal, en píxeles, dentro del contenedor.", {}},
        {"Y", "Posición vertical, en píxeles, dentro del contenedor.", {}},
        {"Width", "Ancho en píxeles.", {}},
        {"Height", "Alto en píxeles.", {}},
        {"Text", "Texto del control.", {}},
        {"Placeholder", "Texto de ayuda que se muestra mientras el cuadro está vacío.", {}},
        {"FontSize", "Tamaño de la letra, en píxeles.", {"11", "12", "13", "14", "16", "18", "20", "24", "32"}},
        {"Bold", "Texto en negrita.", kBool},
        {"Enabled", "Si el control responde al usuario.", kBool},
        {"Visible", "Si el control se muestra.", kBool},
        {"Checked", "Estado marcado de la casilla o del botón de opción.", kBool},
        {"CornerRadius", "Radio de las esquinas redondeadas, en píxeles.", {"0", "4", "6", "8", "12"}},
        {"Style", "Estilo visual del control.", {"Default", "Primary", "Subtle", "Danger"}},
        {"TextAlign", "Alineación horizontal del texto.", {"Left", "Center", "Right"}},
        {"Anchor", "Bordes del contenedor a los que se ancla el control al cambiar de tamaño (lista separada por comas).",
         {"Left", "Top", "Right", "Bottom"}, true},
        {"Value", "Valor actual.", {}},
        {"Min", "Valor mínimo.", {}},
        {"Max", "Valor máximo.", {}},
        {"Group", "Grupo de botones de opción: solo uno de cada grupo puede estar marcado.", {}},
        {"Items", "Elementos de la lista, separados por ';'.", {}},
        {"SelectedIndex", "Índice del elemento seleccionado (-1: ninguno).", {"-1", "0"}},
        {"Background", "Color de fondo ('#RRGGBB' o '#RRGGBBAA').", {}},
        {"Background2", "Segundo color del degradado de fondo ('#RRGGBB').", {}},
        {"GradientDirection", "Dirección del degradado entre Background y Background2.", {"Vertical", "Horizontal"}},
        {"Foreground", "Color del texto ('#RRGGBB').", {}},
        {"BorderColor", "Color del borde ('#RRGGBB').", {}},
        {"Accent", "Color de acento: relleno de casillas, barras y deslizadores ('#RRGGBB').", {}},
        {"Click", "Método que se llama al hacer clic: void Nombre(Widget sender).", {}, false, true},
        {"Changed", "Método que se llama cuando cambia el valor: void Nombre(Widget sender).", {}, false, true},
        // Controles de imágenes, pestañas, árbol, menús, temporizador y lienzo
        {"Source", "Imagen que se muestra (PNG, JPEG, BMP o GIF), relativa al proyecto; se busca también junto al ejecutable y, en Android, dentro del APK.", {}},
        {"SizeMode", "Cómo se coloca la imagen: Normal (arriba a la izquierda), Stretch (estirada), Zoom (cabe entera sin deformarse), Center (centrada) o Cover (llena y recorta).",
         {"Normal", "Stretch", "Zoom", "Center", "Cover"}},
        {"Icon", "Icono (PNG, JPEG, BMP o GIF) que se dibuja a la izquierda del texto.", {}},
        {"Shortcut", "Atajo de teclado del elemento de menú (Ctrl+S, Ctrl+Shift+N, F5, Supr...): funciona aunque el menú esté cerrado.",
         {"Ctrl+N", "Ctrl+O", "Ctrl+S", "Ctrl+Shift+S", "Ctrl+Z", "Ctrl+Y", "Ctrl+Q", "F1", "F5", "Supr"}},
        {"Interval", "Milisegundos entre dos Tick del temporizador.", {"16", "100", "500", "1000"}},
        {"Expanded", "Si el nodo muestra sus hijos.", kBool},
        {"Tag", "Dato libre del nodo (una ruta, un identificador...): TreeNode.Tag.", {}},
        {"ContextMenu", "Menú contextual (Name de un <ContextMenu> de la ventana) que se abre con el botón derecho.", {}},
        {"SelectedChanged", "Método que se llama al cambiar la selección (pestaña, nodo o elemento): void Nombre(Widget sender).", {}, false, true},
        {"NodeActivated", "Método que se llama con doble clic o Enter sobre un nodo: void Nombre(Widget sender).", {}, false, true},
        {"Tick", "Método que se llama cada Interval milisegundos: void Nombre(Widget sender).", {}, false, true},
        {"Paint", "Método que dibuja el lienzo: void Nombre(Widget sender, Graphics g).", {}, false, true},
        {"MouseDown", "Botón del ratón pulsado sobre el lienzo: void Nombre(Widget sender, MouseArgs e).", {}, false, true},
        {"MouseMove", "Ratón movido sobre el lienzo: void Nombre(Widget sender, MouseArgs e).", {}, false, true},
        {"MouseUp", "Botón del ratón soltado: void Nombre(Widget sender, MouseArgs e).", {}, false, true},
    };
    return v;
}

#define FST_COMMON "Name", "X", "Y", "Width", "Height", "Anchor", "Enabled", "Visible", "Style", "FontSize", "Bold", \
                   "CornerRadius", "Background", "Background2", "GradientDirection", "Foreground", "BorderColor"

const std::vector<ElemSpec>& uiControls() {
    static const std::vector<ElemSpec> v = {
        {"Panel", "Contenedor de otros controles.", {FST_COMMON, "Text", "Click"}, {}},
        {"Label", "Texto estático.", {FST_COMMON, "Text", "TextAlign", "Click"}, {}},
        {"Button", "Botón: el atributo Click indica el método que se llama al pulsarlo.", {FST_COMMON, "Text", "TextAlign", "Accent", "Click"}, {}},
        {"TextBox", "Cuadro de texto editable: Changed se llama al escribir.", {FST_COMMON, "Text", "Placeholder", "TextAlign", "Accent", "Changed"}, {}},
        {"CheckBox", "Casilla de verificación.", {FST_COMMON, "Text", "Checked", "Accent", "Click", "Changed"}, {}},
        {"Slider", "Deslizador para elegir un número entre Min y Max.", {FST_COMMON, "Value", "Min", "Max", "Accent", "Changed"}, {}},
        {"ProgressBar", "Barra de progreso entre Min y Max.", {FST_COMMON, "Value", "Min", "Max", "Accent"}, {}},
        {"RadioButton", "Botón de opción: solo uno de cada Group puede estar marcado.", {FST_COMMON, "Text", "Checked", "Group", "Accent", "Click", "Changed"}, {}},
        {"ComboBox", "Lista desplegable: Items separados por ';'.", {FST_COMMON, "Items", "SelectedIndex", "Accent", "Changed"}, {}},
        {"ListBox", "Lista de elementos: Items separados por ';'.", {FST_COMMON, "Items", "SelectedIndex", "Accent", "Changed", "SelectedChanged"}, {}},
        {"PictureBox", "Imagen (PNG, JPEG, BMP o GIF) con SizeMode Normal, Stretch, Zoom, Center o Cover.",
         {"Name", "X", "Y", "Width", "Height", "Anchor", "Visible", "Source", "SizeMode", "CornerRadius", "Background", "Background2",
          "GradientDirection", "BorderColor", "ContextMenu", "Click"}, {}},
        {"TabControl", "Páginas con pestañas: contiene elementos <TabPage>; Ctrl+Tab cambia de página.",
         {FST_COMMON, "SelectedIndex", "Accent", "ContextMenu", "SelectedChanged"}, {}},
        {"TreeView", "Árbol de nodos que se expanden y contraen: contiene elementos <TreeNode>.",
         {FST_COMMON, "ContextMenu", "SelectedChanged", "NodeActivated"}, {}},
        {"MenuBar", "Barra de menús (arriba de la ventana): contiene elementos <Menu>.",
         {"Name", "X", "Y", "Width", "Height", "Anchor", "Visible", "FontSize", "Background", "Foreground", "BorderColor"}, {}},
        {"Canvas", "Lienzo de dibujo libre: Paint recibe un Graphics; MouseDown/MouseMove/MouseUp, un MouseArgs.",
         {"Name", "X", "Y", "Width", "Height", "Anchor", "Enabled", "Visible", "CornerRadius", "Background", "Background2",
          "GradientDirection", "BorderColor", "ContextMenu", "Paint", "MouseDown", "MouseMove", "MouseUp"}, {}},
        {"Timer", "Temporizador (componente no visual): lanza Tick cada Interval milisegundos mientras Enabled es true.",
         {"Name", "Interval", "Enabled", "Tick"}, {}},
        {"ContextMenu", "Menú contextual (componente no visual): se abre con el botón derecho sobre los controles que lo nombran.",
         {"Name", "FontSize"}, {}},
    };
    return v;
}

// Elementos que solo van dentro de otro (páginas, nodos y menús).
const std::vector<ElemSpec>& uiParts() {
    static const std::vector<ElemSpec> v = {
        {"TabPage", "Página de un <TabControl>: contiene los controles que se ven al elegir su pestaña.",
         {"Name", "Text", "Enabled", "Background", "Background2", "GradientDirection"}, {}},
        {"TreeNode", "Nodo de un <TreeView> (puede contener otros nodos). Con Name se genera un campo TreeNode.",
         {"Name", "Text", "Expanded", "Tag"}, {}},
        {"Menu", "Menú desplegable de un <MenuBar> o submenú: contiene <MenuItem>, <Menu> y <Separator>.",
         {"Name", "Text", "Enabled", "Visible", "Icon"}, {}},
        {"MenuItem", "Elemento de un menú: Click se llama al elegirlo; Shortcut es su atajo de teclado.",
         {"Name", "Text", "Shortcut", "Icon", "Checked", "Enabled", "Visible", "Click"}, {}},
        {"Separator", "Línea que separa grupos de elementos de un menú.", {"Name", "Visible"}, {}},
    };
    return v;
}

const ElemSpec kUiWindow = {"Window",
                            "Ventana de la interfaz. Genera una clase 'partial' con un campo por control y el método InitializeComponent().",
                            {"Class", "Namespace", "Title", "Width", "Height", "Theme", "Resizable", "MinWidth", "MinHeight", "Background",
                             "Background2", "GradientDirection"},
                            {}};

template <class T>
const T* findSpec(const std::vector<T>& v, const std::string& name) {
    for (const T& s : v)
        if (name == s.name) return &s;
    return nullptr;
}

const AttrSpec* uiAttr(const std::string& n) { return findSpec(uiAttrs(), n); }

const ElemSpec* uiElem(const std::string& n) {
    if (n == "Window") return &kUiWindow;
    if (const ElemSpec* p = findSpec(uiParts(), n)) return p;
    return findSpec(uiControls(), n);
}

bool uiIsComponent(const std::string& n) { return n == "Timer" || n == "ContextMenu"; }
bool uiIsMenuOwner(const std::string& n) { return n == "MenuBar" || n == "Menu" || n == "MenuItem" || n == "ContextMenu"; }

// Texto que se inserta al completar el elemento 'name' (etiqueta recién empezada).
std::string uiSnippet(const std::string& name) {
    if (name == "TabControl")
        return "TabControl Name=\"$0\" X=\"0\" Y=\"0\" Width=\"400\" Height=\"300\">\n  <TabPage Text=\"Página 1\">\n  </TabPage>\n</TabControl>";
    if (name == "TreeView") return "TreeView Name=\"$0\" X=\"0\" Y=\"0\" Width=\"220\" Height=\"260\">\n</TreeView>";
    if (name == "MenuBar") return "MenuBar Name=\"$0\">\n  <Menu Text=\"Archivo\">\n  </Menu>\n</MenuBar>";
    if (name == "TabPage") return "TabPage Text=\"$0\">\n</TabPage>";
    if (name == "TreeNode") return "TreeNode Text=\"$0\" />";
    if (name == "Menu") return "Menu Text=\"$0\">\n</Menu>";
    if (name == "MenuItem") return "MenuItem Text=\"$0\" Click=\"\" />";
    if (name == "Separator") return "Separator />";
    if (name == "ContextMenu") return "ContextMenu Name=\"$0\">\n  <MenuItem Text=\"\" Click=\"\" />\n</ContextMenu>";
    if (name == "Timer") return "Timer Name=\"$0\" Interval=\"1000\" Enabled=\"true\" Tick=\"\" />";
    return name + " Name=\"$0\" X=\"0\" Y=\"0\" Width=\"120\" Height=\"32\"" + (name == "Panel" ? "></Panel>" : " />");
}

// Parámetros del manejador de un evento.
std::string uiHandlerParams(const std::string& ev) {
    if (ev == "Paint") return "Widget sender, Graphics g";
    if (ev == "MouseDown" || ev == "MouseMove" || ev == "MouseUp") return "Widget sender, MouseArgs e";
    return "Widget sender";
}

const ElemSpec* projectElem(const std::string& n) {
    if (n == "Project") return &kProjectRoot;
    if (n == "PropertyGroup") return &kPropertyGroup;
    if (n == "ItemGroup") return &kItemGroup;
    if (const ElemSpec* p = findSpec(projectProps(), n)) return p;
    return findSpec(projectItems(), n);
}

std::string joinValues(const std::vector<std::string>& v, const char* sep = ", ") {
    std::string r;
    for (const std::string& s : v) r += (r.empty() ? "" : sep) + s;
    return r;
}

// "a, b o c"
std::string joinOr(const std::vector<std::string>& v) {
    std::string r;
    for (size_t i = 0; i < v.size(); i++) r += (i == 0 ? "" : i + 1 == v.size() ? " o " : ", ") + v[i];
    return r;
}

std::string lower(std::string s) {
    for (char& c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}

std::string trim(const std::string& s) {
    size_t a = s.find_first_not_of(" \t\r\n"), z = s.find_last_not_of(" \t\r\n");
    return a == std::string::npos ? "" : s.substr(a, z - a + 1);
}

// ================================================================== analizador tolerante

struct XAttr {
    std::string name, value;
    size_t nameBeg = 0, nameEnd = 0;
    bool hasValue = false, closed = false;
    size_t valBeg = 0, valEnd = 0;  // contenido, sin las comillas
};

struct XTag {
    size_t beg = 0, end = 0;  // '<' y después de '>' (o donde se cortó)
    bool closing = false, selfClose = false, complete = false;
    std::string name;
    size_t nameBeg = 0, nameEnd = 0;
    std::vector<XAttr> attrs;
    int parent = -1;  // etiqueta de apertura que lo contiene
    int match = -1;   // etiqueta de cierre (para aperturas) o de apertura (para cierres)
    const XAttr* attr(const std::string& n) const {
        for (const XAttr& a : attrs)
            if (a.name == n) return &a;
        return nullptr;
    }
};

bool isNameChar(char c) { return std::isalnum((unsigned char)c) || c == '_' || c == '-' || c == '.' || c == ':'; }

struct XScan {
    const std::string& s;
    std::vector<XTag> tags;
    std::vector<std::pair<size_t, size_t>> comments;
    std::vector<int> unclosed;  // aperturas sin cierre al final

    explicit XScan(const std::string& src) : s(src) { run(); }

    void run() {
        size_t i = 0;
        std::vector<int> stack;
        while (i < s.size()) {
            if (s[i] != '<') {
                i++;
                continue;
            }
            if (s.compare(i, 4, "<!--") == 0) {
                size_t e = s.find("-->", i + 4);
                size_t end = e == std::string::npos ? s.size() : e + 3;
                comments.push_back({i, end});
                i = end;
                continue;
            }
            if (s.compare(i, 2, "<?") == 0 || s.compare(i, 2, "<!") == 0) {
                size_t e = s.find('>', i);
                i = e == std::string::npos ? s.size() : e + 1;
                continue;
            }
            XTag t;
            t.beg = i++;
            if (i < s.size() && s[i] == '/') {
                t.closing = true;
                i++;
            }
            t.nameBeg = i;
            while (i < s.size() && isNameChar(s[i])) i++;
            t.nameEnd = i;
            t.name = s.substr(t.nameBeg, t.nameEnd - t.nameBeg);
            for (;;) {
                while (i < s.size() && std::isspace((unsigned char)s[i])) i++;
                if (i >= s.size() || s[i] == '<') break;
                if (s[i] == '>') {
                    t.complete = true;
                    i++;
                    break;
                }
                if (s[i] == '/' && i + 1 < s.size() && s[i + 1] == '>') {
                    t.complete = t.selfClose = true;
                    i += 2;
                    break;
                }
                if (!isNameChar(s[i])) {
                    i++;
                    continue;
                }
                XAttr a;
                a.nameBeg = i;
                while (i < s.size() && isNameChar(s[i])) i++;
                a.nameEnd = i;
                a.name = s.substr(a.nameBeg, a.nameEnd - a.nameBeg);
                size_t j = i;
                while (j < s.size() && (s[j] == ' ' || s[j] == '\t')) j++;
                if (j < s.size() && s[j] == '=') {
                    a.hasValue = true;
                    j++;
                    while (j < s.size() && (s[j] == ' ' || s[j] == '\t')) j++;
                    if (j < s.size() && (s[j] == '"' || s[j] == '\'')) {
                        char q = s[j];
                        a.valBeg = j + 1;
                        size_t e = s.find(q, a.valBeg);
                        // Una comilla sin cerrar llega como mucho al final de la línea.
                        size_t nl = s.find('\n', a.valBeg);
                        if (e != std::string::npos && (nl == std::string::npos || e < nl || s.find('<', a.valBeg) > e)) {
                            a.valEnd = e;
                            a.closed = true;
                            i = e + 1;
                        } else {
                            a.valEnd = nl == std::string::npos ? s.size() : nl;
                            i = a.valEnd;
                        }
                    } else {
                        a.valBeg = j;
                        while (j < s.size() && !std::isspace((unsigned char)s[j]) && s[j] != '>' && s[j] != '<' && s[j] != '/') j++;
                        a.valEnd = j;
                        i = j;
                    }
                    a.value = s.substr(a.valBeg, a.valEnd - a.valBeg);
                } else {
                    i = j;
                }
                t.attrs.push_back(std::move(a));
            }
            t.end = i;
            int idx = (int)tags.size();
            t.parent = stack.empty() ? -1 : stack.back();
            if (t.closing) {
                // Cierra hasta la apertura con el mismo nombre (si la hay).
                for (int k = (int)stack.size() - 1; k >= 0; k--)
                    if (tags[stack[k]].name == t.name) {
                        t.match = stack[k];
                        t.parent = k > 0 ? stack[k - 1] : -1;
                        break;
                    }
                tags.push_back(std::move(t));
                if (tags[idx].match >= 0) {
                    tags[tags[idx].match].match = idx;
                    while (!stack.empty() && stack.back() != tags[idx].match) {
                        unclosed.push_back(stack.back());
                        stack.pop_back();
                    }
                    if (!stack.empty()) stack.pop_back();
                }
                continue;
            }
            bool open = t.complete && !t.selfClose && !t.name.empty();
            tags.push_back(std::move(t));
            if (open) stack.push_back(idx);
        }
        for (int k : stack) unclosed.push_back(k);
    }

    bool inComment(size_t off) const {
        for (auto& [a, b] : comments)
            if (off > a && off < b) return true;
        return false;
    }

    // Elemento abierto que contiene 'off' (fuera de cualquier etiqueta).
    int openAt(size_t off) const {
        std::vector<int> stack;
        for (int k = 0; k < (int)tags.size() && tags[k].beg < off; k++) {
            const XTag& t = tags[k];
            if (t.closing) {
                for (int j = (int)stack.size() - 1; j >= 0; j--)
                    if (tags[stack[j]].name == t.name) {
                        stack.resize(j);
                        break;
                    }
            } else if (t.complete && !t.selfClose && t.end <= off) {
                stack.push_back(k);
            }
        }
        return stack.empty() ? -1 : stack.back();
    }

    // Texto entre una apertura y su cierre.
    std::string content(const XTag& t, size_t* beg = nullptr) const {
        if (t.match < 0) return "";
        if (beg) *beg = t.end;
        return s.substr(t.end, tags[t.match].beg - t.end);
    }

    std::vector<int> childrenOf(int parent) const {
        std::vector<int> r;
        for (int k = 0; k < (int)tags.size(); k++)
            if (!tags[k].closing && !tags[k].name.empty() && tags[k].parent == parent) r.push_back(k);
        return r;
    }
};

void lineCol(const std::string& s, size_t off, int& line, int& col) {
    line = 1;
    size_t lineStart = 0;
    for (size_t i = 0; i < off && i < s.size(); i++)
        if (s[i] == '\n') {
            line++;
            lineStart = i + 1;
        }
    col = (int)(std::min(off, s.size()) - lineStart) + 1;
}

size_t offsetOfLine(const std::string& s, int line) {
    size_t off = 0;
    for (int l = 1; l < line; l++) {
        size_t n = s.find('\n', off);
        if (n == std::string::npos) return s.size();
        off = n + 1;
    }
    return off;
}

// ================================================================== validación del .fstproj

struct ProjectValidator {
    const std::string& path;
    const std::string& s;
    XScan sc;
    std::vector<XmlDiagnostic> out;

    ProjectValidator(const std::string& p, const std::string& text) : path(p), s(text), sc(text) {}

    void at(size_t off, const std::string& msg, int severity = 1) {
        XmlDiagnostic d;
        lineCol(s, off, d.line, d.col);
        d.severity = severity;
        d.message = msg;
        out.push_back(d);
    }

    void checkValue(const XTag& t, const ElemSpec& spec) {
        size_t beg = t.end;
        std::string raw = sc.content(t, &beg);
        std::string v = trim(raw);
        size_t off = beg + raw.find_first_not_of(" \t\r\n");
        if (raw.find_first_not_of(" \t\r\n") == std::string::npos) off = beg;
        if (v.find('<') != std::string::npos) return;  // ya informado como elemento hijo
        if (v.empty()) return;
        std::string name = spec.name;
        if (spec.isBool) {
            std::string l = lower(v);
            if (l != "true" && l != "false" && l != "1" && l != "0" && l != "yes" && l != "no")
                at(off, "<" + name + "> debe ser true o false (no '" + v + "')");
            return;
        }
        if (name == "OutputType" || name == "TargetPlatform" || name == "TargetArch" || name == "Configuration") {
            if (std::find(spec.values.begin(), spec.values.end(), v) == spec.values.end())
                at(off, "<" + name + "> debe ser " + joinOr(spec.values) + " (no '" + v + "')");
        } else if (name == "AndroidApi") {
            bool digits = !v.empty() && std::all_of(v.begin(), v.end(), [](char c) { return std::isdigit((unsigned char)c); });
            if (!digits) at(off, "<AndroidApi> debe ser un número (no '" + v + "')");
        }
    }

    void run() {
        // Estructura
        for (const XTag& t : sc.tags) {
            if (t.name.empty()) {
                at(t.beg, t.closing ? "falta el nombre de la etiqueta de cierre" : "falta el nombre del elemento");
                continue;
            }
            if (!t.complete) at(t.beg, "falta '>' en la etiqueta <" + std::string(t.closing ? "/" : "") + t.name + ">");
            for (const XAttr& a : t.attrs) {
                if (!a.hasValue) at(a.nameBeg, "falta el valor del atributo '" + a.name + "' (" + a.name + "=\"...\")");
                else if (!a.closed) at(a.valBeg, "falta la comilla de cierre en el atributo '" + a.name + "'");
            }
            if (t.closing && t.match < 0) at(t.beg, "</" + t.name + "> no cierra ningún elemento abierto");
        }
        for (int k : sc.unclosed) at(sc.tags[k].beg, "falta </" + sc.tags[k].name + "> para cerrar <" + sc.tags[k].name + ">");

        // Contenido
        std::vector<int> roots = sc.childrenOf(-1);
        if (roots.empty()) {
            at(0, "el archivo de proyecto necesita un elemento <Project>");
            return;
        }
        for (size_t i = 0; i < roots.size(); i++) {
            const XTag& r = sc.tags[roots[i]];
            if (i > 0) {
                at(r.nameBeg, "solo puede haber un elemento raíz <Project>");
                continue;
            }
            if (r.name != "Project") {
                at(r.nameBeg, "el elemento raíz debe ser <Project> (no <" + r.name + ">)");
                continue;
            }
            for (int g : sc.childrenOf(roots[i])) {
                const XTag& gt = sc.tags[g];
                if (gt.name == "PropertyGroup") {
                    std::set<std::string> seen;
                    for (int p : sc.childrenOf(g)) {
                        const XTag& pt = sc.tags[p];
                        const ElemSpec* spec = findSpec(projectProps(), pt.name);
                        if (!spec) {
                            std::string known;
                            for (const ElemSpec& e : projectProps()) known += (known.empty() ? "" : ", ") + std::string(e.name);
                            at(pt.nameBeg, "propiedad desconocida <" + pt.name + "> (válidas: " + known + ")");
                            continue;
                        }
                        if (!seen.insert(pt.name).second) at(pt.nameBeg, "la propiedad <" + pt.name + "> está repetida en este grupo", 2);
                        for (const XAttr& a : pt.attrs) at(a.nameBeg, "las propiedades no admiten atributos ('" + a.name + "')");
                        for (int c : sc.childrenOf(p)) at(sc.tags[c].nameBeg, "<" + pt.name + "> no puede contener elementos");
                        checkValue(pt, *spec);
                    }
                } else if (gt.name == "ItemGroup") {
                    for (int it : sc.childrenOf(g)) {
                        const XTag& item = sc.tags[it];
                        const ElemSpec* spec = findSpec(projectItems(), item.name);
                        if (!spec) {
                            at(item.nameBeg, "elemento desconocido <" + item.name +
                                                 "> en <ItemGroup> (válidos: Compile, NativeLibrary, LibraryPath, ProjectReference)");
                            continue;
                        }
                        for (const XAttr& a : item.attrs) {
                            if (std::find(spec->attrs.begin(), spec->attrs.end(), a.name) == spec->attrs.end()) {
                                at(a.nameBeg, "atributo desconocido '" + a.name + "' en <" + item.name + "> (válidos: " +
                                                  joinValues(spec->attrs) + ")");
                            } else if (a.name == "Platform" && a.closed) {
                                const AttrSpec* as = findSpec(projectAttrs(), "Platform");
                                if (std::find(as->values.begin(), as->values.end(), lower(trim(a.value))) == as->values.end())
                                    at(a.valBeg, "Platform debe ser " + joinOr(as->values) + " (no '" + a.value + "')");
                            }
                        }
                        const XAttr* inc = item.attr("Include");
                        if (!inc && !(item.name == "Compile" && item.attr("Remove")))
                            at(item.nameBeg, "<" + item.name + "> necesita el atributo Include");
                        if (inc && inc->closed && item.name == "ProjectReference") {
                            fs::path dir = fs::path(path).parent_path();
                            std::string v = inc->value;
                            size_t start = 0;
                            while (start <= v.size()) {
                                size_t semi = v.find(';', start);
                                std::string ref = trim(v.substr(start, semi == std::string::npos ? std::string::npos : semi - start));
                                std::error_code ec;
                                if (!ref.empty() && !fs::exists(dir / ref, ec))
                                    at(inc->valBeg + start, "no existe el proyecto referenciado '" + ref + "'", 2);
                                if (semi == std::string::npos) break;
                                start = semi + 1;
                            }
                        }
                    }
                } else {
                    at(gt.nameBeg, "elemento desconocido <" + gt.name + "> (se esperaba PropertyGroup o ItemGroup)");
                }
            }
        }
        // Red de seguridad: si el analizador del compilador rechaza el XML y no se ha visto el motivo.
        if (out.empty()) {
            XmlNode root;
            std::string err;
            if (!parseXml(s, root, err)) {
                XmlDiagnostic d;
                d.message = "XML no válido: " + err;
                if (err.rfind("línea ", 0) == 0) d.line = std::atoi(err.c_str() + 7);
                out.push_back(d);
            }
        }
    }
};

// ================================================================== contexto del cursor

enum class Ctx { None, ElementName, AttrName, AttrValue, Text };

struct CursorCtx {
    Ctx kind = Ctx::None;
    int tag = -1;     // etiqueta en la que está el cursor
    int parent = -1;  // elemento que la contiene
    const XAttr* attr = nullptr;
    size_t valueOff = 0;  // posición dentro del valor
};

CursorCtx contextAt(const XScan& sc, size_t off) {
    CursorCtx c;
    if (sc.inComment(off)) return c;
    for (int k = 0; k < (int)sc.tags.size(); k++) {
        const XTag& t = sc.tags[k];
        bool inside = t.complete ? (off > t.beg && off < t.end) : (off > t.beg && off <= t.end);
        if (!inside) continue;
        c.tag = k;
        c.parent = t.closing ? (t.match >= 0 ? sc.tags[t.match].parent : sc.openAt(t.beg)) : sc.openAt(t.beg);
        if (off <= t.nameEnd) {
            c.kind = Ctx::ElementName;
            return c;
        }
        if (t.closing) return c;
        for (const XAttr& a : t.attrs) {
            if (a.hasValue && off >= a.valBeg && off <= a.valEnd && a.valBeg > a.nameEnd) {
                c.kind = Ctx::AttrValue;
                c.attr = &a;
                c.valueOff = off - a.valBeg;
                return c;
            }
        }
        c.kind = Ctx::AttrName;
        return c;
    }
    c.kind = Ctx::Text;
    c.parent = sc.openAt(off);
    return c;
}

void add(std::vector<XmlCompletionItem>& out, const std::string& label, int kind, const std::string& detail,
         const std::string& insert = "") {
    for (const XmlCompletionItem& i : out)
        if (i.label == label) return;
    XmlCompletionItem it;
    it.label = label;
    it.kind = kind;
    it.detail = detail;
    it.insert = insert;
    out.push_back(it);
}

// ¿La etiqueta está a medio escribir (solo '<' y el nombre)? Entonces se puede completar entera.
bool bareTag(const XTag& t) { return !t.complete && t.attrs.empty(); }

// Valores ya escritos en una lista separada por comas, salvo el que está bajo el cursor.
std::set<std::string> otherFlags(const XAttr& a, size_t valueOff) {
    std::set<std::string> r;
    size_t start = 0;
    const std::string& v = a.value;
    while (start <= v.size()) {
        size_t comma = v.find(',', start);
        size_t end = comma == std::string::npos ? v.size() : comma;
        if (!(valueOff >= start && valueOff <= end)) r.insert(lower(trim(v.substr(start, end - start))));
        if (comma == std::string::npos) break;
        start = comma + 1;
    }
    return r;
}

void completeProject(const XScan& sc, const std::string& path, const CursorCtx& c, std::vector<XmlCompletionItem>& out) {
    const XTag* parent = c.parent >= 0 ? &sc.tags[c.parent] : nullptr;
    std::string pname = parent ? parent->name : "";
    if (c.kind == Ctx::ElementName) {
        const XTag& t = sc.tags[c.tag];
        if (t.closing) {
            if (parent) add(out, pname, kElement, "cierra <" + pname + ">", pname + ">");
            return;
        }
        bool bare = bareTag(t);
        if (!parent) {
            add(out, "Project", kElement, kProjectRoot.doc, bare ? "Project>\n$0\n</Project>" : "");
        } else if (pname == "Project") {
            add(out, "PropertyGroup", kElement, kPropertyGroup.doc, bare ? "PropertyGroup>$0</PropertyGroup>" : "");
            add(out, "ItemGroup", kElement, kItemGroup.doc, bare ? "ItemGroup>$0</ItemGroup>" : "");
        } else if (pname == "PropertyGroup") {
            std::set<std::string> present;
            for (int k : sc.childrenOf(c.parent))
                if (k != c.tag) present.insert(sc.tags[k].name);
            for (const ElemSpec& p : projectProps())
                if (!present.count(p.name))
                    add(out, p.name, kProperty, p.doc, bare ? std::string(p.name) + ">$0</" + p.name + ">" : "");
        } else if (pname == "ItemGroup") {
            for (const ElemSpec& p : projectItems()) add(out, p.name, kElement, p.doc, bare ? std::string(p.name) + " Include=\"$0\" />" : "");
        }
        return;
    }
    if (c.kind == Ctx::AttrName) {
        const XTag& t = sc.tags[c.tag];
        const ElemSpec* spec = findSpec(projectItems(), t.name);
        if (!spec) return;
        for (const std::string& a : spec->attrs) {
            if (t.attr(a)) continue;
            const AttrSpec* as = findSpec(projectAttrs(), a);
            add(out, a, kProperty, as ? as->doc : "", a + "=\"$0\"");
        }
        return;
    }
    if (c.kind == Ctx::AttrValue) {
        const XTag& t = sc.tags[c.tag];
        if (c.attr->name == "Platform") {
            for (const std::string& v : findSpec(projectAttrs(), "Platform")->values) add(out, v, kValue, "");
        } else if (c.attr->name == "Include" && t.name == "ProjectReference") {
            // Proyectos de las carpetas vecinas.
            std::error_code ec;
            fs::path dir = fs::path(path).parent_path();
            fs::path parentDir = dir.parent_path();
            for (auto& e : fs::directory_iterator(parentDir, ec)) {
                if (!e.is_directory(ec) || e.path() == dir) continue;
                for (auto& f : fs::directory_iterator(e.path(), ec))
                    if (f.path().extension() == ".fstproj") {
                        std::string rel = "../" + e.path().filename().string() + "/" + f.path().filename().string();
                        add(out, rel, kFile, "proyecto " + f.path().stem().string());
                    }
            }
        } else if (c.attr->name == "Include" && t.name == "NativeLibrary") {
            for (const char* l : {"m", "pthread", "dl", "X11", "GL", "vulkan", "freetype", "user32", "gdi32", "kernel32", "ws2_32"})
                add(out, l, kValue, "biblioteca nativa");
        }
        return;
    }
    if (c.kind == Ctx::Text && parent && sc.tags[c.parent].parent >= 0 && sc.tags[sc.tags[c.parent].parent].name == "PropertyGroup") {
        const ElemSpec* spec = findSpec(projectProps(), pname);
        if (!spec) return;
        if (pname == "AssemblyName" || pname == "RootNamespace") {
            std::string stem = fs::path(path).stem().string();
            add(out, stem, kValue, "nombre del proyecto");
        }
        for (const std::string& v : spec->values) add(out, v, kValue, spec->doc);
    }
}

void completeUi(const XScan& sc, const std::string& path, const CursorCtx& c, const XmlUiCodeInfo* code,
                std::vector<XmlCompletionItem>& out) {
    const XTag* parent = c.parent >= 0 ? &sc.tags[c.parent] : nullptr;
    std::string pname = parent ? parent->name : "";
    if (c.kind == Ctx::ElementName) {
        const XTag& t = sc.tags[c.tag];
        if (t.closing) {
            if (parent) add(out, pname, kElement, "cierra <" + pname + ">", pname + ">");
            return;
        }
        bool bare = bareTag(t);
        if (!parent) {
            std::string cls = fs::path(path).stem().string();
            add(out, "Window", kElement, kUiWindow.doc,
                bare ? "Window Class=\"" + cls + "\" Title=\"$0\" Width=\"640\" Height=\"480\">\n</Window>" : "");
        } else if (pname == "Window" || pname == "Panel" || pname == "TabPage") {
            for (const ElemSpec& e : uiControls()) {
                if (uiIsComponent(e.name) && pname != "Window") continue;  // los componentes van en <Window>
                add(out, e.name, kElement, e.doc, bare ? uiSnippet(e.name) : "");
            }
        } else {
            // Contenedores con hijos de un tipo concreto (reglas de anidamiento de UiGen).
            std::vector<std::string> kids;
            if (pname == "TabControl") kids = {"TabPage"};
            else if (pname == "TreeView" || pname == "TreeNode") kids = {"TreeNode"};
            else if (uiIsMenuOwner(pname)) kids = {"Menu", "MenuItem", "Separator"};
            for (const std::string& k : kids)
                if (const ElemSpec* e = uiElem(k)) add(out, e->name, kElement, e->doc, bare ? uiSnippet(k) : "");
        }
        return;
    }
    if (c.kind == Ctx::AttrName) {
        const XTag& t = sc.tags[c.tag];
        const ElemSpec* spec = uiElem(t.name);
        if (!spec) return;
        for (const std::string& a : spec->attrs) {
            if (t.attr(a)) continue;
            const AttrSpec* as = uiAttr(a);
            std::string detail = as ? as->doc : "";
            if (as && !as->values.empty() && !as->flags && as->values != kBool) detail += " (" + joinValues(as->values) + ")";
            add(out, a, kProperty, detail, a + "=\"$0\"");
        }
        return;
    }
    if (c.kind == Ctx::AttrValue) {
        const XTag& t = sc.tags[c.tag];
        const XAttr& a = *c.attr;
        const AttrSpec* as = uiAttr(a.name);
        if (!as) return;
        if (as->handler) {
            if (!code) return;
            std::string params = uiHandlerParams(a.name);
            for (const XmlUiCodeInfo::Method& m : code->methods) {
                // Paint y los eventos del ratón reciben un segundo parámetro (Graphics / MouseArgs).
                bool fits = params == "Widget sender" ? m.handler
                          : m.signature.find(params.find("Graphics") != std::string::npos ? "Graphics" : "MouseArgs") != std::string::npos;
                if (fits) add(out, m.name, kMethod, m.signature);
            }
            // Nombre propuesto para un manejador nuevo: On + nombre del control (sin prefijo) + evento.
            const XAttr* nm = t.attr("Name");
            std::string base = nm && !nm->value.empty() ? nm->value : t.name;
            size_t k = 0;
            while (k < base.size() && std::islower((unsigned char)base[k])) k++;
            if (k < base.size() && k > 0 && k <= 3) base = base.substr(k);
            if (!base.empty()) base[0] = (char)std::toupper((unsigned char)base[0]);
            std::string fresh = "On" + base + a.name;
            bool exists = false;
            for (const XmlUiCodeInfo::Method& m : code->methods) exists |= m.name == fresh;
            if (!exists) add(out, fresh, kMethod, "nuevo manejador: void " + fresh + "(" + params + ")");
            return;
        }
        if (a.name == "ContextMenu") {
            // Menús contextuales del documento.
            for (const XTag& o : sc.tags)
                if (!o.closing && o.name == "ContextMenu")
                    if (const XAttr* nm = o.attr("Name"))
                        if (!nm->value.empty()) add(out, nm->value, kValue, "<ContextMenu Name=\"" + nm->value + "\">");
            return;
        }
        if (a.name == "Source" || a.name == "Icon") {
            // Imágenes de la carpeta del .fstui (y sus subcarpetas, como Assets/).
            std::error_code ec;
            fs::path dir = fs::path(path).parent_path();
            int seen = 0;
            for (auto it = fs::recursive_directory_iterator(dir, ec); it != fs::recursive_directory_iterator() && seen < 200;
                 it.increment(ec)) {
                if (it.depth() > 3 || it->path().filename().string().rfind(".", 0) == 0 || it->path().filename() == "bin" ||
                    it->path().filename() == "obj") {
                    if (it->is_directory(ec)) it.disable_recursion_pending();
                    continue;
                }
                std::string ext = lower(it->path().extension().string());
                if (ext != ".png" && ext != ".jpg" && ext != ".jpeg" && ext != ".bmp" && ext != ".gif") continue;
                add(out, fs::relative(it->path(), dir, ec).generic_string(), kFile, "imagen");
                seen++;
            }
            return;
        }
        if (a.name == "Class" && t.name == "Window") {
            add(out, fs::path(path).stem().string(), kValue, "clase de la ventana");
            return;
        }
        std::set<std::string> skip = as->flags ? otherFlags(a, c.valueOff) : std::set<std::string>();
        for (const std::string& v : as->values)
            if (!skip.count(lower(v))) add(out, v, kValue, as->doc);
    }
}

std::string attrHover(const AttrSpec& a) {
    std::string h = a.name + std::string(" — ") + a.doc;
    if (!a.values.empty() && !a.handler) h += "\nValores: " + joinValues(a.values);
    return h;
}

}  // namespace

// ================================================================== API

XmlDocKind xmlDocKind(const std::string& path) {
    std::string ext = fs::path(path).extension().string();
    if (ext == ".fstproj") return XmlDocKind::Project;
    if (ext == ".fstui") return XmlDocKind::Ui;
    return XmlDocKind::None;
}

std::vector<XmlDiagnostic> xmlValidateProject(const std::string& path, const std::string& text) {
    ProjectValidator v(path, text);
    v.run();
    return v.out;
}

std::vector<XmlCompletionItem> xmlComplete(XmlDocKind kind, const std::string& path, const std::string& text, size_t offset,
                                           const XmlUiCodeInfo* code) {
    std::vector<XmlCompletionItem> out;
    XScan sc(text);
    CursorCtx c = contextAt(sc, std::min(offset, text.size()));
    if (c.kind == Ctx::None) return out;
    if (kind == XmlDocKind::Project) completeProject(sc, path, c, out);
    else if (kind == XmlDocKind::Ui) completeUi(sc, path, c, code, out);
    return out;
}

std::vector<XmlSymbolRef> xmlRefs(XmlDocKind kind, const std::string& path, const std::string& text, const XmlUiCodeInfo* code) {
    std::vector<XmlSymbolRef> out;
    XScan sc(text);
    auto ref = [&](size_t off, size_t len, const std::string& hover) -> XmlSymbolRef& {
        XmlSymbolRef r;
        lineCol(text, off, r.line, r.col);
        r.len = (int)len;
        r.hover = hover;
        out.push_back(r);
        return out.back();
    };
    std::string cls, ns;
    if (kind == XmlDocKind::Ui) xmlUiClass(text, cls, ns);
    for (const XTag& t : sc.tags) {
        if (t.name.empty()) continue;
        const ElemSpec* spec = kind == XmlDocKind::Project ? projectElem(t.name) : uiElem(t.name);
        if (spec) {
            std::string h = "<" + t.name + "> — " + spec->doc;
            if (!spec->values.empty()) h += "\nValores: " + joinValues(spec->values);
            ref(t.nameBeg, t.name.size(), h);
        }
        if (t.closing) continue;
        for (const XAttr& a : t.attrs) {
            if (kind == XmlDocKind::Project) {
                if (const AttrSpec* as = findSpec(projectAttrs(), a.name)) ref(a.nameBeg, a.name.size(), attrHover(*as));
                if (t.name == "ProjectReference" && a.name == "Include" && a.closed && !a.value.empty()) {
                    fs::path target = (fs::path(path).parent_path() / a.value).lexically_normal();
                    std::error_code ec;
                    XmlSymbolRef& r = ref(a.valBeg, a.value.size(), "proyecto " + target.string());
                    if (fs::exists(target, ec)) {
                        r.defPath = target.string();
                        r.defLine = r.defCol = 1;
                    }
                }
                continue;
            }
            const AttrSpec* as = uiAttr(a.name);
            if (as) ref(a.nameBeg, a.name.size(), attrHover(*as));
            if (!a.hasValue || a.value.empty()) continue;
            if (a.name == "Name" && t.name != "Window" && !cls.empty()) {
                ref(a.valBeg, a.value.size(), "(campo) Widget " + cls + "." + a.value);
            } else if (as && as->handler && code) {
                for (const XmlUiCodeInfo::Method& m : code->methods)
                    if (m.name == a.value) {
                        XmlSymbolRef& r = ref(a.valBeg, a.value.size(), m.signature);
                        r.defPath = m.path;
                        r.defLine = m.line;
                        r.defCol = m.col;
                        break;
                    }
            } else if (a.name == "Class" && t.name == "Window" && code && code->found) {
                XmlSymbolRef& r = ref(a.valBeg, a.value.size(), code->classSignature);
                r.defPath = code->classPath;
                r.defLine = code->classLine;
                r.defCol = code->classCol;
            }
        }
    }
    return out;
}

bool xmlUiClass(const std::string& text, std::string& cls, std::string& ns) {
    XScan sc(text);
    for (const XTag& t : sc.tags) {
        if (t.closing || t.name != "Window") continue;
        if (const XAttr* a = t.attr("Class")) cls = a->value;
        if (const XAttr* a = t.attr("Namespace")) ns = a->value;
        return !cls.empty();
    }
    return false;
}

bool xmlUiControlPos(const std::string& text, const std::string& name, int& line, int& col) {
    XScan sc(text);
    for (const XTag& t : sc.tags) {
        const XAttr* a = t.closing ? nullptr : t.attr("Name");
        if (a && a->value == name) {
            lineCol(text, a->valBeg, line, col);
            return true;
        }
    }
    return false;
}

void xmlRefineUiDiagnostic(const std::string& text, const std::string& message, int& line, int& col) {
    // "XML no válido: línea N: ..."
    size_t p = message.find("línea ");
    if (message.rfind("XML no válido", 0) == 0 && p != std::string::npos) {
        line = std::max(1, std::atoi(message.c_str() + p + 7));
        col = 1;
    }
    XScan sc(text);
    size_t lineOff = offsetOfLine(text, line);
    if (message.rfind("XML no válido", 0) == 0) {
        // "... en <Butt>": la última etiqueta con ese nombre que empieza antes del final de la línea.
        size_t lt = message.find(" <");
        size_t gt = lt == std::string::npos ? std::string::npos : message.find('>', lt);
        if (gt != std::string::npos) {
            std::string name = message.substr(lt + 2, gt - lt - 2);
            if (!name.empty() && name[0] == '/') name = name.substr(1);
            size_t lineEnd = std::min(text.size(), text.find('\n', lineOff));
            const XTag* best = nullptr;
            for (const XTag& t : sc.tags)
                if (t.name == name && t.beg < lineEnd) best = &t;
            if (best) {
                lineCol(text, best->nameBeg, line, col);
                return;
            }
        }
    }
    // Etiqueta que empieza en esa línea (el generador usa la línea del '<').
    size_t lineEnd = std::min(text.size(), text.find('\n', lineOff));
    const XTag* tag = nullptr;
    for (const XTag& t : sc.tags)
        if (!t.closing && t.beg >= lineOff && t.beg < lineEnd) {
            tag = &t;
            break;
        }
    if (!tag) {
        // Al menos el primer carácter visible de la línea.
        size_t k = lineOff;
        while (k < text.size() && (text[k] == ' ' || text[k] == '\t')) k++;
        if (k < text.size() && text[k] != '\n') lineCol(text, k, line, col);
        return;
    }
    // Palabras entre comillas simples del mensaje: atributo o valor mencionado.
    std::vector<std::string> quoted;
    for (size_t i = message.find('\''); i != std::string::npos; i = message.find('\'', i + 1)) {
        size_t e = message.find('\'', i + 1);
        if (e == std::string::npos) break;
        quoted.push_back(message.substr(i + 1, e - i - 1));
        i = e;
    }
    for (const std::string& q : quoted)
        for (const XAttr& a : tag->attrs)
            if (a.name == q) {
                // Si el mensaje cita también el valor, se señala el valor.
                for (const std::string& q2 : quoted)
                    if (&q2 != &q && !q2.empty() && a.hasValue && a.value.find(q2) != std::string::npos) {
                        lineCol(text, a.valBeg + a.value.find(q2), line, col);
                        return;
                    }
                lineCol(text, a.nameBeg, line, col);
                return;
            }
    for (const std::string& q : quoted)
        for (const XAttr& a : tag->attrs)
            if (!q.empty() && a.hasValue && a.value == q) {
                lineCol(text, a.valBeg, line, col);
                return;
            }
    // "control desconocido '<X>'" u otros: el nombre del elemento.
    lineCol(text, tag->nameBeg, line, col);
}
