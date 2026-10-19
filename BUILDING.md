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
- `make build` — build the Debug configuration, signed with the project's Apple team
- `make dev` — `make build`, then launch `Pnoe Dev.app`
- `make run` — launch `~/Downloads/Pnoe.app`, or the first app found in DerivedData
- `make clean` — remove `~/Pnoe-Dependencies`
- `make help` — list all commands

## Signing with the project team

`make build`, `make dev` and Debug builds in Xcode sign with the project's development team (`6CTUQH4ST8`, a free Personal Team) and `Pnoe.debug.entitlements`. A free team cannot sign iCloud/CloudKit entitlements, so these builds do not use `Pnoe.entitlements`, which keeps the iCloud container for dictionary sync until that is enabled. Debug builds never connect to CloudKit.

Signing needs a provisioning profile for the team on your Mac. If `make build` stops with "No profiles for 'com.techneissa.Pnoe.dev' were found", open `Pnoe.xcodeproj` in Xcode once with the team signed in under Settings > Accounts and build there, or pass `-allowProvisioningUpdates` to `xcodebuild`. If you are not the maintainer, use `make local`.

## Build with Xcode

```bash
make setup
open Pnoe.xcodeproj
```

Select the `Pnoe` scheme. Run builds `Pnoe Dev.app`; Archive uses Release, which still requests the iCloud entitlements and needs a paid team. `LOCAL_BUILD` applies only through `make local`.

## Troubleshooting

- Run `make check` to verify the required tools.
- Run `make whisper` if the framework is missing.
- If several Apple Development identities exist, set `LOCAL_CODESIGN_IDENTITY` explicitly.
- For additional help, open a [GitHub issue](https://github.com/techneissa/Pnoe/issues).

## The Built-in engine's services

The Built-in AI engine runs in two XPC services embedded in the app, so a model crash never takes down dictation: `PnoeFormatterXPC` (llama.cpp, GGUF files) and `PnoeFormatterMLXXPC` (MLX folders). Each links only its own engine. MLX needs its Metal library, which only `xcodebuild` can build (SwiftPM on the command line cannot), so build with `make build`, `make local` or Xcode; the first build compiles MLX and takes a few minutes. `make formatter-test` needs neither engine. Each service has its own entitlements file; `make local` passes `PNOE_XPC_ENTITLEMENTS` and `PNOE_MLX_XPC_ENTITLEMENTS` for them.
