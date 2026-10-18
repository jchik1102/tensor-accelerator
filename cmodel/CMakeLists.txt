# C++ model of ta_core (include/ta_model.hpp) and its unit tests.
#   cmake -S cmodel -B build/cmodel -DTA_VECTORS=<dir with core.txt, quant.txt>
#   cmake --build build/cmodel && ctest --test-dir build/cmodel --output-on-failure
# The same sources are compiled into XSim's DPI library by scripts/run-sim.ps1.
cmake_minimum_required(VERSION 3.16)
project(ta_model CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()
add_compile_options(-Wall -Wextra -Werror)

set(TA_VECTORS "${CMAKE_CURRENT_SOURCE_DIR}/../artifacts/vectors" CACHE PATH "directory with core.txt and quant.txt")

add_library(ta_model src/ta_model.cpp)
target_include_directories(ta_model PUBLIC include)

enable_testing()
foreach(t test_requant test_core test_replay)
  add_executable(${t} tests/${t}.cpp)
  target_link_libraries(${t} PRIVATE ta_model)
endforeach()
add_test(NAME requant COMMAND test_requant ${TA_VECTORS}/quant.txt)
add_test(NAME core COMMAND test_core)
add_test(NAME replay_4x4 COMMAND test_replay ${TA_VECTORS}/core.txt 4)
add_test(NAME replay_8x8 COMMAND test_replay ${TA_VECTORS}/core.txt 8)
