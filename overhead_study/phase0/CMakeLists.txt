# Phase-0 standalone build for the instrumented Mofka example.
# Mirrors install/_mofka/example/CMakeLists.txt: mofka::client transitively pulls in
# diaspora / thallium / bedrock / nlohmann_json / spdlog / fmt from the spack view, so
# no manual include or library paths are needed -- CMAKE_PREFIX_PATH (set by
# `spack env activate`) resolves find_package(mofka).
cmake_minimum_required (VERSION 3.19)
project (phase0_mofka_timing CXX)

set (CMAKE_CXX_STANDARD 17)
set (CMAKE_CXX_STANDARD_REQUIRED ON)
add_compile_options (-Wall -Wextra)

# mofka::client's transitive interface lists `bedrock-module-api` as a bare library
# name, but mofka-config.cmake / bedrock-config.cmake never find_dependency() it, so
# without this the imported target is undefined and the link degrades to a bare
# `-lbedrock-module-api` that ld cannot locate. Importing the package first defines the
# target (with its full IMPORTED_LOCATION), so the transitive reference resolves to the
# real .so in the spack view. Both configs are on CMAKE_PREFIX_PATH via `spack env activate`.
find_package (bedrock-module-api REQUIRED)
find_package (mofka REQUIRED)

add_executable (producer_timed producer_timed.cpp)
target_link_libraries (producer_timed mofka::client)

add_executable (consumer consumer.cpp)
target_link_libraries (consumer mofka::client)
