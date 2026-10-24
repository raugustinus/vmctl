# Experiments

Retired or one-off material that is not part of the `vmctl` deliverable. Nothing
here is built by the Makefile or referenced from `Sources/`.

## usb-passthrough

The experimental USB accessory supervisor removed from the main package on
2026-09-24. See `docs/USB-PASSTHROUGH.md` for what was tried, what works, and why
iPhone passthrough is not possible on macOS 27. Contents:

- `USBPassthrough.swift`: the retired `vmctld` source file (imports `AccessoryAccess`).
- `build-usb.sh` and `USBApp/Info.plist`: the app-bundle build. The script expects
  to run from the package root beside the `Makefile`, `bin/`, and `vmctld.entitlements`;
  copy those three files back there to rebuild.
- `VMControlUSB.app`: the last profile-signed bundle. Built artifact, gitignored.
- `profile/`: the decoded provisioning profile and its developer certificate
  extracted while debugging signing. Contains team and device identifiers; gitignored.

## console-smoke

A standalone AppKit smoke test for the daemon's console window (opens, reuses,
closes, reopens without a guest). `main.swift` links against the `Console` and
`ConsoleApplicationDelegate` types from `Sources/vmctld`. The `console-smoke`
binary is the last build and is gitignored.
