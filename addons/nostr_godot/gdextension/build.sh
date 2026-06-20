#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Building libsecp256k1 ==="
cd libsecp256k1
mkdir -p build_cmake
cmake -S . -B build_cmake \
    -DSECP256K1_ENABLE_MODULE_SCHNORRSIG=ON \
    -DSECP256K1_ENABLE_MODULE_ECDH=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DSECP256K1_DISABLE_SHARED=ON \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    2>&1 | tail -3
cmake --build build_cmake -j$(nproc) --target secp256k1 2>&1 | tail -3
cd ..

echo "=== Building godot-cpp ==="
cd godot-cpp
scons platform=linux -j$(nproc) 2>&1 | tail -3
cd ..

echo "=== Building nostr_crypto GDExtension ==="
mkdir -p build
g++ -c -fPIC -std=c++17 \
    -I godot-cpp/include \
    -I godot-cpp/gen/include \
    -I godot-cpp/gdextension \
    -I libsecp256k1/include \
    -I libsecp256k1/src \
    src/nostr_crypto.cpp -o build/nostr_crypto.o

g++ -shared -o build/libnostr_crypto.so \
    build/nostr_crypto.o \
    -L libsecp256k1/build_cmake/lib \
    -L godot-cpp/bin \
    -lsecp256k1 \
    -lgodot-cpp.linux.template_debug.x86_64 \
    -lpthread

mkdir -p lib
cp build/libnostr_crypto.so lib/libnostr_crypto.so

echo "=== Build complete ==="
echo "Library: lib/libnostr_crypto.so ($(du -h lib/libnostr_crypto.so | cut -f1))"
