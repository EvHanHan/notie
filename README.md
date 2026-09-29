# Notie

A tiny macOS menu bar app for fast idea capture into a Markdown file, Apple Notes, or Apple Reminders.

## Download

The easiest way to share Notie on GitHub is through Releases.

1. Open the latest GitHub Release.
2. Download `Notie-<version>-macos-universal.dmg`.
3. Open the disk image.
4. Drag `Notie.app` into `Applications`.
5. Launch Notie from `Applications`.

## Build From Source

Notie builds with Apple Command Line Tools and Rust, so full Xcode is not required. The Rust helper builds `transcribe-cpp` and its native C++ backend locally.

1. Install Apple Command Line Tools with `xcode-select --install`.
2. Install CMake, for example with `brew install cmake`.
3. Install Rust with [rustup](https://rustup.rs), then add both app targets with `rustup target add aarch64-apple-darwin x86_64-apple-darwin`.
4. Build the app with:

```sh
./scripts/build.sh
```

5. Launch the built app with:

```sh
open build/Notie.app
```

You can also double-click `open-notie.command`, which builds and launches the app for you.

If a Rust build ends with `cmake-0.1.58` and `-mcpu=native`, update the repository and rerun `./scripts/build.sh`; the build script disables native CPU tuning so both Apple Silicon and Intel targets can be compiled.

## Package For GitHub

Create a local DMG with:

```sh
./scripts/package.sh
```

This writes a universal macOS DMG to `dist/`.

For a trusted release build, provide these environment variables before running the script:

- `SIGNING_IDENTITY`: your `Developer ID Application` certificate name
- `NOTARY_KEYCHAIN_PROFILE`: a `notarytool` keychain profile name created with Apple credentials

If those variables are omitted, the script still builds a DMG for local testing, but it will not be signed or notarized.

The repo also includes a GitHub Actions workflow in [release.yml](/Users/han.han@dataiku.com/Desktop/Personal/Clicky/notie/.github/workflows/release.yml) that:

- builds the app on macOS
- imports your `Developer ID Application` certificate from GitHub Secrets
- notarizes and staples the DMG with Apple
- uploads the DMG as a workflow artifact
- attaches the DMG to a GitHub Release when you push a tag like `v1.0.0`

Set these GitHub Actions secrets before shipping releases:

- `APPLE_CERTIFICATE_P12_BASE64`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_DEVELOPER_IDENTITY`
- `APPLE_API_ISSUER_ID`
- `APPLE_API_KEY_ID`
- `APPLE_API_PRIVATE_KEY_BASE64`
- `KEYCHAIN_PASSWORD`

## Use

1. Open `build/Notie.app` after building locally, or install the packaged release app from the DMG if you downloaded one from GitHub Releases.
2. Click the `✎` menu bar icon and choose **Choose Markdown File…**.
3. Press `⌘K` or click the `✎` menu bar icon and choose **New Note**.
4. Choose **Write to File**, **Apple Notes**, or **Apple Reminders** in the note window.
5. Type your note, paste a screenshot, or drag an image into the note window.
6. Press `⌘↩` or click **Save**.

Each saved note is appended to the selected file as a new Markdown bullet point.
Images are copied into a sibling `*-assets` folder and linked from the bullet.
Apple Notes entries are created through macOS automation and can include pasted or dragged images.
Apple Reminders entries are created in your default Reminders list after you grant Reminders access; pasted or dragged images are ignored because reminder items do not support them.

Before recording, choose **Recordings Folder: None** from the menu bar dropdown and select where Notie should save recordings. Choose **Record** to capture system audio and microphone audio together. Choose **Record Screen** to capture your primary display (including the cursor), system audio, and microphone audio into one `screen-recording.mp4` file. When you stop, Notie mixes both audio sources into the MP4 and removes its temporary capture files; the session retains `meta.json`. You can transcribe that MP4 later with **Transcribe Audio or Video File…**. Choose **Stop Recording** or **Stop Screen Recording** when finished; Notie saves the session folder in a `recordings` folder inside the selected recordings folder. This setting is independent from the default Markdown file. macOS may ask for Microphone, Screen & System Audio Recording, and Screen Recording permission the first time you use these features. Recording requires macOS 14.2 or newer.

Choose **Transcribe Audio or Video File…** to transcribe an existing file without creating a recording. Notie accepts common audio formats macOS can decode, including M4A, MP3, WAV, AIFF, and CAF, plus common video containers including MP4, M4V, MOV, AVI, MKV, WebM, MPEG, and 3GP when macOS can decode their audio track. For video files, Notie extracts and transcribes the audio only; it does not analyze video frames. It never changes the selected file: it writes `<name>.transcript.md` and `<name>.transcript.json` beside it instead. If those names already exist, Notie creates matching numbered files such as `<name>.transcript-2.md` and `<name>.transcript-2.json`.

Transcription is started only when you choose **Transcribe Audio or Video File…** and runs entirely on-device using `transcribe-cpp` with the English-only Parakeet TDT 0.6B v2 Q4_K_M model. The first transcription downloads approximately 475 MB and caches it under `~/Library/Application Support/Notie/Models`; later transcriptions reuse the cached model and can work offline. Imported files are rendered as `audio`. If transcription fails, the original file remains available and the error is shown in Notie’s transcription log. Recording sessions are never transcribed automatically.
