#include "Common.h"

#include <cstdio>

Diagnostics diag;

void Diagnostics::error(const SourceLoc& loc, const std::string& msg) {
    ++errorCount;
    if (capture) {
        captured.push_back({Severity::Error, loc, true, msg});
        return;
    }
    const char* f = (loc.file >= 0 && loc.file < (int)files.size()) ? files[loc.file].c_str() : "?";
    std::fprintf(stderr, "%s:%d:%d: error: %s\n", f, loc.line, loc.col, msg.c_str());
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
    const char* f = (loc.file >= 0 && loc.file < (int)files.size()) ? files[loc.file].c_str() : "?";
    std::fprintf(stderr, "%s:%d:%d: nota: %s\n", f, loc.line, loc.col, msg.c_str());
}
