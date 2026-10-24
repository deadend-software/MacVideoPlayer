# DVD playback runtime

VLC / LibVLC 3.0.23, universal arm64 and x86_64 runtime, copied from the VideoLAN distribution installed at /Applications/VLC.app. macvideoplayer embeds this runtime; the installed VLC application is not needed at runtime.

VideoLAN and contributors: https://www.videolan.org/vlc/
Release and corresponding source: https://download.videolan.org/pub/videolan/vlc/3.0.23/
Build and dependency source recipes: https://code.videolan.org/videolan/vlc/-/tree/3.0.23/contrib

LibVLC is LGPL 2.1 or later; VLC modules include GPL 2 or later code. The enclosing macvideoplayer application is GPLv3. Preserve upstream notices and provide corresponding source for the runtime and its dependencies when distributing binaries. The runtime files are unmodified; only embedded copies are signed during the Xcode build. The embedded copy omits the plugin cache (plugins.dat), the Blu-ray Java archives, and the VLC.app window interface and Growl notification modules, none of which this app uses.

DVD playback uses libdvdnav's navigation VM, including authored menus, highlights, still frames, angles, language selection, and title transitions. Other media continues through macvideoplayer's existing playback engines.

## Blu-ray AACS runtime

`lib/libaacs.0.dylib` is libaacs 0.12.0 (LGPL 2.1 or later, https://www.videolan.org/developers/libaacs.html) built as a universal arm64 and x86_64 library with libgcrypt 1.12.4 and libgpg-error 1.61 (both LGPL 2.1 or later, https://gnupg.org/software/) linked in statically. The unmodified source archives are in `aacs-src/`, and `build-aacs.sh` rebuilds the library from them. VLC's libbluray plugin loads it at run time to decrypt AACS-protected Blu-rays. No keys are included: playback needs the user's own `KEYDB.cfg`, installed from File > Install AACS Key Database.

`lib/libbdplus.0.dylib` is libbdplus 0.2.0 (LGPL 2.1 or later, https://www.videolan.org/developers/libbdplus.html), built the same way from the source archive in `aacs-src/` and loaded by libbluray to run BD+ discs' content code. It ships no device keys or conversion tables; those are supplied by the user in `~/Library/Preferences/bdplus`.

DVD CSS decryption is already part of the VLC libdvdnav and libdvdread plugins (libdvdcss, GPL 2 or later).
