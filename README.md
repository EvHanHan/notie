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

Before recording, choose **Recordings Folder: None** from the menu bar dropdown and select where Notie should save recordings. Choose **Record** to capture system audio and microphone audio together. While recording, choose **Take Screenshot** from the menu bar or press **⌘⇧S** to save a PNG screenshot of your primary display in that meeting’s timestamped session folder, alongside `mic.wav`, `system.wav`, `meta.json`, `transcript.json`, and `transcript.md`; a brief white flash confirms that the screenshot was saved. The menu option and shortcut are inactive whenever Notie is not recording. Choose **Stop Recording** when finished; Notie saves the session folder in a `recordings` folder inside the selected recordings folder. This setting is independent from the default Markdown file. macOS may ask for Microphone, System Audio Recording, and Screen Recording permission the first time you use these features. Recording requires macOS 14.2 or newer.

Transcription runs automatically and entirely on-device using `transcribe-cpp` with the English-only Parakeet TDT 0.6B v2 Q4_K_M model. The first transcription downloads approximately 475 MB and caches it under `~/Library/Application Support/Notie/Models`; later transcriptions reuse the cached model and can work offline. Mic and system audio are transcribed independently and rendered as `me` and `them` segments in chronological order. If transcription fails, the audio remains available and the error is appended to `transcribe.log`. Pending sessions are retried when Notie launches again.
