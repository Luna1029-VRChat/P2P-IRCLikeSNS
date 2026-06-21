cmake_minimum_required(VERSION 3.20)
project(nostr_crypto_gdextension)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(EMSCRIPTEN)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -pthread -sSHARED_MEMORY=1")
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -pthread -sSHARED_MEMORY=1")
    set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -pthread -sSHARED_MEMORY=1")
    set(CMAKE_EXECUTABLE_SUFFIX ".wasm")
    set(CMAKE_SHARED_LIBRARY_SUFFIX ".wasm")
endif()

# libsecp256k1
add_library(secp256k1 STATIC
    libsecp256k1/src/secp256k1.c
)
target_include_directories(secp256k1 PUBLIC libsecp256k1)
target_include_directories(secp256k1 PRIVATE libsecp256k1/src)
target_compile_definitions(secp256k1 PRIVATE
    SECP256K1_BUILD
    HAVE_CONFIG_H
    ENABLE_MODULE_SCHNORRSIG
    ENABLE_MODULE_ECDH
)

# godot-cpp
file(GLOB_RECURSE GODOT_CPP_SRC
    godot-cpp/src/*.cpp
)

add_library(godotcpp STATIC ${GODOT_CPP_SRC})
target_include_directories(godotcpp PUBLIC
    godot-cpp/include
    godot-cpp/gdextension
)
target_compile_definitions(godotcpp PRIVATE GODOT_GDEXTENSION)

# nostr_crypto GDExtension
if(EMSCRIPTEN)
    add_library(nostr_crypto MODULE
        src/nostr_crypto.cpp
    )
    target_link_options(nostr_crypto PRIVATE -sSIDE_MODULE=1)
else()
    add_library(nostr_crypto SHARED
        src/nostr_crypto.cpp
    )
endif()
target_include_directories(nostr_crypto PRIVATE
    libsecp256k1
    libsecp256k1/src
    godot-cpp/include
    godot-cpp/gdextension
)
target_link_libraries(nostr_crypto PRIVATE secp256k1 godotcpp)

# Install target
set(LIB_DIR "${CMAKE_SOURCE_DIR}/lib")
if(EMSCRIPTEN)
    install(TARGETS nostr_crypto LIBRARY DESTINATION ${LIB_DIR})
    # Rename to match Godot's expected naming
    set_target_properties(nostr_crypto PROPERTIES OUTPUT_NAME "nostr_crypto.web.template_release.wasm32")
else()
    install(TARGETS nostr_crypto LIBRARY DESTINATION ${LIB_DIR})
endif()
