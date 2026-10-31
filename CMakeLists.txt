# Faset - compilación del compilador con CMake (Windows con MinGW/MSVC, Linux, macOS).
cmake_minimum_required(VERSION 3.16)
project(faset CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

file(GLOB FASET_SOURCES ${CMAKE_SOURCE_DIR}/src/*.cpp)
add_executable(faset ${FASET_SOURCES})

if(MSVC)
  target_compile_options(faset PRIVATE /W4 /utf-8)
else()
  target_compile_options(faset PRIVATE -Wall -Wextra -Wno-unused-parameter)
endif()

# Comptime evaluation recurses on the native stack, so deep compile-time recursion must have room
# to hit the kCtMaxDepth guard (which reports "recursion too deep") instead of overflowing the
# default 1 MB Windows stack and crashing the compiler. Reserve a large stack (address space only,
# committed lazily). On Linux the main-thread stack is governed by ulimit, so this is Windows-only.
if(WIN32)
  if(MSVC)
    target_link_options(faset PRIVATE /STACK:268435456)
  else()
    target_link_options(faset PRIVATE -Wl,/STACK:268435456)
  endif()
endif()

# La biblioteca estándar (lib/) se copia junto al ejecutable para que 'faset' la encuentre.
add_custom_command(TARGET faset POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_directory ${CMAKE_SOURCE_DIR}/lib $<TARGET_FILE_DIR:faset>/lib)

install(TARGETS faset RUNTIME DESTINATION bin)
install(DIRECTORY lib/ DESTINATION lib/faset)
