#include "XmlIntel.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <filesystem>
#include <functional>
#include <set>

#include "Packages.h"
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
        {"OutputType", "Output type: Exe (console), WinExe (windowed app) or Library (library).", {}, {"Exe", "WinExe", "Library"}},
        {"AssemblyName", "Name of the generated executable or library (defaults to the project name).", {}, {}},
        {"RootNamespace", "Main namespace of the project (used by templates and the designer).", {}, {}},
        {"TargetPlatform", "Target platform: native (the system's), linux, windows, android or macos.", {}, {"native", "linux", "windows", "android", "macos"}},
        {"TargetArch", "Target architecture: x86_64, x86, arm64 or armv7 (defaults to the system's).", {}, {"x86_64", "x86", "arm64", "armv7"}},
        {"AndroidApi", "Android API level (default 24).", {}, {"24", "26", "28", "29", "30", "31", "33", "34"}},
        {"Configuration", "Default configuration: Debug (with debug symbols) or Release (optimized).", {}, {"Debug", "Release"}},
        {"OutputPath", "Output folder, relative to the project (default 'bin').", {}, {"bin"}},
        {"StaticLink", "Links the C libraries statically (true or false).", {}, kBool, true},
        {"EnableDefaultCompileItems", "Automatically compiles all .fst and .fstui files in the folder (true by default).", {}, kBool, true},
        {"Version", "Project version (in a package, semver: 1.2.0; published with the git tag v1.2.0).", {}, {"1.0.0", "0.1.0"}},
        {"Description", "Project description (informational).", {}, {}},
        {"Authors", "Project authors (in a package, the ones shown by 'faset pack').", {}, {}},
        // Paquetes (faset pack / faset publish)
        {"PackageId", "Package name: the one used in <PackageReference Include=\"...\"> (letters, digits, '.', '_' and '-').", {}, {}},
        {"License", "Package license (e.g. MIT, Apache-2.0).", {}, {"MIT", "Apache-2.0", "BSD-3-Clause", "GPL-3.0", "LGPL-3.0", "MPL-2.0"}},
        {"RepositoryUrl", "Package git repository: where the vX.Y.Z tags are published.", {}, {}},
        {"PackageIndex", "Package index (JSON) where <PackageReference> entries without Git or Path are looked up "
                         "(default https://faset.lat/paquetes/index.json).", {}, {}},
        {"Optimize", "Forces optimization (true or false).", {}, kBool, true},
        {"DebugSymbols", "Forces debug symbols (true or false).", {}, kBool, true},
        {"RuntimeChecks", "Runtime checks (bounds, nulls, double delete...): on by default in Debug and off in Release.", {}, kBool, true},
        {"AllowUnsafe", "Allows memory_unsafe code across the whole project without marking it (true or false).", {}, kBool, true},
        {"IsTestProject", "Test project: no Main, its [Test] methods run with 'faset test' (true or false).", {}, kBool, true},
        // Android (APK)
        {"AndroidPackage", "Android app package (e.g. com.company.app; default com.faset.<name>).", {}, {}},
        {"AppName", "Visible app name on Android.", {}, {}},
        {"VersionCode", "Internal Android version number (integer that increases with each release).", {}, {"1"}},
        {"VersionName", "Visible version of the Android app (e.g. 1.0).", {}, {"1.0"}},
        {"AndroidAbis", "APK ABIs separated by ';' (default arm64-v8a;x86_64).", {},
         {"arm64-v8a;x86_64", "arm64-v8a", "x86_64", "armeabi-v7a", "x86"}},
        {"AndroidTargetSdk", "Android target SDK (defaults to the newest installed platform).", {}, {"34", "35", "36"}},
        {"AndroidOrientation", "Orientation of the Android app.", {}, {"portrait", "landscape", "sensor", "unspecified"}},
        {"AndroidIcon", "Android app icon (PNG, relative to the project).", {}, {"icon.png"}},
        {"AndroidKeystore", "Keystore used to sign the APK (default ~/.android/debug.keystore).", {}, {}},
        {"AndroidKeyAlias", "Alias of the APK signing key.", {}, {}},
        {"AndroidKeystorePassword", "Keystore password (better: FASET_ANDROID_KEYSTORE_PASSWORD variable).", {}, {}},
        {"AndroidKeyPassword", "Key password (better: FASET_ANDROID_KEY_PASSWORD variable).", {}, {}},
    };
    return v;
}

const std::vector<ElemSpec>& projectItems() {
    static const std::vector<ElemSpec> v = {
        {"Compile", "Files to compile: Include adds (supports '*' and '**'), Remove excludes.", {"Include", "Remove"}, {}},
        {"NativeLibrary", "Native library to link against (e.g. 'm', 'user32'); Platform limits it to one system.",
         {"Include", "Platform"}, {}},
        {"LibraryPath", "Folder to search for native libraries, relative to the project.", {"Include"}, {}},
        {"ProjectReference", "Another Faset project (.fstproj) whose code is compiled together with this one.", {"Include"}, {}},
        {"PackageReference", "Package (a Faset library) from a git repository, a folder or the index: "
                             "downloaded with 'faset restore' (or when building) and compiled as a ProjectReference.",
         {"Include", "Version", "Git", "Branch", "Commit", "Path", "Folder"}, {}},
        {"AndroidPermission", "Android permission the app requests (e.g. INTERNET, CAMERA).", {"Include"}, {}},
        {"Asset", "Resources (sounds, images...): copied next to the executable or into the APK's assets/ with the same "
                  "relative path. Include supports '*', '**' and folders; Remove excludes.", {"Include", "Remove"}, {}},
    };
    return v;
}

const std::vector<AttrSpec>& projectAttrs() {
    static const std::vector<AttrSpec> v = {
        {"Include", "Items to add (';'-separated list).", {}},
        {"Remove", "Items to exclude (';'-separated list, supports '*' and '**').", {}},
        {"Platform", "System it applies to: linux, windows, android or macos.", {"linux", "windows", "android", "macos"}},
        {"Version", "Package version (git tag vX.Y.Z): exact (1.2.0), ^1.2 (compatible), ~1.2 (patches), 1.x, "
                    "\">=1.0 <2.0\" or alternatives with ||. Without Version: the latest.", {"^1.0", "~1.0", "1.0.0", ">=1.0 <2.0"}},
        {"Git", "Package git repository (https://..., git@... or a path to a local repository).", {}},
        {"Branch", "Uses the tip of this branch instead of a version (paquetes.lock stores the commit).", {"main", "master"}},
        {"Commit", "Uses this exact commit (full or abbreviated sha).", {}},
        {"Path", "Local folder containing the package project (relative to this .fstproj).", {}},
        {"Folder", "Subfolder of the repository (or of Path) where the package's .fstproj is.", {}},
    };
    return v;
}

const ElemSpec kProjectRoot = {"Project", "Faset project: <PropertyGroup> groups with properties and <ItemGroup> groups with files and references.", {}, {}};
const ElemSpec kPropertyGroup = {"PropertyGroup", "Project properties (OutputType, AssemblyName, TargetPlatform...).", {}, {}};
const ElemSpec kItemGroup = {"ItemGroup", "Project items: Compile, NativeLibrary, LibraryPath, ProjectReference, PackageReference and Asset.", {}, {}};

// ---- .fstp (ver src/Solution.cpp)

const ElemSpec kSolutionRoot = {"Solution", "Faset solution: several projects (.fstproj) opened and built together.",
                                {"Name", "Configuration", "TargetPlatform"}, {}};
const ElemSpec kSolutionProject = {"Project", "Solution project. Path is relative to the .fstp; Startup=\"true\" marks it as the "
                                   "startup project (the one 'faset run' runs).", {"Path", "Startup"}, {}};
const ElemSpec kSolutionFolder = {"Folder", "Solution folder: only organizes projects in the tree (can be nested).", {"Name"}, {}};

const std::vector<AttrSpec>& solutionAttrs() {
    static const std::vector<AttrSpec> v = {
        {"Name", "Name (of the solution or of the solution folder).", {}},
        {"Configuration", "Default configuration for all projects if -c is not given.", {"Debug", "Release"}},
        {"TargetPlatform", "Default platform for all projects if --target is not given.", {"native", "linux", "windows", "android", "macos"}},
        {"Path", "Path to the .fstproj, relative to the solution folder.", {}},
        {"Startup", "Startup project: the one run with 'faset run' and F5 (only one).", {"true", "false"}},
    };
    return v;
}

const ElemSpec* solutionElem(const std::string& n) {
    if (n == "Solution") return &kSolutionRoot;
    if (n == "Project") return &kSolutionProject;
    if (n == "Folder") return &kSolutionFolder;
    return nullptr;
}

// ---- .fstui (ver src/UiGen.cpp)

const std::vector<AttrSpec>& uiAttrs() {
    static const std::vector<AttrSpec> v = {
        {"Class", "Name of the 'partial' class the window generates (the code goes in Name.fst).", {}},
        {"Namespace", "Namespace of the window class.", {}},
        {"Title", "Window title.", {}},
        {"Theme", "Window color theme.", {"Dark", "Light"}},
        {"Resizable", "Whether the user can resize the window.", kBool},
        {"MinWidth", "Minimum window width, in pixels.", {}},
        {"MinHeight", "Minimum window height, in pixels.", {}},
        {"Name", "Control name: a 'Widget' field with this name is generated in the class.", {}},
        {"X", "Horizontal position, in pixels, within the container.", {}},
        {"Y", "Vertical position, in pixels, within the container.", {}},
        {"Width", "Width in pixels.", {}},
        {"Height", "Height in pixels.", {}},
        {"Text", "Control text.", {}},
        {"Placeholder", "Hint text shown while the box is empty.", {}},
        {"FontSize", "Font size, in pixels.", {"11", "12", "13", "14", "16", "18", "20", "24", "32"}},
        {"Bold", "Bold text.", kBool},
        {"Enabled", "Whether the control responds to the user.", kBool},
        {"Visible", "Whether the control is shown.", kBool},
        {"Checked", "Checked state of the checkbox or radio button.", kBool},
        {"CornerRadius", "Radius of the rounded corners, in pixels.", {"0", "4", "6", "8", "12"}},
        {"Style", "Visual style of the control.", {"Default", "Primary", "Subtle", "Danger"}},
        {"TextAlign", "Horizontal text alignment.", {"Left", "Center", "Right"}},
        {"Anchor", "Container edges the control anchors to when resized (comma-separated list).",
         {"Left", "Top", "Right", "Bottom"}, true},
        {"Value", "Current value.", {}},
        {"Min", "Minimum value.", {}},
        {"Max", "Maximum value.", {}},
        {"Group", "Radio button group: only one in each group can be checked.", {}},
        {"Items", "List items, separated by ';'.", {}},
        {"SelectedIndex", "Index of the selected item (-1: none).", {"-1", "0"}},
        {"Background", "Background color ('#RRGGBB' or '#RRGGBBAA').", {}},
        {"Background2", "Second color of the background gradient ('#RRGGBB').", {}},
        {"GradientDirection", "Direction of the gradient between Background and Background2.", {"Vertical", "Horizontal"}},
        {"Foreground", "Text color ('#RRGGBB').", {}},
        {"BorderColor", "Border color ('#RRGGBB').", {}},
        {"Accent", "Accent color: fill of checkboxes, bars and sliders ('#RRGGBB').", {}},
        {"Click", "Method called on click: void Name(Widget sender).", {}, false, true},
        {"Changed", "Method called when the value changes: void Name(Widget sender).", {}, false, true},
        {"Source", "PictureBox: image (PNG, JPEG, BMP or GIF), relative to the project (also next to the executable and, on Android, inside the APK). WebView: address it loads (https://..., file://...). VideoPlayer: video, path or URI.", {}},
        {"Html", "HTML document the WebView shows (instead of Source).", {}},
        {"Navigated", "Method called when a page finishes loading: void Name(Widget sender).", {}, false, true},
        {"TitleChanged", "Method called when the page title changes: void Name(Widget sender).", {}, false, true},
        {"MessageReceived",
         "Method called when the page calls window.faset.postMessage(text): void Name(Widget sender, string message).",
         {}, false, true},
        // VideoPlayer
        {"AutoPlay", "Starts playing as soon as the video loads.", kBool},
        {"Loop", "Starts over when it reaches the end.", kBool},
        {"ShowControls", "Shows the controls bar (play/pause, position and time).", kBool},
        {"Volume", "Volume, from 0 to 1.", {"0", "0.5", "1"}},
        {"Stretch", "How the image is fitted: Uniform (without distortion), Fill (the whole control) or None (original size).",
         {"Uniform", "Fill", "None"}},
        {"Opened", "Method called when the video is ready: void Name(Widget sender).", {}, false, true},
        {"Ended", "Method called when the video ends (without Loop): void Name(Widget sender).", {}, false, true},
        {"Failed", "Method called if the video cannot be opened or played: void Name(Widget sender).", {}, false, true},
        // Controles de imágenes, pestañas, árbol, menús, temporizador y lienzo
        {"SizeMode", "How the image is placed: Normal (top left), Stretch (stretched), Zoom (fits entirely without distortion), Center (centered) or Cover (fills and crops).",
         {"Normal", "Stretch", "Zoom", "Center", "Cover"}},
        {"Icon", "Icon (PNG, JPEG, BMP or GIF) drawn to the left of the text.", {}},
        {"Shortcut", "Keyboard shortcut for the menu item (Ctrl+S, Ctrl+Shift+N, F5, Supr...): works even when the menu is closed.",
         {"Ctrl+N", "Ctrl+O", "Ctrl+S", "Ctrl+Shift+S", "Ctrl+Z", "Ctrl+Y", "Ctrl+Q", "F1", "F5", "Supr"}},
        {"Interval", "Milliseconds between two timer Ticks.", {"16", "100", "500", "1000"}},
        {"Expanded", "Whether the node shows its children.", kBool},
        {"Tag", "Free-form node data (a path, an identifier...): TreeNode.Tag.", {}},
        {"ContextMenu", "Context menu (Name of a <ContextMenu> in the window) opened with the right button.", {}},
        {"SelectedChanged", "Method called when the selection changes (tab, node or item): void Name(Widget sender).", {}, false, true},
        {"NodeActivated", "Method called on double-click or Enter on a node: void Name(Widget sender).", {}, false, true},
        {"Tick", "Method called every Interval milliseconds: void Name(Widget sender).", {}, false, true},
        {"Paint", "Method that draws the canvas: void Name(Widget sender, Graphics g).", {}, false, true},
        {"MouseDown", "Mouse button pressed on the canvas: void Name(Widget sender, MouseArgs e).", {}, false, true},
        {"MouseMove", "Mouse moved over the canvas: void Name(Widget sender, MouseArgs e).", {}, false, true},
        {"MouseUp", "Mouse button released: void Name(Widget sender, MouseArgs e).", {}, false, true},
    };
    return v;
}

#define FST_COMMON "Name", "X", "Y", "Width", "Height", "Anchor", "Enabled", "Visible", "Style", "FontSize", "Bold", \
                   "CornerRadius", "Background", "Background2", "GradientDirection", "Foreground", "BorderColor"

const std::vector<ElemSpec>& uiControls() {
    static const std::vector<ElemSpec> v = {
        {"Panel", "Container for other controls.", {FST_COMMON, "Text", "Click"}, {}},
        {"Label", "Static text.", {FST_COMMON, "Text", "TextAlign", "Click"}, {}},
        {"Button", "Button: the Click attribute names the method called when pressed.", {FST_COMMON, "Text", "TextAlign", "Accent", "Click"}, {}},
        {"TextBox", "Editable text box: Changed is called when typing.", {FST_COMMON, "Text", "Placeholder", "TextAlign", "Accent", "Changed"}, {}},
        {"CheckBox", "Checkbox.", {FST_COMMON, "Text", "Checked", "Accent", "Click", "Changed"}, {}},
        {"Slider", "Slider to pick a number between Min and Max.", {FST_COMMON, "Value", "Min", "Max", "Accent", "Changed"}, {}},
        {"ProgressBar", "Progress bar between Min and Max.", {FST_COMMON, "Value", "Min", "Max", "Accent"}, {}},
        {"RadioButton", "Radio button: only one in each Group can be checked.", {FST_COMMON, "Text", "Checked", "Group", "Accent", "Click", "Changed"}, {}},
        {"ComboBox", "Drop-down list: Items separated by ';'.", {FST_COMMON, "Items", "SelectedIndex", "Accent", "Changed"}, {}},
        {"ListBox", "List of items: Items separated by ';'.", {FST_COMMON, "Items", "SelectedIndex", "Accent", "Changed", "SelectedChanged"}, {}},
        {"WebView", "Embedded web browser (WebKitGTK on Linux, android.webkit on Android). From JavaScript: window.faset.postMessage(text).",
         {"Name", "X", "Y", "Width", "Height", "Anchor", "Visible", "FontSize", "CornerRadius", "Background", "Foreground", "BorderColor",
          "Source", "Html", "Navigated", "TitleChanged", "MessageReceived"},
         {}},
        {"VideoPlayer", "Video player with sound (the generated field is a VideoPlayer: Play, Pause, Stop, Seek, Position...).",
         {"Name", "X", "Y", "Width", "Height", "Anchor", "Visible", "Background", "BorderColor", "Accent", "Source", "AutoPlay", "Loop",
          "ShowControls", "Volume", "Stretch", "Opened", "Ended", "Failed"},
         {}},
        {"PictureBox", "Image (PNG, JPEG, BMP or GIF) with SizeMode Normal, Stretch, Zoom, Center or Cover.",
         {"Name", "X", "Y", "Width", "Height", "Anchor", "Visible", "Source", "SizeMode", "CornerRadius", "Background", "Background2",
          "GradientDirection", "BorderColor", "ContextMenu", "Click"}, {}},
        {"TabControl", "Tabbed pages: contains <TabPage> elements; Ctrl+Tab switches page.",
         {FST_COMMON, "SelectedIndex", "Accent", "ContextMenu", "SelectedChanged"}, {}},
        {"TreeView", "Tree of nodes that expand and collapse: contains <TreeNode> elements.",
         {FST_COMMON, "ContextMenu", "SelectedChanged", "NodeActivated"}, {}},
        {"MenuBar", "Menu bar (top of the window): contains <Menu> elements.",
         {"Name", "X", "Y", "Width", "Height", "Anchor", "Visible", "FontSize", "Background", "Foreground", "BorderColor"}, {}},
        {"Canvas", "Free drawing canvas: Paint receives a Graphics; MouseDown/MouseMove/MouseUp, a MouseArgs.",
         {"Name", "X", "Y", "Width", "Height", "Anchor", "Enabled", "Visible", "CornerRadius", "Background", "Background2",
          "GradientDirection", "BorderColor", "ContextMenu", "Paint", "MouseDown", "MouseMove", "MouseUp"}, {}},
        {"Timer", "Timer (non-visual component): fires Tick every Interval milliseconds while Enabled is true.",
         {"Name", "Interval", "Enabled", "Tick"}, {}},
        {"ContextMenu", "Context menu (non-visual component): opened with the right button on the controls that name it.",
         {"Name", "FontSize"}, {}},
    };
    return v;
}

// Elementos que solo van dentro de otro (páginas, nodos y menús).
const std::vector<ElemSpec>& uiParts() {
    static const std::vector<ElemSpec> v = {
        {"TabPage", "Page of a <TabControl>: contains the controls shown when its tab is selected.",
         {"Name", "Text", "Enabled", "Background", "Background2", "GradientDirection"}, {}},
        {"TreeNode", "Node of a <TreeView> (can contain other nodes). With Name a TreeNode field is generated.",
         {"Name", "Text", "Expanded", "Tag"}, {}},
        {"Menu", "Drop-down menu of a <MenuBar> or submenu: contains <MenuItem>, <Menu> and <Separator>.",
         {"Name", "Text", "Enabled", "Visible", "Icon"}, {}},
        {"MenuItem", "Menu item: Click is called when chosen; Shortcut is its keyboard shortcut.",
         {"Name", "Text", "Shortcut", "Icon", "Checked", "Enabled", "Visible", "Click"}, {}},
        {"Separator", "Line that separates groups of menu items.", {"Name", "Visible"}, {}},
    };
    return v;
}

const ElemSpec kUiWindow = {"Window",
                            "Interface window. Generates a 'partial' class with one field per control and the InitializeComponent() method.",
                            {"Class", "Namespace", "Title", "Width", "Height", "Theme", "Resizable", "MinWidth", "MinHeight", "Background",
                             "Background2", "GradientDirection"},
                            {}};

template <class T>
const T* findSpec(const std::vector<T>& v, const std::string& name) {
    for (const T& s : v)
        if (name == s.name) return &s;
    return nullptr;
}

// ---- componentes no visuales de std.audio (<Sound>, <Music>; ver UiGen.cpp)

const std::vector<AttrSpec>& audioAttrs() {
    static const std::vector<AttrSpec> v = {
        {"Source", "Audio file (WAV, OGG or MP3), relative to the current folder or the executable; on Android, inside "
                   "assets/ (add it with <Asset Include=\"...\"/> in the .fstproj).", {}},
        {"Volume", "Volume (1 = original, 0 = silence).", {"0.25", "0.5", "0.8", "1"}},
        {"Pan", "Pan: -1 left, 0 center, 1 right.", {"-1", "0", "1"}},
        {"Speed", "Playback speed (also changes the pitch): 1 normal.", {"0.5", "1", "1.5", "2"}},
        {"Loop", "Repeat when it reaches the end.", kBool},
        {"AutoPlay", "Start playing when the window is created (in InitializeComponent).", kBool},
    };
    return v;
}

#define FST_AUDIO "Name", "Source", "Volume", "Pan", "Speed", "Loop", "AutoPlay"

const std::vector<ElemSpec>& audioComponents() {
    static const std::vector<ElemSpec> v = {
        {"Sound", "Sound (std.audio) decoded in memory: generates a 'Sound' field; play it with Name.Play().", {FST_AUDIO}, {}},
        {"Music", "Music (std.audio) decoded while it plays: generates a 'Music' field with Play, Pause and Stop.", {FST_AUDIO}, {}},
    };
    return v;
}

bool isAudioComponent(const std::string& n) { return n == "Sound" || n == "Music"; }

const AttrSpec* uiAttr(const std::string& n) {
    if (const AttrSpec* a = findSpec(uiAttrs(), n)) return a;
    return findSpec(audioAttrs(), n);
}

const ElemSpec* uiElem(const std::string& n) {
    if (n == "Window") return &kUiWindow;
    if (const ElemSpec* e = findSpec(audioComponents(), n)) return e;
    if (const ElemSpec* p = findSpec(uiParts(), n)) return p;
    return findSpec(uiControls(), n);
}

bool uiIsComponent(const std::string& n) { return n == "Timer" || n == "ContextMenu"; }
bool uiIsMenuOwner(const std::string& n) { return n == "MenuBar" || n == "Menu" || n == "MenuItem" || n == "ContextMenu"; }

// Texto que se inserta al completar el elemento 'name' (etiqueta recién empezada).
std::string uiSnippet(const std::string& name) {
    if (name == "TabControl")
        return "TabControl Name=\"$0\" X=\"0\" Y=\"0\" Width=\"400\" Height=\"300\">\n  <TabPage Text=\"Page 1\">\n  </TabPage>\n</TabControl>";
    if (name == "TreeView") return "TreeView Name=\"$0\" X=\"0\" Y=\"0\" Width=\"220\" Height=\"260\">\n</TreeView>";
    if (name == "MenuBar") return "MenuBar Name=\"$0\">\n  <Menu Text=\"File\">\n  </Menu>\n</MenuBar>";
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
    if (ev == "MessageReceived") return "Widget sender, string message";
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
    for (size_t i = 0; i < v.size(); i++) r += (i == 0 ? "" : i + 1 == v.size() ? " or " : ", ") + v[i];
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

    // <PackageReference>: combinaciones de atributos, versión, carpeta y estado de paquetes.lock.
    void checkPackage(const XTag& t) {
        const XAttr* inc = t.attr("Include");
        const XAttr *ver = t.attr("Version"), *gitA = t.attr("Git"), *pathA = t.attr("Path");
        const XAttr *br = t.attr("Branch"), *cm = t.attr("Commit");
        if (gitA && pathA) at(pathA->nameBeg, "Git and Path cannot be used together");
        if (br && cm) at(cm->nameBeg, "Branch and Commit cannot be used together");
        if (pathA && (br || cm)) at((br ? br : cm)->nameBeg, "Branch and Commit only apply to git packages");
        if (ver && ver->closed && !trim(ver->value).empty()) {
            std::string err;
            if (!packageVersionValid(ver->value, err)) at(ver->valBeg, err);
            if (pathA) at(ver->nameBeg, "with Path the version is not checked (the folder is used as-is)", 2);
            else if (br || cm) at(ver->nameBeg, "Branch and Commit take precedence over Version", 2);
        }
        if (pathA && pathA->closed && !pathA->value.empty()) {
            std::error_code ec;
            if (!fs::exists(fs::path(path).parent_path() / pathA->value, ec))
                at(pathA->valBeg, "folder '" + pathA->value + "' does not exist", 2);
        }
        if (!inc || !inc->closed || trim(inc->value).empty()) return;
        PackageStatus st = lockedPackageStatus(path, trim(inc->value));
        if (!st.locked)
            at(inc->valBeg, std::string("package '") + trim(inc->value) + "' is not restored" +
                                (st.lockExists ? " (not listed in paquetes.lock)" : "") + ": build or run 'faset restore'", 2);
        else if (st.project.empty())
            at(inc->valBeg, "package '" + trim(inc->value) + "' is not downloaded in the cache: run 'faset restore'", 2);
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
                at(off, "<" + name + "> must be true or false (not '" + v + "')");
            return;
        }
        if (name == "OutputType" || name == "TargetPlatform" || name == "TargetArch" || name == "Configuration") {
            if (std::find(spec.values.begin(), spec.values.end(), v) == spec.values.end())
                at(off, "<" + name + "> must be " + joinOr(spec.values) + " (not '" + v + "')");
        } else if (name == "AndroidApi") {
            bool digits = !v.empty() && std::all_of(v.begin(), v.end(), [](char c) { return std::isdigit((unsigned char)c); });
            if (!digits) at(off, "<AndroidApi> must be a number (not '" + v + "')");
        }
    }

    void run() {
        // Estructura
        for (const XTag& t : sc.tags) {
            if (t.name.empty()) {
                at(t.beg, t.closing ? "missing closing tag name" : "missing element name");
                continue;
            }
            if (!t.complete) at(t.beg, "missing '>' in tag <" + std::string(t.closing ? "/" : "") + t.name + ">");
            for (const XAttr& a : t.attrs) {
                if (!a.hasValue) at(a.nameBeg, "missing value for attribute '" + a.name + "' (" + a.name + "=\"...\")");
                else if (!a.closed) at(a.valBeg, "missing closing quote in attribute '" + a.name + "'");
            }
            if (t.closing && t.match < 0) at(t.beg, "</" + t.name + "> does not close any open element");
        }
        for (int k : sc.unclosed) at(sc.tags[k].beg, "missing </" + sc.tags[k].name + "> to close <" + sc.tags[k].name + ">");

        // Contenido
        std::vector<int> roots = sc.childrenOf(-1);
        if (roots.empty()) {
            at(0, "the project file needs a <Project> element");
            return;
        }
        for (size_t i = 0; i < roots.size(); i++) {
            const XTag& r = sc.tags[roots[i]];
            if (i > 0) {
                at(r.nameBeg, "there can be only one root <Project> element");
                continue;
            }
            if (r.name != "Project") {
                at(r.nameBeg, "the root element must be <Project> (not <" + r.name + ">)");
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
                            at(pt.nameBeg, "unknown property <" + pt.name + "> (valid: " + known + ")");
                            continue;
                        }
                        if (!seen.insert(pt.name).second) at(pt.nameBeg, "property <" + pt.name + "> is duplicated in this group", 2);
                        for (const XAttr& a : pt.attrs) at(a.nameBeg, "properties do not allow attributes ('" + a.name + "')");
                        for (int c : sc.childrenOf(p)) at(sc.tags[c].nameBeg, "<" + pt.name + "> cannot contain elements");
                        checkValue(pt, *spec);
                    }
                } else if (gt.name == "ItemGroup") {
                    for (int it : sc.childrenOf(g)) {
                        const XTag& item = sc.tags[it];
                        const ElemSpec* spec = findSpec(projectItems(), item.name);
                        if (!spec) {
                            at(item.nameBeg, "unknown element <" + item.name +
                                                 "> in <ItemGroup> (valid: Compile, NativeLibrary, LibraryPath, ProjectReference, PackageReference, Asset)");
                            continue;
                        }
                        for (const XAttr& a : item.attrs) {
                            if (std::find(spec->attrs.begin(), spec->attrs.end(), a.name) == spec->attrs.end()) {
                                at(a.nameBeg, "unknown attribute '" + a.name + "' in <" + item.name + "> (valid: " +
                                                  joinValues(spec->attrs) + ")");
                            } else if (a.name == "Platform" && a.closed) {
                                const AttrSpec* as = findSpec(projectAttrs(), "Platform");
                                if (std::find(as->values.begin(), as->values.end(), lower(trim(a.value))) == as->values.end())
                                    at(a.valBeg, "Platform must be " + joinOr(as->values) + " (not '" + a.value + "')");
                            }
                        }
                        const XAttr* inc = item.attr("Include");
                        if (!inc && !(item.name == "Compile" && item.attr("Remove")))
                            at(item.nameBeg, "<" + item.name + "> needs the Include attribute");
                        if (item.name == "PackageReference") checkPackage(item);
                        if (inc && inc->closed && item.name == "ProjectReference") {
                            fs::path dir = fs::path(path).parent_path();
                            std::string v = inc->value;
                            size_t start = 0;
                            while (start <= v.size()) {
                                size_t semi = v.find(';', start);
                                std::string ref = trim(v.substr(start, semi == std::string::npos ? std::string::npos : semi - start));
                                std::error_code ec;
                                if (!ref.empty() && !fs::exists(dir / ref, ec))
                                    at(inc->valBeg + start, "referenced project '" + ref + "' does not exist", 2);
                                if (semi == std::string::npos) break;
                                start = semi + 1;
                            }
                        }
                    }
                } else {
                    at(gt.nameBeg, "unknown element <" + gt.name + "> (expected PropertyGroup or ItemGroup)");
                }
            }
        }
        // Red de seguridad: si el analizador del compilador rechaza el XML y no se ha visto el motivo.
        if (out.empty()) {
            XmlNode root;
            std::string err;
            if (!parseXml(s, root, err)) {
                XmlDiagnostic d;
                d.message = "invalid XML: " + err;
                if (err.rfind("line ", 0) == 0) d.line = std::atoi(err.c_str() + 5);
                out.push_back(d);
            }
        }
    }
};

// ================================================================== validación del .fstp

// Errores de estructura (etiquetas sin cerrar, atributos sin valor...).
void structureDiagnostics(const XScan& sc, const std::function<void(size_t, const std::string&)>& at) {
    for (const XTag& t : sc.tags) {
        if (t.name.empty()) {
            at(t.beg, t.closing ? "missing closing tag name" : "missing element name");
            continue;
        }
        if (!t.complete) at(t.beg, "missing '>' in tag <" + std::string(t.closing ? "/" : "") + t.name + ">");
        for (const XAttr& a : t.attrs) {
            if (!a.hasValue) at(a.nameBeg, "missing value for attribute '" + a.name + "' (" + a.name + "=\"...\")");
            else if (!a.closed) at(a.valBeg, "missing closing quote in attribute '" + a.name + "'");
        }
        if (t.closing && t.match < 0) at(t.beg, "</" + t.name + "> does not close any open element");
    }
    for (int k : sc.unclosed) at(sc.tags[k].beg, "missing </" + sc.tags[k].name + "> to close <" + sc.tags[k].name + ">");
}

struct SolutionValidator {
    const std::string& path;
    const std::string& s;
    XScan sc;
    std::vector<XmlDiagnostic> out;
    int startups = 0;
    std::set<std::string> seen;

    SolutionValidator(const std::string& p, const std::string& text) : path(p), s(text), sc(text) {}

    void at(size_t off, const std::string& msg, int severity = 1) {
        XmlDiagnostic d;
        lineCol(s, off, d.line, d.col);
        d.severity = severity;
        d.message = msg;
        out.push_back(d);
    }

    void checkAttrs(const XTag& t, const ElemSpec& spec) {
        for (const XAttr& a : t.attrs) {
            if (std::find(spec.attrs.begin(), spec.attrs.end(), a.name) == spec.attrs.end()) {
                at(a.nameBeg, "unknown attribute '" + a.name + "' in <" + t.name + "> (valid: " + joinValues(spec.attrs) + ")");
                continue;
            }
            const AttrSpec* as = findSpec(solutionAttrs(), a.name);
            if (as && !as->values.empty() && a.closed && a.hasValue) {
                std::string v = a.name == "Startup" ? lower(trim(a.value)) : trim(a.value);
                if (std::find(as->values.begin(), as->values.end(), v) == as->values.end())
                    at(a.valBeg, a.name + " must be " + joinOr(as->values) + " (not '" + a.value + "')");
            }
        }
    }

    void children(int parent) {
        for (int k : sc.childrenOf(parent)) {
            const XTag& t = sc.tags[k];
            if (t.name == "Project") {
                checkAttrs(t, kSolutionProject);
                const XAttr* p = t.attr("Path");
                if (!p) {
                    at(t.nameBeg, "<Project> needs the Path attribute (path to the .fstproj)");
                } else if (p->closed) {
                    std::string rel = trim(p->value);
                    std::error_code ec;
                    fs::path target = (fs::path(path).parent_path() / rel).lexically_normal();
                    if (rel.empty()) at(p->valBeg, "Path is empty");
                    else if (fs::path(rel).extension() != ".fstproj") at(p->valBeg, "Path must be a .fstproj file (not '" + rel + "')");
                    else if (!fs::exists(target, ec)) at(p->valBeg, "project '" + rel + "' does not exist");
                    else if (!seen.insert(fs::weakly_canonical(target, ec).string()).second)
                        at(p->valBeg, "project '" + rel + "' is duplicated in the solution", 2);
                }
                if (const XAttr* st = t.attr("Startup"))
                    if (lower(trim(st->value)) == "true" && ++startups > 1)
                        at(st->nameBeg, "only one project can have Startup=\"true\"");
                for (int c : sc.childrenOf(k)) at(sc.tags[c].nameBeg, "<Project> cannot contain elements");
            } else if (t.name == "Folder") {
                checkAttrs(t, kSolutionFolder);
                const XAttr* n = t.attr("Name");
                if (!n || trim(n->value).empty()) at(t.nameBeg, "<Folder> needs the Name attribute");
                else if (n->value.find('/') != std::string::npos) at(n->valBeg, "the folder name cannot contain '/'");
                children(k);
            } else {
                at(t.nameBeg, "unknown element <" + t.name + "> (expected Project or Folder)");
            }
        }
    }

    void run() {
        structureDiagnostics(sc, [&](size_t off, const std::string& msg) { at(off, msg); });
        std::vector<int> roots = sc.childrenOf(-1);
        if (roots.empty()) {
            at(0, "the solution file needs a <Solution> element");
            return;
        }
        for (size_t i = 0; i < roots.size(); i++) {
            const XTag& r = sc.tags[roots[i]];
            if (i > 0) at(r.nameBeg, "there can be only one root <Solution> element");
            else if (r.name != "Solution") at(r.nameBeg, "the root element must be <Solution> (not <" + r.name + ">)");
            else {
                checkAttrs(r, kSolutionRoot);
                children(roots[i]);
            }
        }
        if (out.empty()) {
            XmlNode root;
            std::string err;
            if (!parseXml(s, root, err)) {
                XmlDiagnostic d;
                d.message = "invalid XML: " + err;
                if (err.rfind("line ", 0) == 0) d.line = std::atoi(err.c_str() + 5);
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
            if (parent) add(out, pname, kElement, "closes <" + pname + ">", pname + ">");
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
        } else if (t.name == "PackageReference" && (c.attr->name == "Version" || c.attr->name == "Branch")) {
            const AttrSpec* as = findSpec(projectAttrs(), c.attr->name);
            for (const std::string& v : as->values) add(out, v, kValue, as->doc);
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
                        add(out, rel, kFile, "project " + f.path().stem().string());
                    }
            }
        } else if (c.attr->name == "Include" && t.name == "NativeLibrary") {
            for (const char* l : {"m", "pthread", "dl", "X11", "GL", "vulkan", "freetype", "user32", "gdi32", "kernel32", "ws2_32"})
                add(out, l, kValue, "native library");
        }
        return;
    }
    if (c.kind == Ctx::Text && parent && sc.tags[c.parent].parent >= 0 && sc.tags[sc.tags[c.parent].parent].name == "PropertyGroup") {
        const ElemSpec* spec = findSpec(projectProps(), pname);
        if (!spec) return;
        if (pname == "AssemblyName" || pname == "RootNamespace") {
            std::string stem = fs::path(path).stem().string();
            add(out, stem, kValue, "project name");
        }
        for (const std::string& v : spec->values) add(out, v, kValue, spec->doc);
    }
}

void completeSolution(const XScan& sc, const std::string& path, const CursorCtx& c, std::vector<XmlCompletionItem>& out) {
    const XTag* parent = c.parent >= 0 ? &sc.tags[c.parent] : nullptr;
    std::string pname = parent ? parent->name : "";
    if (c.kind == Ctx::ElementName) {
        const XTag& t = sc.tags[c.tag];
        if (t.closing) {
            if (parent) add(out, pname, kElement, "closes <" + pname + ">", pname + ">");
            return;
        }
        bool bare = bareTag(t);
        if (!parent) {
            std::string name = fs::path(path).stem().string();
            add(out, "Solution", kElement, kSolutionRoot.doc, bare ? "Solution Name=\"" + name + "\">\n  $0\n</Solution>" : "");
        } else if (pname == "Solution" || pname == "Folder") {
            add(out, "Project", kElement, kSolutionProject.doc, bare ? "Project Path=\"$0\" />" : "");
            add(out, "Folder", kElement, kSolutionFolder.doc, bare ? "Folder Name=\"$0\">\n</Folder>" : "");
        }
        return;
    }
    if (c.kind == Ctx::AttrName) {
        const XTag& t = sc.tags[c.tag];
        const ElemSpec* spec = solutionElem(t.name);
        if (!spec) return;
        for (const std::string& a : spec->attrs) {
            if (t.attr(a)) continue;
            const AttrSpec* as = findSpec(solutionAttrs(), a);
            add(out, a, kProperty, as ? as->doc : "", a + "=\"$0\"");
        }
        return;
    }
    if (c.kind == Ctx::AttrValue) {
        const XTag& t = sc.tags[c.tag];
        if (c.attr->name == "Path" && t.name == "Project") {
            // Los .fstproj bajo la carpeta de la solución que aún no están en ella.
            std::set<std::string> present;
            for (const XTag& o : sc.tags)
                if (&o != &t && !o.closing && o.name == "Project")
                    if (const XAttr* p = o.attr("Path")) present.insert(trim(p->value));
            std::error_code ec;
            fs::path dir = fs::path(path).parent_path();
            auto it = fs::recursive_directory_iterator(dir, fs::directory_options::skip_permission_denied, ec);
            int found = 0;
            for (; it != fs::recursive_directory_iterator() && found < 200; it.increment(ec)) {
                if (ec) break;
                std::string name = it->path().filename().string();
                if (it->is_directory(ec)) {
                    if (name == "bin" || name == "obj" || (!name.empty() && name[0] == '.') || it.depth() >= 4) it.disable_recursion_pending();
                    continue;
                }
                if (it->path().extension() != ".fstproj") continue;
                std::string rel = fs::relative(it->path(), dir, ec).generic_string();
                if (present.count(rel)) continue;
                add(out, rel, kFile, "project " + it->path().stem().string());
                found++;
            }
            return;
        }
        if (const AttrSpec* as = findSpec(solutionAttrs(), c.attr->name))
            for (const std::string& v : as->values) add(out, v, kValue, as->doc);
    }
}

void completeUi(const XScan& sc, const std::string& path, const CursorCtx& c, const XmlUiCodeInfo* code,
                std::vector<XmlCompletionItem>& out) {
    const XTag* parent = c.parent >= 0 ? &sc.tags[c.parent] : nullptr;
    std::string pname = parent ? parent->name : "";
    if (c.kind == Ctx::ElementName) {
        const XTag& t = sc.tags[c.tag];
        if (t.closing) {
            if (parent) add(out, pname, kElement, "closes <" + pname + ">", pname + ">");
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
            if (pname == "Window")
                for (const ElemSpec& e : audioComponents())
                    add(out, e.name, kElement, e.doc, bare ? std::string(e.name) + " Name=\"$0\" Source=\"\" />" : "");
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
                // Paint, los eventos del ratón y MessageReceived reciben un segundo parámetro.
                bool fits = params == "Widget sender" ? m.handler
                          : params.find("string") != std::string::npos ? m.signature.find(", string") != std::string::npos
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
            if (!exists) add(out, fresh, kMethod, "new handler: void " + fresh + "(" + params + ")");
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
        if ((a.name == "Source" && t.name == "PictureBox") || a.name == "Icon") {
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
                add(out, fs::relative(it->path(), dir, ec).generic_string(), kFile, "image");
                seen++;
            }
            return;
        }
        if (a.name == "Class" && t.name == "Window") {
            add(out, fs::path(path).stem().string(), kValue, "window class");
            return;
        }
        if (a.name == "Source" && isAudioComponent(t.name)) {
            // Archivos de audio de la carpeta del .fstui (y subcarpetas, sin bin/ ni obj/).
            std::error_code ec;
            fs::path dir = fs::path(path).parent_path();
            auto it = fs::recursive_directory_iterator(dir, fs::directory_options::skip_permission_denied, ec);
            int found = 0;
            for (; it != fs::recursive_directory_iterator() && found < 200; it.increment(ec)) {
                if (ec) break;
                std::string name = it->path().filename().string();
                if (it->is_directory(ec)) {
                    if (name == "bin" || name == "obj" || (!name.empty() && name[0] == '.')) it.disable_recursion_pending();
                    continue;
                }
                std::string ext = lower(it->path().extension().string());
                if (ext == ".wav" || ext == ".ogg" || ext == ".mp3") {
                    add(out, fs::relative(it->path(), dir).generic_string(), kFile, "audio file");
                    found++;
                }
            }
            return;
        }
        std::set<std::string> skip = as->flags ? otherFlags(a, c.valueOff) : std::set<std::string>();
        for (const std::string& v : as->values)
            if (!skip.count(lower(v))) add(out, v, kValue, as->doc);
    }
}

std::string attrHover(const AttrSpec& a) {
    std::string h = a.name + std::string(" — ") + a.doc;
    if (!a.values.empty() && !a.handler) h += "\nValues: " + joinValues(a.values);
    return h;
}

}  // namespace

// ================================================================== API

XmlDocKind xmlDocKind(const std::string& path) {
    std::string ext = fs::path(path).extension().string();
    if (ext == ".fstproj") return XmlDocKind::Project;
    if (ext == ".fstui") return XmlDocKind::Ui;
    if (ext == ".fstp") return XmlDocKind::Solution;
    return XmlDocKind::None;
}

std::vector<XmlDiagnostic> xmlValidateProject(const std::string& path, const std::string& text) {
    ProjectValidator v(path, text);
    v.run();
    return v.out;
}

std::vector<XmlDiagnostic> xmlValidateSolution(const std::string& path, const std::string& text) {
    SolutionValidator v(path, text);
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
    else if (kind == XmlDocKind::Solution) completeSolution(sc, path, c, out);
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
        const ElemSpec* spec = kind == XmlDocKind::Project    ? projectElem(t.name)
                             : kind == XmlDocKind::Solution ? solutionElem(t.name)
                                                            : uiElem(t.name);
        if (spec) {
            std::string h = "<" + t.name + "> — " + spec->doc;
            if (!spec->values.empty()) h += "\nValues: " + joinValues(spec->values);
            ref(t.nameBeg, t.name.size(), h);
        }
        if (t.closing) continue;
        for (const XAttr& a : t.attrs) {
            if (kind == XmlDocKind::Solution) {
                if (const AttrSpec* as = findSpec(solutionAttrs(), a.name)) ref(a.nameBeg, a.name.size(), attrHover(*as));
                if (t.name == "Project" && a.name == "Path" && a.closed && !a.value.empty()) {
                    // Ir a la definición abre el .fstproj.
                    fs::path target = (fs::path(path).parent_path() / a.value).lexically_normal();
                    std::error_code ec;
                    bool exists = fs::exists(target, ec);
                    XmlSymbolRef& r = ref(a.valBeg, a.value.size(), (exists ? "project " : "missing project ") + target.string());
                    if (exists) {
                        r.defPath = target.string();
                        r.defLine = r.defCol = 1;
                    }
                }
                continue;
            }
            if (kind == XmlDocKind::Project) {
                if (const AttrSpec* as = findSpec(projectAttrs(), a.name)) ref(a.nameBeg, a.name.size(), attrHover(*as));
                if (t.name == "PackageReference" && a.name == "Include" && a.closed && !trim(a.value).empty()) {
                    // Información del paquetes.lock e "ir a la definición" abre el .fstproj del paquete.
                    PackageStatus st = lockedPackageStatus(path, trim(a.value));
                    XmlSymbolRef& r = ref(a.valBeg, a.value.size(),
                                          st.locked ? st.description : "package " + trim(a.value) + " (not restored: faset restore)");
                    if (!st.project.empty()) {
                        r.defPath = st.project;
                        r.defLine = r.defCol = 1;
                    }
                }
                if (t.name == "PackageReference" && a.name == "Path" && a.closed && !a.value.empty()) {
                    fs::path target = (fs::path(path).parent_path() / a.value).lexically_normal();
                    ref(a.valBeg, a.value.size(), "folder " + target.string());
                }
                if (t.name == "ProjectReference" && a.name == "Include" && a.closed && !a.value.empty()) {
                    fs::path target = (fs::path(path).parent_path() / a.value).lexically_normal();
                    std::error_code ec;
                    XmlSymbolRef& r = ref(a.valBeg, a.value.size(), "project " + target.string());
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
                ref(a.valBeg, a.value.size(), "(field) " + std::string(isAudioComponent(t.name) ? t.name : "Widget") + " " + cls + "." + a.value);
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
    // "invalid XML: line N: ..."
    size_t p = message.find("line ");
    if (message.rfind("invalid XML", 0) == 0 && p != std::string::npos) {
        line = std::max(1, std::atoi(message.c_str() + p + 5));
        col = 1;
    }
    XScan sc(text);
    size_t lineOff = offsetOfLine(text, line);
    if (message.rfind("invalid XML", 0) == 0) {
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
