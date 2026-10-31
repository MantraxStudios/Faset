#include "Xml.h"

#include <algorithm>
#include <cctype>

namespace {


struct XmlParser {
    const std::string& s;
    size_t i = 0;
    std::string error;

    explicit XmlParser(const std::string& src) : s(src) {}

    int lineAt(size_t pos) const { return 1 + (int)std::count(s.begin(), s.begin() + (long)std::min(pos, s.size()), '\n'); }
    bool fail(const std::string& msg) {
        if (error.empty()) error = "line " + std::to_string(lineAt(i)) + ": " + msg;
        return false;
    }
    void skipWs() {
        for (;;) {
            while (i < s.size() && isspace((unsigned char)s[i])) i++;
            if (s.compare(i, 4, "<!--") == 0) {
                size_t e = s.find("-->", i);
                i = e == std::string::npos ? s.size() : e + 3;
            } else if (s.compare(i, 2, "<?") == 0) {
                size_t e = s.find("?>", i);
                i = e == std::string::npos ? s.size() : e + 2;
            } else {
                return;
            }
        }
    }
    static std::string unescape(const std::string& v) {
        std::string r;
        for (size_t k = 0; k < v.size(); k++) {
            if (v[k] == '&') {
                size_t e = v.find(';', k);
                if (e != std::string::npos) {
                    std::string ent = v.substr(k + 1, e - k - 1);
                    if (ent == "lt") r += '<';
                    else if (ent == "gt") r += '>';
                    else if (ent == "amp") r += '&';
                    else if (ent == "quot") r += '"';
                    else if (ent == "apos") r += '\'';
                    else r += "&" + ent + ";";
                    k = e;
                    continue;
                }
            }
            r += v[k];
        }
        return r;
    }
    std::string name() {
        size_t b = i;
        while (i < s.size() && (isalnum((unsigned char)s[i]) || s[i] == '_' || s[i] == '-' || s[i] == '.' || s[i] == ':')) i++;
        return s.substr(b, i - b);
    }
    bool element(XmlNode& n) {
        skipWs();
        if (i >= s.size() || s[i] != '<') return fail("expected '<'");
        n.line = lineAt(i);
        i++;
        n.name = name();
        if (n.name.empty()) return fail("empty element name");
        for (;;) {
            skipWs();
            if (i >= s.size()) return fail("end of file inside <" + n.name + ">");
            if (s.compare(i, 2, "/>") == 0) {
                i += 2;
                return true;
            }
            if (s[i] == '>') {
                i++;
                break;
            }
            std::string a = name();
            if (a.empty()) return fail("malformed attribute in <" + n.name + ">");
            skipWs();
            if (i >= s.size() || s[i] != '=') return fail("expected '=' in attribute '" + a + "'");
            i++;
            skipWs();
            if (i >= s.size() || (s[i] != '"' && s[i] != '\'')) return fail("expected quotes in '" + a + "'");
            char q = s[i++];
            size_t e = s.find(q, i);
            if (e == std::string::npos) return fail("unterminated attribute");
            n.attrs[a] = unescape(s.substr(i, e - i));
            n.attrOrder.push_back(a);
            i = e + 1;
        }
        for (;;) {
            size_t b = i;
            while (i < s.size() && s[i] != '<') i++;
            n.text += s.substr(b, i - b);
            if (s.compare(i, 4, "<!--") == 0) {
                skipWs();
                continue;
            }
            if (i >= s.size()) return fail("missing </" + n.name + ">");
            if (s.compare(i, 2, "</") == 0) {
                i += 2;
                std::string close = name();
                skipWs();
                if (close != n.name) return fail("expected </" + n.name + "> but found </" + close + ">");
                if (i >= s.size() || s[i] != '>') return fail("expected '>'");
                i++;
                n.text = unescape(n.text);
                size_t a = n.text.find_first_not_of(" \t\r\n"), z = n.text.find_last_not_of(" \t\r\n");
                n.text = a == std::string::npos ? "" : n.text.substr(a, z - a + 1);
                return true;
            }
            XmlNode child;
            if (!element(child)) return false;
            n.children.push_back(std::move(child));
        }
    }
};


}  // namespace

bool parseXml(const std::string& src, XmlNode& root, std::string& error) {
    XmlParser xp(src);
    if (!xp.element(root)) {
        error = xp.error;
        return false;
    }
    return true;
}
