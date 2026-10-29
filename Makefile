# Faset - compilación del compilador.
CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter
SRCS     := $(wildcard src/*.cpp)
OBJS     := $(SRCS:src/%.cpp=build/%.o)
BIN      := faset

ifeq ($(OS),Windows_NT)
  BIN := faset.exe
endif

all: $(BIN)

$(BIN): $(OBJS)
	$(CXX) $(CXXFLAGS) -o $@ $^

build/%.o: src/%.cpp $(wildcard src/*.h) | build
	$(CXX) $(CXXFLAGS) -c $< -o $@

build:
	mkdir -p build

test: $(BIN)
	./tests/run.sh

PREFIX ?= /usr/local

# Instala el compilador y la biblioteca estándar (lib/ -> $(PREFIX)/lib/faset).
install: $(BIN)
	install -Dm755 $(BIN) $(DESTDIR)$(PREFIX)/bin/$(BIN)
	mkdir -p $(DESTDIR)$(PREFIX)/lib/faset
	cp -r lib/. $(DESTDIR)$(PREFIX)/lib/faset/

# FasetStudio: el IDE de Faset, escrito en Faset (Vulkan + X11 + FreeType).
studio: $(BIN)
	./$(BIN) build studio

studio-run: studio
	./studio/bin/Release/linux-x86_64/FasetStudio .

# Instala la extensión de VS Code enlazando editors/vscode (los cambios se ven al recargar VS Code).
VSCODE_EXT_DIR ?= $(HOME)/.vscode/extensions
vscode-install: $(BIN)
	mkdir -p $(VSCODE_EXT_DIR)
	ln -sfn $(CURDIR)/editors/vscode $(VSCODE_EXT_DIR)/faset.faset-0.2.0
	@echo "Extensión instalada. En VS Code: Ctrl+Shift+P -> 'Developer: Reload Window'."

vscode-uninstall:
	rm -f $(VSCODE_EXT_DIR)/faset.faset-0.2.0

# Paquetes de distribución (dist/faset-linux-x86_64.tar.gz y, con toolchain de Windows, el .zip).
dist: $(BIN)
	scripts/dist.sh all

clean:
	rm -rf build $(BIN)

.PHONY: all test install dist clean vscode-install vscode-uninstall studio studio-run
