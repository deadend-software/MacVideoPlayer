#!/bin/bash
# Rebuilds the Blu-ray decryption runtime from the bundled, unmodified sources as universal arm64 + x86_64
# dylibs, each with libgcrypt and libgpg-error linked in: Vendor/VLC/lib/libaacs.0.dylib (AACS) and
# Vendor/VLC/lib/libbdplus.0.dylib (BD+). libbluray (inside VLC's libbluray plugin) loads them at runtime.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
sources="$here/aacs-src"
output="$here/lib"
build_root="$(mktemp -d "${TMPDIR:-/tmp}/macvideoplayer-aacs-build.XXXXXX")"
trap 'rm -rf "$build_root"' EXIT
jobs="${AACS_BUILD_JOBS:-8}"

for archive in libgpg-error-1.61 libgcrypt-1.12.4 libaacs-0.12.0 libbdplus-0.2.0; do
    tar -xf "$sources/$archive.tar.bz2" -C "$build_root"
done

for architecture in arm64 x86_64; do
    prefix="$build_root/install-$architecture"
    host="$architecture-apple-darwin"
    [ "$architecture" = arm64 ] && host=aarch64-apple-darwin
    export CC="clang -arch $architecture"
    export CFLAGS="-O2 -fPIC -mmacosx-version-min=12.4"
    export LDFLAGS="-mmacosx-version-min=12.4"
    mkdir -p "$prefix"

    mkdir "$build_root/gpg-error-$architecture"
    (cd "$build_root/gpg-error-$architecture" &&
        "$build_root/libgpg-error-1.61/configure" --host="$host" --prefix="$prefix" \
            --disable-shared --enable-static --disable-doc --disable-tests --disable-nls --disable-languages &&
        make -j"$jobs" && make install)

    mkdir "$build_root/gcrypt-$architecture"
    (cd "$build_root/gcrypt-$architecture" &&
        "$build_root/libgcrypt-1.12.4/configure" --host="$host" --prefix="$prefix" \
            --disable-shared --enable-static --disable-doc --disable-tests --disable-asm \
            --with-libgpg-error-prefix="$prefix" &&
        make -j"$jobs" && make install)

    mkdir "$build_root/aacs-$architecture"
    (cd "$build_root/aacs-$architecture" &&
        PATH="$prefix/bin:$PATH" "$build_root/libaacs-0.12.0/configure" --host="$host" --prefix="$prefix" \
            --enable-shared --disable-static --disable-dependency-tracking \
            --with-libgcrypt-prefix="$prefix" --with-gpg-error-prefix="$prefix" \
            LIBGCRYPT_CFLAGS="-I$prefix/include" LIBGCRYPT_LIBS="-L$prefix/lib -lgcrypt -lgpg-error" \
            GPG_ERROR_CFLAGS="-I$prefix/include" GPG_ERROR_LIBS="-L$prefix/lib -lgpg-error" &&
        make -j"$jobs" && make install)

    mkdir "$build_root/bdplus-$architecture"
    (cd "$build_root/bdplus-$architecture" &&
        PATH="$prefix/bin:$PATH" "$build_root/libbdplus-0.2.0/configure" --host="$host" --prefix="$prefix" \
            --enable-shared --disable-static --disable-dependency-tracking \
            --with-libgcrypt-prefix="$prefix" --with-gpg-error-prefix="$prefix" \
            LIBGCRYPT_CFLAGS="-I$prefix/include" LIBGCRYPT_LIBS="-L$prefix/lib -lgcrypt -lgpg-error" \
            GPG_ERROR_CFLAGS="-I$prefix/include" GPG_ERROR_LIBS="-L$prefix/lib -lgpg-error" &&
        make -j"$jobs" && make install)
    unset CC CFLAGS LDFLAGS
done

mkdir -p "$output"
lipo -create "$build_root/install-arm64/lib/libaacs.0.dylib" "$build_root/install-x86_64/lib/libaacs.0.dylib" \
    -output "$output/libaacs.0.dylib"
install_name_tool -id @rpath/libaacs.0.dylib "$output/libaacs.0.dylib"
ln -sf libaacs.0.dylib "$output/libaacs.dylib"
lipo -create "$build_root/install-arm64/lib/libbdplus.0.dylib" "$build_root/install-x86_64/lib/libbdplus.0.dylib" \
    -output "$output/libbdplus.0.dylib"
install_name_tool -id @rpath/libbdplus.0.dylib "$output/libbdplus.0.dylib"
ln -sf libbdplus.0.dylib "$output/libbdplus.dylib"
otool -L "$output/libaacs.0.dylib" "$output/libbdplus.0.dylib"
