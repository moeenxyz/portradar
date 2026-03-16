# PortRadar

PortRadar is a lightweight macOS menubar app for inspecting local listening TCP ports and acting on the owning process or service.

It is designed to stay simple:
- native Swift/AppKit
- refresh every 30 seconds
- fast local inspection via `lsof`, `ps`, and `launchctl`
- no background daemons, servers, or web stack

## Features

- shows local listening TCP ports
- shows process name
- resolves app name when possible
- falls back to launchd service labels for managed daemons
- falls back to project folder names for plain CLI dev servers
- `Force Close` for regular processes
- `Stop Service` for launchd-managed services
- `Launch at Login` toggle for the built app bundle

## Requirements

- macOS 13+
- Xcode / Swift toolchain with `swift build`

## Development

Run directly from source:

```bash
swift run
```

This is useful for development, but login-item support is intended for the built `.app` bundle.

## Build

Build the standalone app bundle:

```bash
./scripts/build-app.sh
```

That produces:

```bash
dist/PortRadar.app
```

Open it with:

```bash
open "dist/PortRadar.app"
```

## Download

If you do not want to build from source, you can download a prebuilt app bundle from the release assets for the current version tag.

- source users: build locally with `./scripts/build-app.sh`
- download users: grab the packaged build from the `v1` release assets when published

## How the build works

`./scripts/build-app.sh` does the following:

1. builds the Swift package in release mode
2. creates a native macOS `.app` bundle in `dist/`
3. converts [`icon.svg`](./icon.svg) into `AppIcon.icns`
4. writes the bundle metadata into `Info.plist`

## Project Structure

- [`Sources/PortRadar/PortRadar.swift`](./Sources/PortRadar/PortRadar.swift): app logic
- [`scripts/build-app.sh`](./scripts/build-app.sh): bundle build script
- [`scripts/make-icon.swift`](./scripts/make-icon.swift): icon generation helper
- [`icon.svg`](./icon.svg): source icon

## Open Source

PortRadar is open source under the MIT License. See [LICENSE](./LICENSE).

## Contributing

Contributions are welcome.

If you want to improve PortRadar:

1. fork the repo
2. create a branch for your change
3. build and test locally
4. open a pull request with a clear description

Good contribution areas:

- process and app-name detection
- service-management improvements
- menu layout polish
- macOS compatibility fixes
- documentation

See [CONTRIBUTING.md](./CONTRIBUTING.md).

## Versioning

The current source snapshot is intended to be tagged as `v1`. See [CHANGELOG.md](./CHANGELOG.md).
