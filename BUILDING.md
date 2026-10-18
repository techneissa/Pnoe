# Building Pnoe

## Requirements

- macOS 15.0 or later
- Xcode with Command Line Tools
- Git

## Local Build

```bash
git clone https://github.com/techneissa/Pnoe.git
cd Pnoe
make local
open ~/Downloads/Pnoe.app
```

`make local` prepares `whisper.xcframework` in `~/Pnoe-Dependencies`, builds Release in `.local-build`, and copies `Pnoe.app` to `~/Downloads`.

It uses `LocalBuild.xcconfig`, `Pnoe.local.entitlements`, and the `LOCAL_BUILD` Swift flag. Without an override, it uses the only available Apple Development identity or falls back to ad-hoc signing when none or multiple are found.

Choose an identity explicitly:

```bash
make local LOCAL_CODESIGN_IDENTITY="<SHA or name>"
```

Force ad-hoc signing:

```bash
make local LOCAL_CODESIGN_IDENTITY=-
```

Local builds do not include iCloud dictionary sync. Ad-hoc builds may require macOS permissions again after rebuilding.

## Other Commands

- `make check` — verify required tools
- `make whisper` — prepare `whisper.xcframework`
- `make build` — build the standard Debug configuration
- `make dev` — build and launch `Pnoe Dev.app`
- `make run` — launch `~/Downloads/Pnoe.app`, or the first app found in DerivedData
- `make clean` — remove `~/Pnoe-Dependencies`
- `make help` — list all commands

## Build with Xcode

```bash
make setup
open Pnoe.xcodeproj
```

Select the `Pnoe` scheme. Run builds `Pnoe Dev.app`; Archive uses Release. `LOCAL_BUILD` applies only through `make local`.

## Troubleshooting

- Run `make check` to verify the required tools.
- Run `make whisper` if the framework is missing.
- If several Apple Development identities exist, set `LOCAL_CODESIGN_IDENTITY` explicitly.
- For additional help, open a [GitHub issue](https://github.com/techneissa/Pnoe/issues).
