# Live TV (Android TV)

A native, lightweight Live TV and DTH player tailored for Android TV and Google TV sets. Built with Flutter and ExoPlayer Media3, it streams 1,100+ public Indian and international channels with public EPG metadata, multi-audio language switching, and classic DTH Set-Top-Box controls.

| | |
|---|---|
| ![Live TV Channel Browser with 1,100+ channels and categories](../../docs/live-tv-home.png) | ![DTH-Style 4-Hour Timeline Program Guide (EPG) with live PIP video](../../docs/live-tv-epg.png) |
| *1,100+ Live Channels categorized with Voice Search & Language Filter* | *Classic 4-Hour Timeline EPG with Program Synopsis & PIP Video* |
| <img src="../../docs/live-tv-player.png" alt="Full-screen HD live broadcast playback" width="400"> | <img src="../../docs/live-tv-epg.png" alt="DTH Timeline Guide with program synopsis" width="400"> |
| *Full HD Live Playback with Multi-Audio & Fit Controls* | *DTH Program Guide with instant D-pad Genre Switching* |

---

## Features

### 1. Channel Browser & Discovery
- **Categories in a Sidebar**: All, News, Entertainment, Movies, Music, Sports, Kids, Infotainment, Business, Devotional, Other, with channel counts.
- **Language Filtering**: Instant filtering by language (Hindi, English, Tamil, Telugu, Kannada, Malayalam, Bengali, Marathi, Punjabi, Gujarati, etc.).
- **Voice Search & Text Search**: Dedicated search dialog with Android TV microphone speech recognition.
- **Favorites & Recent History**: One-click star bookmarking and automatic history of recently watched channels.

### 2. DTH Timeline EPG (Electronic Program Guide)
- **4-Hour Grid**: Matches Tata Play / Airtel Digital TV STB interfaces. Shows live time slots (e.g. 8:00 pm, 8:30 pm), program titles, and duration bars.
- **Full D-Pad Remote Navigation**:
  - In the Timeline Guide, press **Up (⬆️)** from the top channel row to jump into the Category Pill.
  - Cycle genres directly with **Left / Right (⬅️/➡️)**.
  - Press **OK** or the **Menu (☰)** key to open a centered **Category Picker Modal Dialog** listing all categories with counts.
  - Fast-scroll large channel lists with **Channel Up/Down (Page Up/Down)**.
- **Background PIP Video**: Video continues playing smoothly in the background while browsing the guide.
- **Program Synopsis & Reminders**: Press OK on any upcoming show to view synopsis and set an on-screen alert reminder.

### 3. Media3 ExoPlayer & Multi-Audio
- **Multi-Audio Track Selection**: Channels broadcasting multiple language feeds (*English, Hindi, Spanish, Tamil, German, Japanese, etc.*) automatically display an amber **Audio (🔊)** option in the controls bar.
- **Hardware Acceleration**: ExoPlayer Media3 hardware-accelerated playback with HEVC, H.264, and AAC decoding.
- **18-Second Live Buffer Safety Window**: Automatically establishes a jitter safety window behind the live edge to eliminate frequent re-buffering on home Wi-Fi networks.
- **Auto-Fallback & Reconnect**: If a primary stream errors or fails DRM verification, the player automatically falls back to backup streams without interrupting the user.

### 4. TV Remote Ergonomics
- **Aspect Ratio & Screen Fit**: Cycle between Fit, Fill, Zoom, and 16:9 stretch with one click.
- **Last Channel Recall**: Quick button to flip back to the previously watched channel.
- **Smooth 60 fps Performance on 1 GB RAM TVs**: Pre-rendered offstage category grids, disk-cached logos, and zero frame-dropping animation loops.

---

## Build & Install

Ensure JDK 17 and Android SDK are available in your environment:

```bash
cd apps/live-tv
JAVA_HOME=/path/to/jdk-17 ANDROID_HOME=/path/to/android-sdk flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

For 32-bit vs 64-bit targets:
```bash
flutter build apk --release --target-platform android-arm --android-skip-build-dependency-validation
flutter build apk --release --target-platform android-arm64 --android-skip-build-dependency-validation
```
