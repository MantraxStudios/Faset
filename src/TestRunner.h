// Faset - 'faset test': pruebas unitarias ([Test], [TestCase], [Ignore], [Setup], [Teardown]).
//
// Descubre las pruebas de un proyecto (o de archivos sueltos), genera un 'main' que las ejecuta
// (clase __FasetPruebas, con std.test.TestHarness), lo compila y lanza el programa leyendo sus
// resultados. Ver TestRunner.cpp y docs "Pruebas unitarias".
#pragma once
#include <functional>
#include <set>
#include <string>
#include <vector>

// ¿Es un atributo de las pruebas? (Sema los acepta en los métodos)
bool isTestAttribute(const std::string& name);

// Mientras se compila el programa de pruebas, el punto de entrada es el 'Main' de esta clase
// generada (se ignora el Main del proyecto).
extern bool testHarnessEntry;
extern const char* const kTestHarnessClass;

// Archivos de pruebas de un proyecto que no es <IsTestProject>: los de la carpeta tests/ y los
// *Tests.fst. 'faset build' no los compila; 'faset test' sí.
bool isTestSourceFile(const std::string& file, const std::string& projectDir);

// Lo que 'faset test' necesita del compilador (main.cpp).
struct TestBuildHost {
    std::vector<std::string> inputs;  // fuentes del usuario (.fst, .fstui)
    std::string projectPath;          // .fstproj ("" si son archivos sueltos)
    std::string projectName;
    std::string objDir;               // carpeta para el main generado y el ejecutable
    std::vector<std::string> args;    // opciones de 'faset test' (--filter, --report...)
    std::string selfExe;
    std::set<std::string> defines;    // compilación condicional (para leer los archivos)
    bool verbose = false;
    // Compila 'inputs' (con el main generado) a un ejecutable; 0 si va bien.
    std::function<int(const std::vector<std::string>& inputs, const std::string& output)> build;
};

// Separa de 'args' las opciones propias de 'faset test' (se guardan en 'testArgs').
// Devuelve false (con el error ya mostrado) si alguna está mal.
bool takeTestOptions(std::vector<std::string>& args, std::vector<std::string>& testArgs);

// 'faset test' de una solución .fstp: ejecuta las pruebas de cada proyecto. Devuelve false si
// la entrada no es una solución.
bool solutionTestCommand(const std::vector<std::string>& args, const std::string& argv0, int& code);

// Ejecuta las pruebas de un proyecto o de archivos sueltos. Código de salida de 'faset test'.
int runTests(const TestBuildHost& host);
