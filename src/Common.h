// Faset - utilidades comunes: ubicaciones en el código fuente y diagnósticos.
#pragma once
#include <cstdint>
#include <string>
#include <vector>

struct SourceLoc {
    int file = 0;
    int line = 1;
    int col = 1;  // en bytes, empezando en 1
};

class Diagnostics {
public:
    enum class Severity { Error, Note, Warning };
    struct Entry {
        Severity severity;
        SourceLoc loc;
        bool hasLoc;
        std::string message;
    };

    std::vector<std::string> files;  // nombre a mostrar
    std::vector<std::string> paths;  // ruta absoluta ("" si no es un archivo)
    int errorCount = 0;
    // En modo captura (servidor de lenguaje) los mensajes se guardan en vez de imprimirse.
    bool capture = false;
    std::vector<Entry> captured;

    int addFile(const std::string& name, const std::string& path = "") {
        files.push_back(name);
        paths.push_back(path);
        return (int)files.size() - 1;
    }
    void error(const SourceLoc& loc, const std::string& msg);
    void fatal(const std::string& msg);
    void note(const SourceLoc& loc, const std::string& msg);
    void warning(const SourceLoc& loc, const std::string& msg);  // no impide compilar ([Obsolete])
    void reset() { *this = Diagnostics(); }
};

extern Diagnostics diag;
