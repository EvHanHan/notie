# Notie

A tiny macOS menu bar app for fast idea capture into a Markdown file.

## Download

The easiest way to share Notie on GitHub is through Releases.

1. Open the latest GitHub Release.
2. Download `Notie-<version>-macos-universal.zip`.
3. Unzip it and move `Notie.app` wherever you want.
4. On first launch, macOS may warn that the app is unsigned. Right-click the app and choose **Open**.

## Build From Source

Notie builds with Apple Command Line Tools, so full Xcode is not required.

1. Install the tools once with `xcode-select --install`.
2. Build the app with:

```sh
./scripts/build.sh
```

3. Launch the built app with:

```sh
open build/Notie.app
```

You can also double-click `open-notie.command`, which builds and launches the app for you.

## Package For GitHub

Create a shareable release zip locally with:

```sh
./scripts/package.sh
```

This writes a universal macOS zip to `dist/`, ready to upload to GitHub Releases.

The repo also includes a GitHub Actions workflow in [release.yml](/Users/han.han@dataiku.com/Desktop/Personal/Clicky/notie/.github/workflows/release.yml) that:

- builds the app on macOS
- uploads the zip as a workflow artifact
- attaches the zip to a GitHub Release when you push a tag like `v1.0.0`

## Use

1. Open `build/Notie.app` after building locally, or open the packaged release app if you downloaded one from GitHub Releases.
2. Click the `✎` menu bar icon and choose **Choose Markdown File…**.
3. Press `⌘K` or click the `✎` menu bar icon and choose **New Note**.
4. Type your note, paste a screenshot, or drag an image into the note window.
5. Press `⌘↩` or click **Append to Markdown**.

Each saved note is appended to the selected file as a new Markdown bullet point.
Images are copied into a sibling `*-assets` folder and linked from the bullet.
