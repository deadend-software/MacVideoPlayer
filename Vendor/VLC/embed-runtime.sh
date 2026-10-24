#!/bin/bash
# Embeds the VLC runtime (libvlc, libvlccore and the plugins) in the app so DVDs play
# through libdvdnav with their authored menus. Runs as the "Embed DVD Runtime" build phase.
set -euo pipefail
runtime_source="$SRCROOT/Vendor/VLC"
runtime_destination="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/VLC"
legal_destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/VLC-Legal"
# Declared as this phase's output in the project, so Xcode re-signs the app whenever it changes.
manifest="$legal_destination/runtime-manifest.txt"
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"

# The App Store upload reports "Upload Symbols Failed" for every embedded Mach-O whose UUID has no
# dSYM in the archive. The VLC libraries are stripped, so dsymutil produces symbol-less dSYM bundles,
# but they carry the matching UUIDs, which is what the upload checks. Only done when Xcode
# produces dSYMs (archive builds).
make_dsyms() {
    [ "${DEBUG_INFORMATION_FORMAT:-}" = "dwarf-with-dsym" ] && [ -n "${DWARF_DSYM_FOLDER_PATH:-}" ] || return 0
    mkdir -p "$DWARF_DSYM_FOLDER_PATH"
    for library in "$runtime_destination"/lib/*.dylib "$runtime_destination"/plugins/*.dylib; do
        [ -L "$library" ] && continue
        bundle="$DWARF_DSYM_FOLDER_PATH/$(basename "$library").dSYM"
        [ -d "$bundle" ] && continue
        /usr/bin/dsymutil "$library" -o "$bundle" 2>/dev/null
    done
}

mkdir -p "$legal_destination"
cp "$runtime_source/NOTICE.md" "$runtime_source/COPYING.txt" "$legal_destination/"

# The manifest describes the vendor runtime (every file with size and modification time), this
# script, and the signing identity. Signing changes the embedded copies, so they can't be compared
# with the originals directly; instead the embedded runtime is rebuilt only when the manifest changes.
new_manifest=$(
    printf 'embed-runtime.sh %s\nidentity %s\n' "$(/usr/bin/stat -f '%z %m' "$0")" "$identity"
    cd "$runtime_source"
    find lib plugins \( -type f -o -type l \) | LC_ALL=C sort | while IFS= read -r entry; do
        /usr/bin/stat -f '%N %z %m' "$entry"
    done
)
if [ -d "$runtime_destination/plugins" ] && [ -f "$manifest" ] && [ "$(cat "$manifest")" = "$new_manifest" ]; then
    make_dsyms
    exit 0
fi

mkdir -p "$runtime_destination"
/usr/bin/rsync -a --delete "$runtime_source/lib/" "$runtime_destination/lib/"
/usr/bin/rsync -a --delete "$runtime_source/plugins/" "$runtime_destination/plugins/"

# Everything under Contents/Frameworks is sealed as nested code, so files that are
# not Mach-O (the plugins.dat cache and the Blu-ray Java jars) make the final
# app signature fail with "code object is not signed at all". libvlc runs with
# --no-plugins-cache and BD-J is not used, so neither is needed at runtime.
find "$runtime_destination/lib" "$runtime_destination/plugins" -type f ! -name '*.dylib' -delete
# VLC.app's own window interface and Growl notifications modules link Sparkle and Growl,
# which are not embedded here, so they can never load. The video output this app uses is
# libvout_macosx_plugin.dylib, which stays.
rm -f "$runtime_destination/plugins/libmacosx_plugin.dylib" "$runtime_destination/plugins/libosx_notifications_plugin.dylib"

# Hardened runtime library validation only loads code signed by the app's own team,
# so the embedded copies are signed with the app's identity.
for library in "$runtime_destination"/lib/*.dylib "$runtime_destination"/plugins/*.dylib; do
    [ -L "$library" ] && continue
    /usr/bin/codesign --force --sign "$identity" --timestamp=none "$library"
done

make_dsyms
printf '%s\n' "$new_manifest" > "$manifest"
