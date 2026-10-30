#include "Common.h"

#include <cstdio>

#include "Frontend.h"  // nativeToUtf8

Diagnostics diag;

void Diagnostics::error(const SourceLoc& loc, const std::string& msg) {
    ++errorCount;
    if (capture) {
        captured.push_back({Severity::Error, loc, true, msg});
        return;
    }
    // En Windows el nombre está en la página ANSI y el mensaje en UTF-8: todo sale en UTF-8.
    std::string f = (loc.file >= 0 && loc.file < (int)files.size()) ? nativeToUtf8(files[loc.file]) : "?";
    std::fprintf(stderr, "%s:%d:%d: error: %s\n", f.c_str(), loc.line, loc.col, msg.c_str());
}

void Diagnostics::fatal(const std::string& msg) {
    ++errorCount;
    if (capture) {
        captured.push_back({Severity::Error, SourceLoc(), false, msg});
        return;
    }
    std::fprintf(stderr, "faset: error: %s\n", msg.c_str());
}

void Diagnostics::note(const SourceLoc& loc, const std::string& msg) {
    if (capture) {
        captured.push_back({Severity::Note, loc, true, msg});
        return;
    }
    // En Windows el nombre está en la página ANSI y el mensaje en UTF-8: todo sale en UTF-8.
    std::string f = (loc.file >= 0 && loc.file < (int)files.size()) ? nativeToUtf8(files[loc.file]) : "?";
    std::fprintf(stderr, "%s:%d:%d: nota: %s\n", f.c_str(), loc.line, loc.col, msg.c_str());
}

void Diagnostics::warning(const SourceLoc& loc, const std::string& msg) {
    if (capture) {
        captured.push_back({Severity::Warning, loc, true, msg});
        return;
    }
    std::string f = (loc.file >= 0 && loc.file < (int)files.size()) ? nativeToUtf8(files[loc.file]) : "?";
    std::fprintf(stderr, "%s:%d:%d: aviso: %s\n", f.c_str(), loc.line, loc.col, msg.c_str());
}
