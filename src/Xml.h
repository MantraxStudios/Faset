// Faset - XML mínimo (proyectos .fstproj e interfaces .fstui).
#pragma once
#include <map>
#include <string>
#include <vector>

struct XmlNode {
    std::string name, text;
    std::map<std::string, std::string> attrs;
    std::vector<std::string> attrOrder;  // orden original de los atributos
    std::vector<XmlNode> children;
    int line = 1;
};

// Analiza el primer elemento de 'src'. Devuelve false y rellena 'error' si no es válido.
bool parseXml(const std::string& src, XmlNode& root, std::string& error);
