# DVD playback runtime

VLC / LibVLC 3.0.23, universal arm64 and x86_64 runtime, copied from the VideoLAN distribution installed at /Applications/VLC.app. vplay embeds this runtime; the installed VLC application is not needed at runtime.

VideoLAN and contributors: https://www.videolan.org/vlc/
Release and corresponding source: https://download.videolan.org/pub/videolan/vlc/3.0.23/
Build and dependency source recipes: https://code.videolan.org/videolan/vlc/-/tree/3.0.23/contrib

LibVLC is LGPL 2.1 or later; VLC modules include GPL 2 or later code. The enclosing vplay application is GPLv3. Preserve upstream notices and provide corresponding source for the runtime and its dependencies when distributing binaries. The runtime files are unmodified; only embedded copies are signed during the Xcode build. The embedded copy omits the plugin cache (plugins.dat), the Blu-ray Java archives, and the VLC.app window interface and Growl notification modules, none of which this app uses.

DVD playback uses libdvdnav's navigation VM, including authored menus, highlights, still frames, angles, language selection, and title transitions. Other media continues through vplay's existing playback engines.
