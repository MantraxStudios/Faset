// Faset - IntelliSense de los archivos XML de Faset: proyectos .fstproj e interfaces .fstui.
//
// Lo usa 'faset __analyze' (y por tanto el servidor de lenguaje y FasetStudio):
//   - autocompletado de elementos, atributos y valores según el esquema de cada archivo
//   - validación del .fstproj con la línea y la columna de cada error
//   - información al pasar el ratón sobre elementos y atributos
//   - en .fstui, nombres de manejadores (Click, Changed) sacados del código de la ventana
//
// El análisis es tolerante: funciona con XML a medio escribir.
#pragma once
#include <string>
#include <vector>

enum class XmlDocKind { None, Project, Ui };

XmlDocKind xmlDocKind(const std::string& path);

struct XmlDiagnostic {
    int line = 1, col = 1;  // desde 1; columna en bytes
    int severity = 1;       // 1 error, 2 aviso
    std::string message;
};

struct XmlCompletionItem {
    std::string label, detail;
    std::string insert;  // texto a insertar si no es 'label'; "$0" marca dónde queda el cursor
    int kind = 10;       // CompletionItemKind de LSP
};

struct XmlSymbolRef {
    int line = 1, col = 1, len = 0;
    std::string hover;
    std::string defPath;  // "" si no hay definición
    int defLine = 0, defCol = 0;
};

// Lo que el análisis semántico sabe de la clase de una ventana .fstui.
struct XmlUiCodeInfo {
    struct Method {
        std::string name, signature, path;
        int line = 1, col = 1;
        bool handler = false;  // void Nombre(Widget sender)
    };
    bool found = false;
    std::string classSignature;  // "partial class Demo.MainWindow"
    std::string classPath;       // archivo del código de la ventana
    int classLine = 1, classCol = 1;
    std::vector<Method> methods;
};

// Validación completa de un .fstproj (estructura XML, elementos, propiedades y valores).
std::vector<XmlDiagnostic> xmlValidateProject(const std::string& path, const std::string& text);

// Sugerencias en la posición 'offset' (en bytes) del texto.
std::vector<XmlCompletionItem> xmlComplete(XmlDocKind kind, const std::string& path, const std::string& text, size_t offset,
                                           const XmlUiCodeInfo* code);

// Símbolos con información emergente (y definición, si la hay) de todo el documento.
std::vector<XmlSymbolRef> xmlRefs(XmlDocKind kind, const std::string& path, const std::string& text, const XmlUiCodeInfo* code);

// Clase y namespace de la ventana de un .fstui (atributos Class y Namespace de <Window>).
bool xmlUiClass(const std::string& text, std::string& cls, std::string& ns);

// Posición del valor de Name="name" en un .fstui.
bool xmlUiControlPos(const std::string& text, const std::string& name, int& line, int& col);

// El generador de .fstui solo conoce la línea del elemento: lleva el diagnóstico al atributo o
// valor que menciona el mensaje (y a la línea correcta en los errores de XML mal formado).
void xmlRefineUiDiagnostic(const std::string& text, const std::string& message, int& line, int& col);
