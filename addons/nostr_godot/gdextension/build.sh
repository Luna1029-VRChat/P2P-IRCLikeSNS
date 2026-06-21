#!/bin/bash
set -e

usage() {
    echo "Usage: $0 -p <platform> [-a <arch>] [-t debug|release]"
    echo "  Platforms: linux, windows, macos, web, android"
    echo "  Arch (default: x86_64): x86_64, arm64, wasm32"
    echo "  Examples:"
    echo "    $0 -p linux -a x86_64"
    echo "    $0 -p linux -a arm64"
    echo "    $0 -p windows -a x86_64"
    echo "    $0 -p macos -a arm64"
    echo "    $0 -p web -a wasm32"
    echo "    $0 -p android -a arm64"
    exit 1
}

PLATFORM=""
ARCH="x86_64"
TARGET="template_debug"
SKIP_SCONS_PATCH=0

while getopts "p:a:t:h" opt; do
    case $opt in
        p) PLATFORM="$OPTARG" ;;
        a) ARCH="$OPTARG" ;;
        t) TARGET="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [ -z "$PLATFORM" ]; then
    usage
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ----- Platform validation and toolchain -----
case "$PLATFORM-$ARCH" in
    linux-x86_64)
        CC="${CC:-gcc}"
        CXX="${CXX:-g++}"
        AR="${AR:-ar}"
        SCPREFIX=""
        LIB_SUFFIX=".so"
        SCONS_PLATFORM="linux"
        SCONS_ARCH="x86_64"
        SCONS_TOOLCHAIN=""
        SECP_CMAKE_EXTRA=""
        ;;
    linux-arm64)
        if command -v aarch64-linux-gnu-gcc &>/dev/null; then
            CC="$(which aarch64-linux-gnu-gcc)"
            CXX="$(which aarch64-linux-gnu-g++)"
            AR="$(which aarch64-linux-gnu-ar)"
            RANLIB="$(which aarch64-linux-gnu-ranlib)"
        elif command -v gcc &>/dev/null && [[ "$(uname -m)" == "aarch64" ]]; then
            CC="$(which gcc)"
            CXX="$(which g++)"
            AR="$(which ar)"
            RANLIB="$(which ranlib)"
        else
            echo "Error: aarch64-linux-gnu-gcc not found. Install: apt install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu"
            exit 1
        fi
        SCPREFIX=""
        LIB_SUFFIX=".so"
        SCONS_PLATFORM="linux"
        SCONS_ARCH="arm64"
        SCONS_TOOLCHAIN=""
        SECP_CMAKE_EXTRA="-DCMAKE_SYSTEM_PROCESSOR=aarch64 -DCMAKE_C_COMPILER=$CC -DCMAKE_CXX_COMPILER=$CXX -DCMAKE_AR=$AR -DCMAKE_RANLIB=$RANLIB"
        ;;
    windows-x86_64)
        if command -v x86_64-w64-mingw32-gcc &>/dev/null; then
            CC="$(which x86_64-w64-mingw32-gcc)"
            CXX="$(which x86_64-w64-mingw32-g++)"
            AR="$(which x86_64-w64-mingw32-ar)"
            RANLIB="$(which x86_64-w64-mingw32-ranlib)"
        else
            echo "Error: x86_64-w64-mingw32-gcc not found. Install: apt install gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64"
            exit 1
        fi
        SCPREFIX=""
        LIB_SUFFIX=".dll"
        SCONS_PLATFORM="windows"
        SCONS_ARCH="x86_64"
        SCONS_TOOLCHAIN=""
        SECP_CMAKE_EXTRA="-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64 -DCMAKE_C_COMPILER=$CC -DCMAKE_CXX_COMPILER=$CXX -DCMAKE_AR=$AR -DCMAKE_RC_COMPILER=$(which x86_64-w64-mingw32-windres)"
        ;;
    macos-x86_64)
        CC="${CC:-clang}"
        CXX="${CXX:-clang++}"
        AR="${AR:-ar}"
        SCPREFIX=""
        LIB_SUFFIX=".dylib"
        SCONS_PLATFORM="macos"
        SCONS_ARCH="x86_64"
        SCONS_TOOLCHAIN=""
        SECP_CMAKE_EXTRA=""
        ;;
    macos-arm64)
        CC="${CC:-clang}"
        CXX="${CXX:-clang++}"
        AR="${AR:-ar}"
        SCPREFIX=""
        LIB_SUFFIX=".dylib"
        SCONS_PLATFORM="macos"
        SCONS_ARCH="arm64"
        SCONS_TOOLCHAIN=""
        SECP_CMAKE_EXTRA="-DCMAKE_SYSTEM_PROCESSOR=aarch64"
        ;;
    web-wasm32)
        if ! command -v emcc &>/dev/null; then
            echo "Error: emcc not found. Install Emscripten SDK: https://emscripten.org/docs/getting_started/downloads.html"
            exit 1
        fi
        CC="$(which emcc)"
        CXX="$(which em++)"
        AR="$(which emar)"
        RANLIB="$(which emranlib)"
        SCPREFIX=""
        LIB_SUFFIX=".wasm"
        SCONS_PLATFORM="web"
        SCONS_ARCH="wasm32"
        SCONS_TOOLCHAIN=""
        SECP_CMAKE_EXTRA="-DCMAKE_SYSTEM_NAME=Emscripten -DCMAKE_SYSTEM_PROCESSOR=wasm32 -DCMAKE_C_COMPILER=$CC -DCMAKE_CXX_COMPILER=$CXX -DCMAKE_AR=$AR -DBUILD_TESTING=OFF -DSECP256K1_ENABLE_MODULE_MUSIG=OFF -DSECP256K1_ENABLE_MODULE_ELLSWIFT=OFF"
        ;;
    android-arm64)
        if [ -z "$ANDROID_NDK_HOME" ] && [ -z "$ANDROID_HOME" ]; then
            echo "Error: ANDROID_NDK_HOME or ANDROID_HOME not set."
            exit 1
        fi
        if [ -z "$ANDROID_HOME" ]; then
            ANDROID_HOME="${ANDROID_NDK_HOME%/ndk/*}"
        fi
        NDK_VER="${ANDROID_NDK_HOME##*/}"
        TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
        CC="$TOOLCHAIN/bin/aarch64-linux-android21-clang"
        CXX="$TOOLCHAIN/bin/aarch64-linux-android21-clang++"
        AR="$TOOLCHAIN/bin/llvm-ar"
        SCPREFIX=""
        LIB_SUFFIX=".so"
        SCONS_PLATFORM="android"
        SCONS_ARCH="arm64"
        SCONS_TOOLCHAIN="ANDROID_HOME=$ANDROID_HOME ndk_version=$NDK_VER"
        SECP_CMAKE_EXTRA="-DCMAKE_SYSTEM_NAME=Android -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DCMAKE_ANDROID_API=21 -DCMAKE_ANDROID_NDK=$ANDROID_NDK_HOME -DCMAKE_C_COMPILER=$CC -DCMAKE_CXX_COMPILER=$CXX -DCMAKE_AR=$AR"
        SKIP_SCONS_PATCH=1
        ;;
    android-x86_64)
        if [ -z "$ANDROID_NDK_HOME" ] && [ -z "$ANDROID_HOME" ]; then
            echo "Error: ANDROID_NDK_HOME or ANDROID_HOME not set."
            exit 1
        fi
        if [ -z "$ANDROID_HOME" ]; then
            ANDROID_HOME="${ANDROID_NDK_HOME%/ndk/*}"
        fi
        NDK_VER="${ANDROID_NDK_HOME##*/}"
        TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
        CC="$TOOLCHAIN/bin/x86_64-linux-android21-clang"
        CXX="$TOOLCHAIN/bin/x86_64-linux-android21-clang++"
        AR="$TOOLCHAIN/bin/llvm-ar"
        SCPREFIX=""
        LIB_SUFFIX=".so"
        SCONS_PLATFORM="android"
        SCONS_ARCH="x86_64"
        SCONS_TOOLCHAIN="ANDROID_HOME=$ANDROID_HOME ndk_version=$NDK_VER"
        SECP_CMAKE_EXTRA="-DCMAKE_SYSTEM_NAME=Android -DCMAKE_SYSTEM_PROCESSOR=x86_64 -DCMAKE_ANDROID_API=21 -DCMAKE_ANDROID_NDK=$ANDROID_NDK_HOME -DCMAKE_C_COMPILER=$CC -DCMAKE_CXX_COMPILER=$CXX -DCMAKE_AR=$AR"
        SKIP_SCONS_PATCH=1
        ;;
    *)
        echo "Unsupported platform-arch combination: $PLATFORM-$ARCH"
        exit 1
        ;;
esac

BUILD_DIR="build/${PLATFORM}_${ARCH}"
OUT_DIR="lib"
OUT_LIB="libnostr_crypto${LIB_SUFFIX}"

echo "=== Building for $PLATFORM ($ARCH) ==="
echo "    CC: $CC"
echo "    Target: $TARGET"

# ----- Build libsecp256k1 -----
echo ""
echo "=== Building libsecp256k1 ==="
cd libsecp256k1
mkdir -p "../build/${PLATFORM}_${ARCH}/secp"
SECP_BUILD_DIR="../build/${PLATFORM}_${ARCH}/secp"
cmake -S . -B "$SECP_BUILD_DIR" \
    -DSECP256K1_ENABLE_MODULE_SCHNORRSIG=ON \
    -DSECP256K1_ENABLE_MODULE_ECDH=ON \
    -DSECP256K1_ENABLE_MODULE_EXTRAKEYS=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DSECP256K1_DISABLE_SHARED=ON \
    -DSECP256K1_BUILD_BENCH=OFF \
    -DSECP256K1_BUILD_TESTS=OFF \
    -DSECP256K1_BUILD_EXHAUSTIVE_TESTS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    $SECP_CMAKE_EXTRA \
    2>&1 | tail -5
cmake --build "$SECP_BUILD_DIR" -j$(nproc) --target secp256k1 2>&1 | tail -5
cd ..

# ----- Build godot-cpp -----
echo ""
echo "=== Building godot-cpp ==="
cd godot-cpp
SCONS_ARGS="platform=$SCONS_PLATFORM arch=$SCONS_ARCH target=$TARGET -j$(nproc)"
if [ -n "$SCONS_TOOLCHAIN" ]; then
    SCONS_ARGS="$SCONS_ARGS $SCONS_TOOLCHAIN"
fi
# godot-cpp SCons resets CC/CXX after Environment(tools=["default"]).
# For cross-compilation, temporarily patch SConstruct to inject compilers.
# Android godot-cpp handles toolchain internally, skip patching.
if [ -n "$CC" ] && [ "$CC" != "gcc" ] && [ "$CC" != "clang" ] && [ "$SKIP_SCONS_PATCH" != "1" ]; then
    cp SConstruct SConstruct.bak
    PATCH_LINE="env.Replace(CC='$CC'); env.Replace(CXX='$CXX'); env.Replace(AR='$AR')"
    if [ -n "$RANLIB" ]; then
        PATCH_LINE="$PATCH_LINE; env.Replace(RANLIB='$RANLIB')"
    fi
    sed -i "19a $PATCH_LINE" SConstruct
    scons $SCONS_ARGS 2>&1 | tail -5
    mv SConstruct.bak SConstruct
else
    scons $SCONS_ARGS 2>&1 | tail -5
fi
cd ..

# ----- Build nostr_crypto -----
echo ""
echo "=== Building nostr_crypto GDExtension ==="
mkdir -p "$BUILD_DIR"

# Determine godot-cpp library suffix
GODOT_CPP_SUFFIX=".${SCONS_PLATFORM}.${TARGET}.${SCONS_ARCH}"
GODOT_CPP_LIB="godot-cpp/bin/libgodot-cpp${GODOT_CPP_SUFFIX}${LIBSUFFIX:-.a}"

# Build secp256k1 static lib
SECP_LIB=$(ls build/${PLATFORM}_${ARCH}/secp/lib/libsecp256k1*.a 2>/dev/null | head -1 || echo "")

if [ -z "$SECP_LIB" ]; then
    SECP_LIB=$(ls build/${PLATFORM}_${ARCH}/secp/src/libsecp256k1*.a 2>/dev/null | head -1 || echo "")
fi

if [ -z "$SECP_LIB" ]; then
    echo "Error: libsecp256k1 static library not found"
    echo "Searched in:"
    echo "  build/${PLATFORM}_${ARCH}/secp/lib/libsecp256k1*.a"
    echo "  build/${PLATFORM}_${ARCH}/secp/src/libsecp256k1*.a"
    find build/${PLATFORM}_${ARCH} -name "*.a" 2>/dev/null | head -5
    exit 1
fi

echo "    secp256k1 lib: $SECP_LIB"

# Check that godot-cpp library exists
if [ ! -f "$GODOT_CPP_LIB" ]; then
    echo "Warning: $GODOT_CPP_LIB not found, trying alt location..."
    GODOT_CPP_LIB=$(ls godot-cpp/bin/libgodot-cpp*.a 2>/dev/null | head -1)
    if [ -z "$GODOT_CPP_LIB" ]; then
        echo "Error: godot-cpp library not found"
        exit 1
    fi
    echo "    Using: $GODOT_CPP_LIB"
else
    echo "    godot-cpp lib: $GODOT_CPP_LIB"
fi

# Compile nostr_crypto.cpp with the correct compiler
CXXFLAGS="-fPIC -std=c++17"
if [ "$PLATFORM" = "windows" ]; then
    CXXFLAGS="$CXXFLAGS -DSECP256K1_STATIC"
fi
$CXX -c $CXXFLAGS \
    -I godot-cpp/include \
    -I godot-cpp/gen/include \
    -I godot-cpp/gdextension \
    -I libsecp256k1/include \
    -I libsecp256k1/src \
    src/nostr_crypto.cpp -o "$BUILD_DIR/nostr_crypto.o"

# Link
case "$PLATFORM" in
    linux|android)
        LINKFLAGS="-shared"
        if [ "$PLATFORM" = "linux" ]; then
            LINKFLAGS="$LINKFLAGS -lpthread"
        fi
        $CXX $LINKFLAGS -o "$BUILD_DIR/$OUT_LIB" \
            "$BUILD_DIR/nostr_crypto.o" \
            "$SECP_LIB" \
            "$GODOT_CPP_LIB"
        ;;
    windows)
        $CXX -shared -o "$BUILD_DIR/$OUT_LIB" \
            "$BUILD_DIR/nostr_crypto.o" \
            "$SECP_LIB" \
            "$GODOT_CPP_LIB" \
            -lws2_32 -lbcrypt -static-libgcc -static-libstdc++
        ;;
    macos)
        $CXX -shared -o "$BUILD_DIR/$OUT_LIB" \
            "$BUILD_DIR/nostr_crypto.o" \
            "$SECP_LIB" \
            "$GODOT_CPP_LIB" \
            -framework CoreFoundation -lobjc
        ;;
    web)
        $CXX -shared -o "$BUILD_DIR/$OUT_LIB" \
            "$BUILD_DIR/nostr_crypto.o" \
            "$SECP_LIB" \
            "$GODOT_CPP_LIB" \
            -sSIDE_MODULE=1 \
            -sWASM_BIGINT
        ;;
esac

# Copy to lib/ directory
mkdir -p "$OUT_DIR"
cp "$BUILD_DIR/$OUT_LIB" "$OUT_DIR/${OUT_LIB}"

# Also copy with platform-arch suffix for organization
SUFFIXED_NAME="libnostr_crypto.${SCONS_PLATFORM}.${TARGET}.${SCONS_ARCH}${LIB_SUFFIX}"
cp "$BUILD_DIR/$OUT_LIB" "$OUT_DIR/$SUFFIXED_NAME"

echo ""
echo "=== Build complete ==="
echo "Library: $OUT_DIR/$SUFFIXED_NAME ($(du -h $OUT_DIR/$SUFFIXED_NAME | cut -f1))"
echo ""
echo "You can now update the .gdextension file and export your project."
