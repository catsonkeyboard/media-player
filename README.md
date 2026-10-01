# media_player

A cross-platform video player for **Windows / macOS / Linux / Android / iOS**, built with Flutter + [media_kit](https://pub.dev/packages/media_kit) (libmpv / FFmpeg backend).

One codebase, one playback core, consistent behavior on all five platforms.

## Highlights

- **Plays virtually everything**: MP4 / MKV / AVI / MOV / FLV / WMV / WebM / TS containers; H.264 / H.265 / VP9 / AV1 and more — powered by libmpv with hardware decoding (VideoToolbox / MediaCodec / D3D11VA / VA-API) and automatic software-decode fallback.
- **Library**: recent plays with resume positions, folder-based video library grid, and WebDAV remote sources.
- **Binge-ready**: natural-order playlist autoplay (EP1 → EP2 → EP10), skip intro/outro markers, chapter navigation.
- **Deep playback controls**: audio tracks, 10-band equalizer, subtitles (embedded + external + auto-matching), A-B loop, frame stepping, speed control.
- **Platform integration**: system media control (macOS Now Playing), file association, drag & drop, keyboard shortcuts, mobile gestures, picture-in-picture.

## Features

### Playback core
- Local files and network streams: http(s) direct links, HLS (m3u8), RTSP, RTMP, SRT, FTP
- Hardware decoding toggle (auto-fallback to software decoding), deinterlace toggle, HDR tone-mapping toggle
- Playback speed 0.25x ~ 3x
- Resume playback (auto-resume between 5 s ~ 95 % of duration; progress saved every 5 s and on exit)
- Chapters (mkv chapter-list) with a jump panel
- A-B loop (`A` cycles: set A → loop → clear), frame step (`,` / `.`)
- Skip intro/outro: mark per-file timestamps; intros auto-skip, outros auto-advance to the next episode
- Screenshot current frame (`S`) saved as PNG to Pictures
- Playback info overlay (`I`): video format, fps, bitrate, hwdec status, drops, buffer

### Library
- **Recent**: search by title/path, filter by local/network, per-item progress bars
- **Video library**: add frequently-used folders (persisted), recursive scan, natural-sorted poster grid; tapping any video plays the whole folder as a playlist
- **WebDAV**: manage multiple servers (Alist / Synology / QNAP / Nutstore compatible), browse directories, play with credentials (Basic auth), current directory becomes the autoplay list
- Open via: file picker, folder picker, network URL dialog (clipboard paste + scheme validation), drag & drop (desktop), file association (macOS)

### Playlist
- Four modes: sequence / loop list / repeat one / shuffle
- Playlist panel with position indicator (`2/12`), jump-to-item, prev/next buttons (also in desktop control bar and via `N` / `P`)

### Subtitles
- Embedded track switching, external subtitle loading (srt / ass / ssa / vtt)
- Auto-load same-name subtitles from the video's directory (`EP01.mp4` → `EP01.srt` or `EP01.zh.srt`)
- Font size (4 presets), subtitle delay sync (±0.5 s steps, reset)

### Audio
- Multi-track switching
- 10-band equalizer (-12 ~ +12 dB) with 7 presets (Pop / Rock / Classical / Jazz / Vocal / Electronic) and custom mode

### Video / picture
- Aspect ratio (default / 16:9 / 4:3 / 2.35:1 / 1:1)
- Crop presets (none / half / quarter, vertical or horizontal)
- Rotation (0 / 90 / 180 / 270°)
- Picture adjustments: brightness / contrast / saturation / gamma / hue (auto-reset on episode switch)
- Persisted settings: hwdec, deinterlace, HDR mapping, EQ, speed — restored on next launch

### Platform integration
- **Keyboard (desktop)**: Space play/pause, ←/→ seek ±10 s, ↑/↓ volume, F fullscreen, S screenshot, N/P prev/next, A A-B, I info, `,`/`.` frame step, Esc back (exits fullscreen first)
- **Mobile gestures**: left half vertical drag = brightness (app-level, restored on exit), right half = volume, long-press = 2x speed
- **macOS**: Now Playing info + remote commands (play/pause/seek/next/prev via media keys), file association, graceful libmpv shutdown on quit (prevents exit crash)
- **Windows**: graceful shutdown handshake (same pattern, WM_CLOSE interception)
- **Picture-in-picture**: Android 8.0+ system PiP; macOS/Windows mini always-on-top window (draggable, restores original bounds on exit); iOS not supported (system PiP requires AVPlayer rendering)
- Window position/size memory (suspended during mini-window mode)

## Getting started

```bash
flutter pub get

# Desktop
flutter run -d linux
flutter run -d macos
flutter run -d windows

# Mobile
flutter run -d <android-device-id>
flutter run -d <ios-device-id>
```

The first build downloads prebuilt libmpv binaries per platform (Linux instead links the system `libmpv` from `libmpv-dev`).

### Linux build & launch

One script builds the release bundle and packages a distributable archive (requires Flutter stable with Dart ≥ 3.13):

```bash
./scripts/build-linux.sh              # build release + package dist/media-player-<version>-linux-<arch>.tar.gz
./scripts/build-linux.sh --with-deps  # also install the system toolchain first (Debian/Ubuntu/Mint, needs sudo)
```

Artifacts:

- `build/linux/<arch>/release/bundle/` — runnable directory on the build machine
- `dist/media-player-<version>-linux-<arch>.tar.gz` — archive to copy to other machines

Launch:

```bash
# Dev machine, straight from the build output
./build/linux/x64/release/bundle/media_player

# Target machine, from the distributed archive
tar xzf media-player-0.1.0-linux-x64.tar.gz
./media-player-0.1.0-linux-x64/media_player
```

Dependencies: build needs `clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev`; the binary links the **system** `libmpv2` at runtime (not bundled) — on the target machine run `sudo apt install libmpv2`.

### Debug entry

```bash
# Launch straight into the player with one or more videos (| -separated for playlist autoplay)
MEDIA_PLAYER_TEST_VIDEO="/path/to/a.mp4|/path/to/b.mp4" flutter run -d macos
```

### Tests & analysis

```bash
flutter analyze
flutter test          # 33 tests: playlist, WebDAV, natural sort, models, skip markers
```

## Platform notes

| Platform | Notes |
| --- | --- |
| macOS | App Sandbox disabled for direct distribution (VLC-like path access). Restore `com.apple.security.app-sandbox` before App Store release — security-scoped bookmarks take over automatically. `user-selected.read-only` entitlement is kept (file_picker 13 requires the declaration). |
| Windows | libmpv DLLs bundled automatically; graceful-exit C++ changes need a Windows machine (or CI) to compile-verify. |
| Linux | GTK desktop build; build and package with `scripts/build-linux.sh` (see the “Linux build & launch” section). Links system `libmpv2` at runtime — not bundled in the archive. |
| Android | `INTERNET` permission declared for release; manifest has `supportsPictureInPicture`. |
| iOS | Large file picking copies into a temp directory on first open (system behavior). PiP unsupported (see above). |

Before release: change `applicationId` / bundle identifiers from template defaults — see [docs/RELEASE.md](docs/RELEASE.md).

## Project structure

```
lib/
├── main.dart                        # Entry: service bootstrap, test-video hook
├── models/
│   ├── media_item.dart              # Media record (path/title/progress/bookmark)
│   └── chapter_info.dart
├── services/
│   ├── library_service.dart         # Recent plays + progress persistence
│   ├── media_library_service.dart   # Folder scanning video library
│   ├── webdav_service.dart          # WebDAV client (PROPFIND) + server store
│   ├── playlist_service.dart        # Queue + 4 play modes
│   ├── player_settings.dart         # mpv property setters + persisted settings
│   ├── skip_markers_service.dart    # Intro/outro markers
│   ├── security_scoped.dart         # macOS sandbox bookmarks (dormant)
│   ├── now_playing_service.dart     # macOS system media control
│   ├── pip_service.dart             # PiP entry points
│   ├── window_service.dart          # Window bounds memory
│   ├── native_bridge.dart           # app/native MethodChannel hub
│   └── app_shutdown.dart            # Pre-exit cleanup registry
├── pages/
│   ├── home_page.dart               # 3 tabs: recent / library / network
│   ├── player_page.dart             # Player + shortcuts + overlays
│   ├── player_sheets.dart           # Bottom sheets (tracks/EQ/picture/playlist/chapters)
│   ├── desktop_controls.dart        # Custom minimal desktop control bar
│   └── mobile_gestures.dart         # Mobile gesture layer
└── utils/natural_sort.dart          # EP2 < EP10 ordering
```

- Full design doc (framework/core selection, architecture, risks): [docs/technical-design.md](docs/technical-design.md)
- Release checklist per platform: [docs/RELEASE.md](docs/RELEASE.md)

## Roadmap

- v0.5: DLNA / SMB sources, seek-bar thumbnail preview, OpenSubtitles download (requires API key)
- v1.0: store release engineering (signing, notarization, MSIX, AAB) per [docs/RELEASE.md](docs/RELEASE.md)

## License notes

media_kit ships prebuilt libmpv (LGPL configuration); closed-source distribution is permitted, but keep third-party license attribution in an About page before public release.
