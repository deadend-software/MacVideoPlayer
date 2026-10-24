# macvideoplayer

**macvideoplayer** is a native macOS player for video and audio. It opens to a black stage with the macvideoplayer logo and a menu panel that fades away when you do not need it, plays almost any file through macOS and FFmpeg, and lets you reshape the picture with sliders, filters and your own shaders.

- [Description](#description) · [Features](#features) · [What's new](#whats-new-and-bug-fixes) · [Known bugs](#known-bugs-and-issues) · [Minimum requirements](#minimum-requirements) · [Suggested computer power](#suggested-computer-power)
- [Quick start](#quick-start) · [A tour of the window](#a-tour-of-the-window) · [Keyboard shortcuts](#keyboard-shortcuts)
- [Playlists and shuffle](#playlists-and-shuffle) · [DVD, Blu-ray, VCD and SVCD](#dvd-blu-ray-vcd-and-svcd) · [Audio and subtitle tracks](#audio-video-and-subtitle-tracks)
- [Picture tools](#picture-tools): post-processing, shader and filter editor, FPS display, visualizer
- [Configuration builder](#configuration-builder) · [AirPlay](#airplay)
- [Command line](#command-line) · [Configuration reference](#configuration-reference) · [Building from source](#building-from-source) · [Limitations](#limitations-and-honest-notes)

---

## Description

macvideoplayer is a native macOS media player written in Objective-C and AppKit. Files macOS can decode play directly through the system player; everything else is converted on the fly by FFmpeg, so the practical rule is that if FFmpeg can read a file, macvideoplayer can play it. On top of playback it adds a live picture-processing pipeline (sliders, filter chains and Core Image shaders), disc and playlist handling, an audio visualizer, AirPlay and a full command-line interface.

## Features

- **Wide format support:** common video, audio and network streams (HTTP(S), HLS, RTSP, RTMP, UDP), native or through FFmpeg.
- **Queue-based playback:** playlists (`.m3u`, `.m3u8`, `.pls`), recursive folder queues, drag-and-drop, shuffle and repeat.
- **Discs:** DVD, Blu-ray (main feature), VCD, SVCD, ripped folders and disc images.
- **Tracks and subtitles:** audio, video and subtitle track switching, embedded text and picture subtitles, external `.srt`, `.vtt`, `.ass` and `.ssa` files.
- **File-specific AI picture:** colour, contrast, lines and flat areas are shaped from measurements of each file, so different films get different looks.
- **Picture tools:** post-processing sliders and looks, a live shader and filter-chain editor, upscaling, deinterlacing and inverse telecine.
- **Audio tools:** output device selection, sample-rate control, FFmpeg audio filters, stereo-to-5.1 synthesis and a live spectrum visualizer.
- **AirPlay** output.
- **Configuration builder:** an ordered chain of FFmpeg, effect and shader stages saved as JSON.
- **Command line:** play, queue, inspect and configure from a terminal, with full FFmpeg pass-through.
- **Fading HUD:** a menu panel, playback controls and information card that stay out of the way.
- **Instant AI audio effects:** Hi-Fidelity, clarity, bass, dialogue, night mode and the other AI audio options apply to the sound you are hearing within a moment, on local files and on streams, without restarting playback. See [What's new](#whats-new-and-bug-fixes).
- **Now-playing card for music and streams:** with the visualizer showing, the information card stays on screen and lists the title, artist, album, track, genre, year, file name and folder, or, for a stream, its address and the station name, genre and description.
- **Click-to-show controls:** the on-screen controls appear when you click the picture, not when the pointer moves, enters or leaves the window.

## What's new and bug fixes

### New

- **A stronger, file-specific AI picture.** *Adaptive AI (Analyze This File)* now measures each file's colours (a 12-sector hue histogram), contrast, grain, line sharpness, flat-colour area and compression, then builds that file's own look from it: a 3D colour look-up table (S-curve contrast, colour pop that favours muted colours, extra saturation for the accent hues that file actually contains while a hue that fills the picture is held back and skin-tone orange is protected), firmed-up outlines (hardest on animation's ink lines, light on live action), wide local contrast for depth and form, and smoothing of flat colour areas and compression noise. A cartoon such as *Rurouni Kenshin* and a grainy live-action Blu-ray such as an Elvis concert film therefore get visibly different treatments. Sharpening, clarity and vibrance are also stronger than before, and the *Vivid & Crisp*, *Cinema HDR*, *Anime Pop*, *Super Resolution* and *Clean Restore* presets were all made more pronounced. This costs GPU and memory (a 1.7 MB colour table, several full-frame filter passes); in a headless test a 720p frame took about 2 ms on an Apple M5.
- **Instant audio effects.** Changing an AI audio option no longer restarts the stream. The player keeps the decoded audio that has not been heard yet, rebuilds its filter chain and re-renders that audio, so the change is heard at once and the audio clock (and picture sync) is not disturbed.
- **High-rate music output.** Audio-only media opens its output at 96 kHz when the device supports it, so Hi-Fidelity and the other effects can be switched on and off without reopening the audio device. Video, and any sample rate you choose yourself, are left alone.
- **Metadata card beside the visualizer.** The card no longer fades after 8 seconds while the visualizer is showing; it lists every tag the file or stream carries, plus the file name and folder or the stream address.
- **Controls on click.** Single-click the picture to show the controls (they hide again after about 2 seconds); double-click still toggles full screen.

### Fixed

- **Streaming music stopped, beeped or buffered for up to 30 seconds when an audio effect was changed.** The change restarted playback; for a live stream that reconnected, tried to seek to a position a live stream does not have, and could fall back to converting the whole stream with FFmpeg. Changes are now applied live.
- **Buffer stuck at a few percent with a steady tone after enabling Hi-Fidelity.** Dropping the buffered audio starved network streams (they only deliver sound as fast as it plays), and Apple's mastering-grade sample-rate converter could run slower than real time. Streams now keep their buffer, start on a lighter converter setting, and any source switches to it if conversion falls behind.
- **Audio-only media decoded far ahead and then lost audio.** Without video there was nothing to pace the reader, so the decoder filled the audio buffer (about 80 seconds at 96 kHz stereo) and silently dropped what it decoded next. Reading now pauses once about 8 seconds are buffered.
- **Controls popped up whenever the pointer moved, entered or left the window.**

## Known bugs and issues

These are current, known problems. See [Limitations](#limitations-and-honest-notes) for the longer list.

- Converted playback (media macOS cannot play natively) can take a long time to start if FFmpeg lacks VideoToolbox H.264 encoding or HLS output, because the whole file is converted first.
- Seeking far ahead in converted media restarts conversion, causing a pause.
- The visualizer shows only an idle animation, not a real spectrum, for media that is converted ahead of playback. Music and streams played by the built-in FFmpeg player show a real spectrum.
- Audio effects were exercised against a live 32 kHz MP3 stream and local test media only; the sound itself was checked by logging buffer level and clock sync, not by ear, and not on every output device (Bluetooth, HDMI, AirPlay).
- The AI picture stages were verified on generated test images (the output differs visibly between a cartoon-like and a film-like profile and runs in a few milliseconds per 720p frame); they have not been judged on real films, and the strength of the new look is a matter of taste. Motion is not analysed or interpolated: the AI stages work on each frame separately.
- Hi-Fidelity at the 96 kHz default uses noticeably more CPU than plain playback; on a stream it falls back to a lighter converter.
- DVD menu items cannot be clicked directly (the disc engine takes no mouse input); the disc bar and arrow keys drive them. Blu-ray menus can be clicked.
- Copy-protected discs are only partly supported (see [Encrypted discs](#encrypted-dvds-and-blu-rays)): UHD (AACS 2) discs do not play, Blu-ray decryption needs your own `KEYDB.cfg` (and BD+ discs your own BD+ data), and none of this has been tested against a real commercial disc. Java (BD-J) Blu-ray menus are not run. HDMV Blu-ray menus show a still or looping background with their buttons; button animations, sounds and pop-up menus are not played.
- The FFplay backend opens its own window, so macvideoplayer's controls, effects and visualizer do not apply to it.
- `screenshot`, `export` and `trim` are unfinished, and `pause`, `seek` and `stop` cannot control a running player from another process.
- AirPlay, FFplay playback and high-sample-rate or 5.1 hardware output have not been tested against real devices.
- `audioSampleRate` changes the system output device and is not restored when playback stops.

## Minimum requirements

| | Requirement |
| --- | --- |
| **Operating system** | macOS 12.4 (Monterey) or later. Building from source needs a current Xcode. |
| **Processor** | Apple silicon (M1 or later) or an Intel Mac with a 64-bit x86_64 processor. The app and its embedded libraries (FFmpeg, VLC runtime, libaacs, libbdplus) are universal builds. |
| **Memory** | 4 GB for audio; 8 GB for video and disc playback. Music playback keeps up to about 20 seconds of decoded audio in memory so effects can be applied instantly (a few MB). |
| **Graphics** | Any Mac with Metal support. Hardware H.264/HEVC decoding (VideoToolbox) is strongly recommended for 1080p and 4K. |
| **Storage** | About 250 MB for the app (it embeds the FFmpeg and VLC runtimes). Disc images and converted playback need extra free space. |
| **Audio output** | Any Core Audio output. A device that accepts 96 kHz gets the high-rate music path; others are served at their own rate with no loss of features. |
| **Network** | Only for streams: a connection that sustains the stream's bit rate (a 96 kb/s radio stream needs about 0.2 Mb/s including overhead). Streams are buffered for about 3 seconds before they start. |
| **Optical drive** | Only for playing physical discs: any DVD or Blu-ray drive macOS recognises (an external USB drive on a Mac without one). Ripped folders and `.iso` images need no drive. |

## Suggested computer power

These are rough guidelines, not measured benchmarks. Playback that macOS decodes natively uses hardware decoding and is light; the heavier figures apply when FFmpeg converts media or when filters and upscaling run.

| Task | Suggested Mac |
| --- | --- |
| Music, podcasts and the visualizer | Any Mac that runs macOS 12.4 or later; 4 GB RAM |
| Music or streams with Hi-Fidelity and several AI audio effects at 96 kHz | Any Apple silicon Mac, or an Intel Mac from about 2017; 8 GB RAM |
| 1080p video, natively supported formats | Any Apple silicon Mac, or an Intel Mac from about 2015; 8 GB RAM |
| 4K video, natively supported formats | Apple silicon (M1 or later) or an Intel Mac with hardware HEVC decoding; 8 GB RAM |
| Converted playback (MKV, AVI, DVD, Blu-ray) at 1080p | Apple silicon, or a recent quad-core Intel Mac; 8 GB RAM; FFmpeg with VideoToolbox |
| Converted 4K or high-bitrate Blu-ray streams | Apple silicon M1 Pro or better, with 16 GB RAM and fast SSD storage |
| Post-processing sliders, effects and custom shaders | A Mac with a capable GPU; Apple silicon recommended for 4K |
| Upscaling (2× to 4×) and deinterlacing | Apple silicon M1 Pro or better; Metal upscaling needs a GPU, `lanczos` upscaling and deinterlacing use the CPU |
| Several filters combined with 4K converted playback | Apple silicon M2 Pro or better, 16 GB RAM or more |

---

## Quick start

1. Open `macvideoplayer.xcodeproj` in Xcode, choose the **macvideoplayer** scheme and press Run. (macOS 12.4 or later.)
2. The window opens black with the macvideoplayer logo and the **menu panel** on the left.
3. Click **Open File…**, drop a file onto the window, or double-click a file in the panel's browser.
4. Move the mouse to show the controls. They fade four seconds after the pointer stops.

Install [FFmpeg](https://ffmpeg.org) (for example `brew install ffmpeg`) to unlock everything beyond what macOS plays natively: AVI, MKV with unusual codecs, DVDs, Blu-ray streams, subtitle extraction and track details. macvideoplayer finds `ffmpeg` and `ffprobe` in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin` and your `PATH`.

From a terminal:

```sh
macvideoplayer movie.mkv                       # play a file
macvideoplayer ~/Music --shuffle               # queue a whole folder in random order
macvideoplayer disc /Volumes/MY_DVD            # play a disc
macvideoplayer help                            # every command and option
```

The executable lives at `Mac Video Player.app/Contents/MacOS/Mac Video Player`; add it to your `PATH` or create an alias to use these commands.

---

## A tour of the window

| Part | What it does |
| --- | --- |
| **Black stage with the macvideoplayer logo** | Shown at launch and after Stop. The logo is replaced by the video as soon as playback starts. Set `backgroundImage` in the configuration to use your own picture. |
| **Menu panel (the HUD)** | Every feature as a button: open a file, URL, folder or disc; playlist and shuffle; tracks and subtitles; AirPlay; visualizer; FPS display; post-processing; shader editor; configuration builder; settings; help. It appears at launch, fades after a few seconds, returns whenever you move the mouse while nothing is playing, when you touch the left edge during playback, or when you press **Tab**. A built-in file browser sits underneath; the disc and folder buttons in its header jump to your volumes or play the current folder. |
| **Playback controls** | Previous, play/pause, next, stop, position, time, volume, shuffle, repeat, tracks and subtitles, playlist, full screen and the menu. They fade four seconds after the mouse enters, moves in or leaves the window. |
| **AirPlay overlay** | The AirPlay button floats in the top-right corner and follows the same four-second fade. |
| **Information card** | When playback starts, a card in the top-left shows the title, artist or album, duration, video and audio formats, subtitle count, container and bitrate, then fades away after about eight seconds. Press **I** to show it again. |
| **Subtitles** | Drawn at the bottom of the picture, above the controls. |
| **FPS pill** | Optional. Shows the frames per second the player is actually delivering, next to the file's own rate (`FPS 23.9 / 23.98`). |
| **Right-click** | A quick menu with the most-used actions. |

The menu bar mirrors everything: **File**, **Playback**, **Audio**, **Video**, **Subtitles**, **Window** and **Help**. The *Audio Track*, *Video Track* and *Subtitles* menus fill in from the file that is playing.

---

## Keyboard shortcuts

| Key | Action | Key | Action |
| --- | --- | --- | --- |
| Space | Play / pause | N / P | Next / previous item |
| Tab | Show or hide the menu panel | S | Shuffle on / off |
| ← / → | Seek 5 seconds | R | Repeat off / all / one |
| ↑ / ↓ | Volume | M | Mute |
| F | Full screen | I | Show media information |
| V | Visualizer over video | D | FPS display |
| `[` / `]` | Slower / faster | Esc | Hide the menu panel |
| ⌘O | Open file | ⇧⌘O | Open folder or playlist |
| ⌘U | Open URL | ⌥⌘O | Open disc |
| ⌘L | Playlist | ⌘B | Configuration builder |
| ⌘, | Settings | ⌘. | Stop |

Letter keys only act on the player window, so typing in the editors never triggers them. Double-click the picture for full screen.

---

## Playlists and shuffle

macvideoplayer always plays from a queue. Opening one file creates a queue of one; opening several files, a folder, or a playlist file fills the queue.

- **In the window:** *Open File…* accepts several files; *Open Folder…* queues folders (searched recursively) and `.m3u`, `.m3u8` and `.pls` playlists; dropping any mix of files, folders and discs onto the window does the same.
- **Playlist panel** (⌘L): drag rows to reorder, drop more files in, remove, clear, save as `.m3u`, load a playlist, tick **Shuffle** and choose **Repeat** (off, whole list, one item). Double-click an item to play it.
- **Shuffle** plays every item once in random order, starting from the current one, then reshuffles on repeat. It never jumps tracks when you turn it on or off.
- **Next / previous** follow shuffle and repeat. *Previous* restarts the current item when you are more than four seconds in.
- **Command line:**

```sh
macvideoplayer play a.mkv b.mp3 ~/Music/Album --shuffle        # files and folders, shuffled
macvideoplayer play --playlist evening.m3u --repeat all        # playlist file, repeating
macvideoplayer playlist show ~/Music --shuffle                 # preview what would play
macvideoplayer playlist create out.m3u ~/Music --shuffle       # write a (shuffled) M3U playlist
```

Shuffle, repeat, FPS and visualizer choices are remembered in `~/Library/Application Support/macvideoplayer/config.json`.

---

## DVD, Blu-ray, VCD and SVCD

Choose **Open Disc…** (⌥⌘O), click the disc button in the browser header, drop a disc onto the window, or run `macvideoplayer disc`. macvideoplayer accepts:

| Source | What plays |
| --- | --- |
| Mounted disc in `/Volumes`, or a ripped folder that contains `VIDEO_TS` | **DVD**: the title set with the most data (normally the main feature), joined into one program |
| Folder containing `BDMV` | **Blu-ray**: discs with HDMV menus open on their own menu (buttons work with the mouse, arrow keys, Return and number keys; ⌥⌘M returns to it). Discs without a readable HDMV menu play their largest stream (normally the main feature) |
| Folder containing `MPEGAV` or `VCD` | **VCD**: every track becomes a playlist item |
| Folder containing `MPEG2` or `SVCD` | **SVCD**: every track becomes a playlist item |
| `.iso`, `.img`, `.toast`, `.cdr`, `.dmg`, `.udf` image | Mounted read-only, then treated as above |

```sh
macvideoplayer disc                       # first disc that is mounted
macvideoplayer disc-list                  # what is mounted, and its type
macvideoplayer disc ~/Rips/MyMovie.iso
```

Discs are converted on the fly with FFmpeg: playback starts within a couple of seconds while conversion continues ahead of the playhead, so you can seek (a distant seek restarts conversion from that point). Interlaced DVD video is deinterlaced automatically. Post-processing, shaders, subtitles and the FPS display all work on disc playback.

**Disc bar.** As soon as a DVD or Blu-ray loads, a bar appears at the top of the window: **Menu**, **▶ Play** (the main feature), **Titles ▾**, **Chapters ▾**, previous/next chapter, the four arrow buttons and **Select**. It stays up while a menu is showing and otherwise fades with the playback controls. Every part of it is clickable.

- **Blu-ray menus** are drawn by macvideoplayer from the disc's own menu data, so you can click a menu entry directly (for example *Play Movie*) and it plays.
- **DVD menus** are drawn by the disc engine, which cannot receive mouse clicks. Use the bar instead: *Play*, *Titles*, *Chapters*, or the arrow and *Select* buttons (the arrow keys and Return work too).

### Encrypted DVDs and Blu-rays

DVDs and Blu-rays play through an embedded VLC 3.0.23 runtime (`Vendor/VLC`), which also decrypts protected discs:

- **DVD (CSS):** libdvdcss is built into the runtime's libdvdnav and libdvdread plugins, so CSS-encrypted DVDs need nothing extra.
- **Blu-ray (AACS 1.x):** libbluray decrypts through libaacs 0.12.0 (built with libgcrypt and libgpg-error into a universal `Vendor/VLC/lib/libaacs.0.dylib`; `Vendor/VLC/build-aacs.sh` rebuilds it and libbdplus from the sources in `Vendor/VLC/aacs-src`). **No keys are included.** Choose **File → Install AACS Key Database (KEYDB.cfg)…** and select your own `KEYDB.cfg`; it is copied to `~/Library/Preferences/aacs/KEYDB.cfg`. Without a key entry for the disc, playback fails with a message saying so. AACS-protected Blu-ray folders and `.iso` images go through this engine.
- **Physical drives:** reading keys from a disc in a drive needs raw device access, which the App Sandbox does not allow, so the app is built **without the sandbox** (it keeps the Hardened Runtime, with library validation disabled so the embedded, locally signed libraries load). A build like this cannot be submitted to the Mac App Store.
- **Blu-ray (BD+):** libbdplus 0.2.0 is embedded the same way (`Vendor/VLC/lib/libbdplus.0.dylib`) and loaded by libbluray, so BD+ discs run their protection code. It needs device data that is not bundled; **File → Install BD+ Keys (aes_keys.bin, slots.bin)…** copies your own files to where libbdplus reads them: `aes_keys.bin` to `~/Library/Preferences/bdplus/vm0/` and `slots.bin` to `~/Library/Caches/bdplus/` (libbdplus rewrites `slots.bin` as discs run). **Show BD+ Data Folder** opens the first folder. BD+ discs also need a working AACS setup (above). BD+ support is untested.
- **Not supported:** UHD Blu-ray (AACS 2.x) and Blu-ray Java (BD-J) menus.

This has built and launched, but has not been tested against a real encrypted disc. Decrypting discs may be restricted by law where you live (for example DMCA §1201 in the US); use it only for discs you own, where that is permitted. Home-made, unprotected and ripped discs always work.

---

## Audio, video and subtitle tracks

Use the speech-bubble button, the panel's **Tracks & Subtitles**, or the *Audio*, *Video* and *Subtitles* menus. Track names include language, codec and channel layout, read with `ffprobe`.

- **Audio tracks** switch instantly for files macOS plays natively; otherwise playback restarts at the same position with the chosen track.
- **Video tracks** (alternate angles or streams) restart playback at the same position.
- **Subtitles:** text subtitles inside the file (SRT, ASS, WebVTT, `mov_text`) are extracted and drawn by macvideoplayer. Picture-based subtitles (DVD and Blu-ray) are drawn onto the video by FFmpeg, which restarts playback at the same position. **Load Subtitle File…** adds an external `.srt`, `.vtt`, `.ass` or `.ssa`. A file named like the video (`Movie.srt` beside `Movie.mkv`) loads automatically.
- `macvideoplayer tracks FILE` lists every track from the terminal.

---

## Picture tools

### Post-processing

*Panel → Post-Processing…* (⌥⌘P). Sliders for brightness, contrast, saturation, hue, gamma, exposure, warmth, sharpness, noise reduction, blur and vignette, an invert switch, and one-click looks (Cinema, Vivid, Noir, Warm Sunset, Cool Night, Clean & Sharp, Soft Dream). Changes apply live, even while paused, and are remembered. From the command line:

```sh
macvideoplayer play movie.mkv --post "saturation=1.3,contrast=1.1,sharpness=0.5"
```

### Shader and filter editor

*Panel → Shader Editor* (⌥⌘E) has a live preview that uses the frame that is playing now, or a test pattern when nothing is.

- **Shader**: a Core Image color kernel. The preview updates as you type, with compile errors shown below the editor. Insert a template (invert, grayscale, sepia, posterize, threshold, teal & orange, scanlines) to start.
- **Filter chain**: stack and reorder built-in filters such as `sepia:0.6`, `noir`, `bloom:1`, `comic`, `zoomblur:10`. Select a row to change its amount. `macvideoplayer effect-list` shows all of them.
- **Apply to Player** puts both on the playing video immediately. **Save Preset…** stores them as JSON; **Save Shader…** writes a `.cikernel` file you can use with `--shader`.

```c
kernel vec4 effect(__sample pixel) {
    return vec4(pixel.a - pixel.rgb, pixel.a);     // invert
}
```

Kernels use Apple's older Core Image kernel language: one `__sample` argument, a `vec4` result. Multi-pass shaders, Metal shaders and custom uniforms are not supported.

### FPS display

Turn it on from the panel, the Video menu (⌥⌘D) or `D`. `macvideoplayer play movie.mkv --fps` starts with it on.

### Audio visualizer

Audio-only files and streams (music, podcasts, radio) always show a live spectrum, taken from the actual audio, and the information card stays up beside it with the title, artist, album, file name or stream details. Press `V` (or *Audio → Visualizer over Video*) to also show it along the bottom of a video; *Next Visualizer Style* cycles bars, mirror and ring. Spectrum analysis works on files macOS plays directly. For media macvideoplayer converts (discs, unusual formats), the visualizer shows a gentle idle animation instead.

---

## Configuration builder

Open it with ⌘B, the panel's **Config Builder**, or from a terminal:

```sh
macvideoplayer configure                               # empty builder
macvideoplayer configure my-setup.json                 # load a saved setup
macvideoplayer configure --input ~/Movies/film.mkv     # start with media chosen
```

In one window you can pick the media (a file, URL, folder, playlist or disc), choose the playback backend, and build an **ordered chain of stages** that mixes:

| Stage type | What it is | Example |
| --- | --- | --- |
| `video` | FFmpeg video filter | `eq=contrast=1.1,unsharp=5:5:0.8` |
| `audio` | FFmpeg audio filter | `loudnorm`, `aresample=48000` |
| `effect` | Built-in Core Image effect | `sepia:0.6` |
| `shader` | Core Image kernel file | `~/shaders/glow.cikernel` |

FFmpeg video stages run first, then effects and shaders in order; audio stages form their own chain. Reorder, remove, load shaders or write one, set volume, loop and shuffle, then **Save Config…**, **Apply** or **Launch Media**. The builder also opens the shader editor and post-processing windows. When a chain needs FFmpeg, macvideoplayer converts the media on the fly and plays the result.

---

## AirPlay

Start playback, then click the AirPlay button in the top-right overlay (or **AirPlay** in the panel). The overlay appears whenever the pointer enters, moves in or leaves the window and fades four seconds later; it stays while the device list is open. AirPlay works with media macOS plays directly and with converted media.

---

## Supported media

macvideoplayer hands everything macOS can decode to the system player, and sends the rest through FFmpeg, so the practical rule is: **if FFmpeg can read it, macvideoplayer can play it.** That covers essentially all common video (MP4, MOV, MKV, WebM, AVI, WMV/ASF, FLV, MPEG-PS/TS, VOB, M2TS, OGV, 3GP, RealMedia, MXF and more), audio (MP3, AAC, M4A, FLAC, ALAC, WAV, AIFF, Ogg/Opus, WMA, APE, WavPack, AC-3/E-AC-3, DTS, MKA, CAF and more) and network streams (HTTP(S), HLS, RTSP, RTMP, UDP). The file chooser accepts every file. Without FFmpeg installed, playback is limited to what macOS itself supports.

---

## Command line

```text
macvideoplayer                                  open the player
macvideoplayer FILE|FOLDER|URL... [OPTIONS]     play (same as `macvideoplayer play`)
macvideoplayer play INPUT... [OPTIONS]          play files, folders, playlists, discs or URLs
macvideoplayer disc [PATH]   macvideoplayer disc-list    play a disc / list mounted discs
macvideoplayer playlist create OUT.m3u INPUT... [--shuffle]
macvideoplayer playlist show INPUT... [--shuffle]
macvideoplayer configure [JSON] [--input FILE]  configuration builder
macvideoplayer tracks FILE   macvideoplayer info FILE    list tracks / print metadata as JSON
macvideoplayer effect-list                      built-in effects
macvideoplayer device-list   macvideoplayer device-set UID
macvideoplayer config-save FILE
macvideoplayer ffmpeg ARGS...   macvideoplayer ffmpeg-play ARGS...   forward to ffmpeg / ffplay
```

| Option | Meaning |
| --- | --- |
| `--shuffle`, `--repeat off\|all\|one`, `--playlist FILE` | Queue behavior |
| `--fps`, `--visualizer`, `--visualizer-style bars\|mirror\|ring`, `--no-metadata` | Display options |
| `--post "brightness=0.1,contrast=1.2"` | Post-processing (brightness contrast saturation hue gamma exposure warmth sharpness noiseReduction blur vignette) |
| `--effect NAME[:AMOUNT]`, `--shader FILE` | Core Image effect / kernel |
| `--vf GRAPH`, `--af GRAPH` | FFmpeg video / audio filter graphs (converted playback) |
| `--audio-layout auto\|stereo\|5.1` | Force stereo or synthesize 5.1 |
| `--backend auto\|native\|prepared\|ffplay` | Choose how media is played |
| `--config-load FILE` | Load a JSON configuration; flags override it |
| `--loop`, `--mute`, `--volume 0..1`, `--rate N`, `--audio UID` | Basics |
| `--audio-sample-rate auto\|max\|HZ`, `--upscale 1..4`, `--scaler metal\|lanczos` | Quality |
| `--deinterlace`, `--inverse-telecine`, `--field-order auto\|tff\|bff` | Interlaced and telecined sources |
| `--ffmpeg`, `--ffplay-arg TOKEN` | Use an external FFplay window |

Backends: **auto** plays natively and falls back to FFmpeg conversion; **native** never converts; **prepared** always converts; **ffplay** uses FFplay's own window (requires `ffplay`).

---

## Audio quality and processing

The sample-rate, deinterlacing, inverse-telecine and upscaling options are unchanged from earlier versions; see `examples/quality-metal.json`, `examples/quality-interlaced.json` and `examples/surround.json`.

- `audioSampleRate`: `auto` leaves the output device alone, `max` asks Core Audio for its highest nominal rate, or give Hz as a string. This changes the **system** output device and is not restored when playback stops.
- `deinterlace` (BWDIF) or `inverseTelecine` (field match, deinterlace, decimate): choose one. They need the FFmpeg path.
- `upscale` 1–4× with `scaler` `metal` (Lanczos on the GPU, native playback, 8192-pixel limit) or `lanczos` (FFmpeg CPU scaling). This is interpolation, not AI super-resolution.
- `audioLayout` `5.1` synthesizes surround from stereo; it does not recover discrete channels.

## Full FFmpeg access

```sh
macvideoplayer ffmpeg -i input.mov -c:v libx264 -crf 20 -c:a aac -b:a 192k output.mp4
macvideoplayer ffmpeg -ss 10 -i input.mp4 -frames:v 1 frame.png
macvideoplayer ffmpeg-play -vf hflip input.mp4
```

Arguments are forwarded unchanged and the exit status returned. In *Settings*, `ffmpegArguments` runs the same kind of job from the GUI: one array element per argument, no shell quoting, and include the input and output paths (use `-nostdin` and `-n` or `-y`).

---

## Configuration reference

Defaults load from `~/Library/Application Support/macvideoplayer/config.json`; `--config-load` and the builder use the same format. Unknown keys are preserved.

| Key | Type / default | Purpose |
| --- | --- | --- |
| `volume`, `rate` | number / 1 | Volume 0–1, playback speed |
| `loop`, `mute`, `ffmpeg` | boolean / false | Repeat the current item, mute, use FFplay |
| `shuffle` | boolean / false | Play the queue in random order |
| `repeat` | `off` \| `all` \| `one` | Queue repeat |
| `showFPS`, `visualizer` | boolean / false | FPS pill; visualizer over video |
| `visualizerStyle` | `bars` \| `mirror` \| `ring` | Visualizer look |
| `showMetadata` | boolean / true | Information card at the start |
| `postProcessing` | object | Slider values, `enabled`, `filterChain`, `shaderSource` |
| `playlist` | array of strings | Items to queue when macvideoplayer starts with no inputs |
| `backgroundImage` | string | Picture shown on the empty stage instead of the logo |
| `playbackBackend` | `auto` \| `native` \| `prepared` \| `ffplay` | How media is played |
| `effect`, `shader` | string | Native effect / kernel path |
| `effectChain` | array of `{type, value}` | Ordered stages (see the builder) |
| `vf`, `af` | string | FFmpeg filter graphs |
| `ffplayArguments`, `ffmpegArguments` | array of strings | Raw FFplay / FFmpeg arguments |
| `audioDevice`, `audioLayout`, `audioSampleRate` | string | Audio output options |
| `deinterlace`, `inverseTelecine`, `fieldOrder`, `upscale`, `scaler` | see above | Video quality options |

---

## Building from source

Open `macvideoplayer.xcodeproj`, scheme **macvideoplayer**. The *Embed DVD Runtime* build phase copies and signs the VLC runtime (including libaacs) into the app; with no development team the project signs ad hoc, which is why library validation is disabled (`RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION`). To rebuild libaacs, run `Vendor/VLC/build-aacs.sh` (needs the Xcode command line tools; it builds from the bundled sources and needs no download). The project uses `FFMPEG_ROOT = /usr/local` only for optional FFmpeg headers (`VPFFmpeg.h`); the app itself runs FFmpeg as a subprocess.

`tools/make_assets.swift` regenerates the app icon (`macvideoplayer/AppIcon.icns`) and the logo shown on the empty stage (`macvideoplayer/macvideoplayer-splash.png`):

```sh
swift tools/make_assets.swift
```

---

## Limitations and honest notes

- **Copy protection:** CSS DVDs and AACS 1.x Blu-rays can be decrypted (only with your own `KEYDB.cfg`), and BD+ is wired up but needs user-supplied data; UHD (AACS 2.x) discs are not supported. Untested on real encrypted discs. Blu-ray HDMV menus are interpreted (first page, buttons and their commands); Java (BD-J) menus and DVD-style angle menus are not, and such discs play their largest stream.
- **Converted playback** (anything macOS cannot play natively) needs FFmpeg with VideoToolbox H.264 encoding and HLS output; without them macvideoplayer converts the whole file before playing, which can take a long time for movies. Seeking far ahead in converted media restarts conversion.
- **Visualizer:** real spectrum only for natively played media; converted media shows an idle animation.
- **Shaders** use Apple's deprecated Core Image kernel language and can only transform one pixel at a time.
- **FFplay backend:** opens its own window; macvideoplayer's controls, effects and visualizer do not apply, and `ffplay` must be installed (it is not part of every FFmpeg build).
- **Seeking from the command line:** `pause`, `seek`, `stop` and similar commands report that they need a running player; there is no remote control between processes. `screenshot`, `export` and `trim` remain unfinished; use `macvideoplayer ffmpeg` for those jobs.
- **AirPlay** was not exercised against real receivers in development, and FFplay playback and physical high-sample-rate or 5.1 output are unverified.
- Verified during development: the project builds; the empty stage, menu panel and chrome skin render; converted playback starts within seconds with effects applied; post-processing, the FPS display, the information card, DVD folders (synthetic), folder queues with shuffle, audio visualizer, and the shader editor's live preview were exercised with generated test media.
