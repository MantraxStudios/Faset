// Faset - servidor de lenguaje (LSP) para editores como VS Code.
//
//   faset lsp                        servidor JSON-RPC por stdin/stdout
//   faset __analyze <req> <res>      análisis aislado (lo lanza el servidor en un subproceso
//                                    para que la memoria se libere siempre al terminar)
#pragma once
#include <string>

int runLanguageServer(const std::string& argv0);
int runAnalyzer(const std::string& requestPath, const std::string& resultPath, const std::string& argv0);
