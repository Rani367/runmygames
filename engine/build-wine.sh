#!/bin/bash
# Builds CodeWeavers' CrossOver Wine (LGPL source release) as a self-contained,
# relocatable x86_64 engine with WoW64 (32-bit apps via the 64-bit loader).
#
#   engine/build-wine.sh            # build + install into $ENGINE_DIR
#   JOBS=6 engine/build-wine.sh
source "$(dirname "$0")/common.sh"

JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
SRC="$RMG_CACHE/sources"
BUILD="$RMG_CACHE/build/$ENGINE_NAME"
STAGE="$RMG_CACHE/stage/$ENGINE_NAME"
BREW="$(brew --prefix)"

[[ -f "$X86LIBS/libgnutls.30.dylib" ]] || die "run engine/deps.sh first"
command -v x86_64-w64-mingw32-gcc >/dev/null || die "mingw-w64 missing; run engine/deps.sh"

# ---------------------------------------------------------------- source
TARBALL="$RMG_CACHE/crossover-sources-$CX_VERSION.tar.gz"
download "$CX_URL" "$TARBALL" "$CX_SHA256"
if [[ ! -f "$SRC/.rmg-$CX_VERSION" ]]; then
    log "Unpacking CrossOver $CX_VERSION sources"
    rm -rf "$SRC"; mkdir -p "$RMG_CACHE/unpack"
    tar -xzf "$TARBALL" -C "$RMG_CACHE/unpack"
    mv "$RMG_CACHE/unpack/sources" "$SRC"; rmdir "$RMG_CACHE/unpack"
    for p in "$RMG_REPO"/engine/patches/*.patch; do
        log "Applying $(basename "$p")"
        patch -d "$SRC/wine" -p1 --forward < "$p"
    done
    touch "$SRC/.rmg-$CX_VERSION"
fi

# ---------------------------------------------------------------- configure
BISON="$(brew --prefix bison)/bin"; FLEX="$(brew --prefix flex)/bin"
export PATH="$BISON:$FLEX:$PATH"
# Headers come from arm64 Homebrew (architecture-neutral); x86_64 dylibs from $X86LIBS.
export PKG_CONFIG=/usr/bin/false
export FREETYPE_CFLAGS="-I$BREW/opt/freetype/include/freetype2" FREETYPE_LIBS="-L$X86LIBS -lfreetype"
export GNUTLS_CFLAGS="-I$BREW/opt/gnutls/include -I$BREW/opt/nettle/include -I$BREW/opt/libtasn1/include -I$BREW/opt/p11-kit/include/p11-kit-1" GNUTLS_LIBS="-L$X86LIBS -lgnutls"
export SDL2_CFLAGS="-I$BREW/opt/sdl2-compat/include/SDL2 -D_THREAD_SAFE" SDL2_LIBS="-L$X86LIBS -lSDL2"
export CC="ccache clang -arch x86_64" CXX="ccache clang++ -arch x86_64"
MVK="$RMG_CACHE/moltenvk"
[[ -f "$MVK/dynamic/dylib/macOS/libMoltenVK.dylib" ]] || die "MoltenVK missing; run engine/deps.sh"
export CPPFLAGS="-I$MVK/include" LDFLAGS="-L$MVK/dynamic/dylib/macOS"
export CFLAGS="-O2 -Wno-error=incompatible-function-pointer-types -Wno-error=int-conversion -Wno-deprecated-declarations"
export CROSSCFLAGS="-O2"
export MACOSX_DEPLOYMENT_TARGET=14.0
# Leaf sonames: the engine bundles these dylibs in its own lib/ and finds them
# through DYLD_FALLBACK_LIBRARY_PATH, instead of absolute paths into this build box.
export ac_cv_lib_soname_freetype=libfreetype.6.dylib
export ac_cv_lib_soname_gnutls=libgnutls.30.dylib
export ac_cv_lib_soname_SDL2=libSDL2-2.0.0.dylib
export ac_cv_lib_soname_vulkan=
export ac_cv_lib_soname_MoltenVK=libMoltenVK.dylib

mkdir -p "$BUILD"
# Build-time tools (sfnt2fon) link the prebuilt libs by leaf name, which dyld resolves
# relative to the working directory: make them visible in the build root.
ln -sf "$X86LIBS/"*.dylib "$BUILD/"
if [[ ! -f "$BUILD/Makefile" ]]; then
    log "Configuring (x86_64 + i386 WoW64)"
    (cd "$BUILD" && arch -x86_64 "$SRC/wine/configure" \
        --prefix="$STAGE" \
        --enable-archs=i386,x86_64 \
        --disable-tests \
        --without-x --without-alsa --without-capi --without-dbus --without-oss \
        --without-pulse --without-udev --without-usb --without-v4l2 --without-wayland \
        --without-gstreamer --without-krb5 --without-gssapi --without-netapi \
        --with-mingw --with-freetype --with-gnutls --with-sdl --with-vulkan \
        --with-coreaudio --with-opencl --with-cups --with-pcap=no) \
        | tee "$BUILD/configure.log" | tail -30
fi

# ---------------------------------------------------------------- build
log "Compiling with $JOBS jobs (first build ~20-30 min on Apple Silicon)"
(cd "$BUILD" && arch -x86_64 make -j"$JOBS" >"$BUILD/make.log" 2>&1) \
    || { tail -40 "$BUILD/make.log"; die "build failed, see $BUILD/make.log"; }
rm -rf "$STAGE"
(cd "$BUILD" && arch -x86_64 make install-lib >"$BUILD/install.log" 2>&1) \
    || { tail -40 "$BUILD/install.log"; die "install failed"; }

# ---------------------------------------------------------------- bundle dylibs
# Wine dlopen()s these by leaf name via DYLD_FALLBACK_LIBRARY_PATH=<engine>/lib; the
# prebuilt set already links its own dependencies @loader_path-relative.
log "Bundling x86_64 libraries"
LIBDIR="$STAGE/lib"
cp -a "$X86LIBS/"*.dylib "$LIBDIR/"
cp "$MVK/dynamic/dylib/macOS/libMoltenVK.dylib" "$LIBDIR/"
find "$LIBDIR" -maxdepth 1 -name '*.dylib' -type f -exec codesign -f -s - {} \; 2>/dev/null

# ---------------------------------------------------------------- install
log "Installing engine -> $ENGINE_DIR"
rm -rf "$ENGINE_DIR"; mkdir -p "$(dirname "$ENGINE_DIR")"
cp -R "$STAGE" "$ENGINE_DIR"
echo "$CX_VERSION" > "$ENGINE_DIR/RMG_ENGINE_VERSION"
"$RMG_REPO/engine/wrap-engine.sh"
WINEDEBUG=-all DYLD_FALLBACK_LIBRARY_PATH="$ENGINE_DIR/lib" "$ENGINE_DIR/bin/wine" --version
log "Engine ready."
