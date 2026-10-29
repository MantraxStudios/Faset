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

# La biblioteca estándar (lib/) se copia junto al ejecutable para que 'faset' la encuentre.
add_custom_command(TARGET faset POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_directory ${CMAKE_SOURCE_DIR}/lib $<TARGET_FILE_DIR:faset>/lib)

install(TARGETS faset RUNTIME DESTINATION bin)
install(DIRECTORY lib/ DESTINATION lib/faset)
