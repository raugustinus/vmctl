# Validation performed

On 2026-09-23, on arm64 macOS with Apple Swift 6.4:

- Release build completed using `./build.sh`.
- `codesign --verify --strict bin/vmctld` passed.
- The signed daemon contains `com.apple.security.virtualization = true`.
- All 5 XCTest tests passed (0 failures), including the signed daemon integration test.
- Integration exercised separate CLI processes, daemon auto-start, stale socket/PID
  recovery, singleton locking, status with a FIFO disk and no config, structured
  request errors, 0600 socket permissions, and signal-driven clean exit.
- No VM state was created under the default `~/.vmctl` path.

The integration test initially encountered sandbox restrictions on Virtualization
availability and Unix-socket bind. After local network permission was granted,
all IPC tests passed. The daemon checks Virtualization availability only when
starting/creating a guest, so status and diagnostics remain usable independently.

No Apple restore image was provided. Real macOS installation, VM boot, guest IP
lease discovery, graceful guest shutdown, and forced shutdown were **not tested**.
Cross-user socket rejection was not tested with a second OS account. These remain
hardware/integration checks, not guarantees established by the passing test suite.

The test command used an isolated build directory to avoid local build metadata
and disabled debug-symbol generation:

```sh
VMCTL_TEST_BIN="$PWD/bin" swift test \
  --scratch-path /tmp/vmctl-validation-build \
  --build-system native --disable-sandbox -debug-info-format none
```

## User provisioning update

The rebuilt, signed binaries support `start --user` via macOS 27 guest provisioning.
All 7 tests passed after this update, including a daemon-level rejection of
provisioning an already-booted VM and checks for legacy config compatibility,
account validation, and first-boot/version restrictions. An attempted terminal
prompt in the tool environment returned `password_prompt` rather than using
visible input; hidden interactive entry still needs verification in Terminal.
The new API compiles against the installed macOS 27 SDK. A real provisioned guest
and SSH login have not yet been tested. The user independently reported successful
installation, normal boot and an IP address with the previous version.

## Local console update

The release build and signing completed with AppKit and `VZVirtualMachineView`.
All 7 tests pass, including stopped-VM console rejection, argument validation,
and continued daemon availability after a rejected console request. The VM
configuration now includes USB keyboard and absolute-coordinate pointer devices.

A separate blank-window smoke harness was compiled, but the execution sandbox
could not access the desktop session/Launch Services and returned
`console_unavailable`. Window focus, keyboard/pointer interaction, closing/reopening
and a real guest display remain to be verified from the user's desktop Terminal.
The existing daemon reported `dev running` and `mac stopped`; no user VM was
stopped or reconfigured during this update.

## Shutdown detection update

The user's dev log showed shutdown requested at 18:34:53 UTC, forced shutdown at
18:35:24, and stopped at 18:35:25. The old force path checked framework state before
forcing, so this trace does not establish a delayed callback after an already-off VM.

Added a 100 ms state watch during graceful shutdown, request-time state
reconciliation, and explicit `stop --force`. Release build/signing and all 11 tests
passed. Four new watchdog tests cover shutdown without a delegate callback,
completion winning at the deadline, a single timeout action, and cancellation/
replacement invalidating pending ticks. CLI integration covers idempotent forced
stop of an inactive VM and invalid force arguments. No live guest was powered off
for validation; real guest shutdown latency has not been remeasured.

## Console display-quality update

Replaced the 1024×768/80-PPI guest configuration with Apple's screen-derived
pixel dimensions and density, using a 2048×1536/160-PPI fallback without a host
screen. Enabled automatic display reconfiguration on macOS 14+ to follow window
resizing and screen changes. The NSWindow uses explicit sRGB as an SDR baseline.

The release build passed and all 11 existing tests passed after the resolution
change. The sRGB addition was subsequently rebuilt. Tests do not measure visual
quality; the console could not be selected through the available UI tooling.
Retina sharpness, guest mode changes and the reported color mismatch need a visual
check on the user's display after restarting the updated daemon/VM. No running
user VM or host/guest display settings were changed during implementation.

## Experimental USB support

Compiled the AccessoryAccess listener, VZUSBPassthroughDevice hot-plug path, XHCI
controller configuration and opt-in CLI commands against the macOS 27 SDK. The
normal signed release build verifies and all 11 tests pass, including USB CLI
argument validation, disabled status/off, and rejecting USB enable for a stopped
VM. AccessoryAccess is verified as LC_LOAD_WEAK_DYLIB to preserve the older-host
normal lifecycle path. USB app Info.plist and build script syntax validate; the
bundle builder rejects a missing USB_PROFILE before attempting a privileged build.

Two Apple Development identities were visible, but none of the three local
provisioning-profile files contained the USB entitlement. The restricted USB app
was therefore not signed/launched; physical capture, hot-unplug/replug, device
approval UI and Xcode/iPhone behavior remain untested. No host USB device was
captured, no running VM was stopped, and no signing profile was changed.

## USB passthrough real-device run (2026-09-23)

Built and launched the profile-signed USB app on a macOS 27 host. Three defects
were found and fixed on the way to a real assignment: the dictionary-based
`AAUSBAccessoryMatchingCriteria` initializers return nil for every dictionary
tried, so the daemon now registers with an empty criteria list like Apple's
sample; a daemon exec'd from the terminal was attributed to the terminal by TCC
and the accessory menu never appeared, so the CLI now launches the app bundle via
LaunchServices; and a LaunchServices-launched app cannot switch its activation
policy from prohibited to regular, so the hidden state is now accessory.

With those fixes the Virtual Machine Accessories menu listed the iPhone, the user
assigned it, macOS re-enumerated the phone and detached host drivers, and the
daemon received it. `VZUSBPassthroughDevice` creation then failed with
VZErrorDomain -6, "A USB passthrough device with isochronous endpoints is not
supported." A descriptor dump showed the phone's active configuration has no
isochronous endpoints; only its USB audio configuration has one. The framework
therefore inspects every configuration. iPhone passthrough is not possible on
macOS 27. All 11 tests pass on the final build.

## USB integration retired (2026-09-24)

Removed the accessory listener, experimental CLI commands, XHCI passthrough
controller, AccessoryAccess linkage, and USB app auto-launch. Console keyboard
and pointer devices remain. Retired source and app bundle are backed up under
experiments/usb-passthrough. USB registration was disabled in the
existing supervisor; dev remained running. The running supervisor still needs
an orderly restart to switch to the standalone binary.

Release build and strict signature verification passed. All 11 XCTest tests,
including separate CLI invocations and daemon locking, passed with the rebuilt
binaries. Live console activation has not been visually verified.

## Linux guest support (2026-10-23)

Added EFI generic-platform Linux guests: `create --linux [--image raw]`, `start --iso`,
and first-boot provisioning through a cloud-init NoCloud seed (`--user`, optional
`--ssh-key`, password hashed with sha512-crypt). The seed is a FAT12 volume with VFAT
long names written in Swift; the daemon still spawns no commands.

Release build and strict signature verification passed on arm64 macOS with Swift 6.4.
All 17 XCTest tests passed. New coverage: sha512-crypt against the specification vector
and three OpenSSL `passwd -6` outputs; FAT12 layout, FAT chains, long-name entries and
size limits read back by an independent parser; user-data never containing the plaintext
password; public-key line validation; legacy request/config decoding; Linux eligibility.

The daemon integration test created a Linux VM with no guest image, booted it to EFI
firmware with a fake installer ISO and a cloud-init seed attached, observed `running`,
force-stopped it, rejected a second provisioning attempt with `first_boot_required`,
booted it again from disk, and stopped it. A generated seed image was attached with
`hdiutil` on the host: `fsck_msdos -n` reported no errors, the volume mounted as
`/Volumes/CIDATA`, and `user-data`/`meta-data` were readable with their long names.

Not tested: a real Linux installation or cloud image boot (no arm64 Linux image was on
this machine; both local ISOs are x86_64), cloud-init actually consuming the seed,
SSH login with the installed key, graceful ACPI shutdown of a Linux guest, the Linux
console display, and raw-image import of a multi-gigabyte file. The user's existing
`dev` and `mac` VMs were not started, stopped, or modified; no daemon was running.

## Wrong-architecture image guard (2026-10-23)

A first real attempt booted `debian-13.7.0-amd64-netinst.iso` on Apple Silicon: `start`
reported `running` and the EFI firmware halted one second later with nothing bootable,
so `console` found the VM stopped. `localFile` now rejects installer ISOs and raw images
whose name contains `amd64`, `x86_64`, `x86-64`, `i386` or `i686` with `invalid_installer`
or `invalid_image` naming arm64, and a guest that stops on its own while `running` logs
`guest_powered_off`. The integration test covers both rejections; all 17 tests pass.
Verified live: the same command against the rebuilt daemon now fails immediately with
the arm64 message instead of reporting `running`. The arm64 netinst boot itself is still
untested at the time of writing.

## Linux disk size flag (2026-10-23)

`create --linux --disk <size>` sends a byte count; the daemon accepts whole MiB between
1 GiB and 4 TiB (`invalid_disk_size` otherwise), sizes the sparse disk, and rejects an
image larger than the chosen disk (`image_too_large`). macOS creates reject the field
with `unsupported_option`. Because an older daemon ignores unknown request fields, the
CLI stats `disk.img` after `created` and reports `daemon_upgrade_required` if the size
differs. The integration test creates a 2 GiB VM and reads the size back, and rejects a
missing value, `0G`, `20X`, `500M`, and a 3 GiB sparse image against a 2 GiB disk.
Release build, signing and all 17 tests passed. The running daemon still predates the
flag while a Debian install is in progress on `deb`; the `deb` disk occupied 1.4 GiB
of host space during the install against its 64 GiB ceiling.

## vmctl rm (2026-10-23)

`rm <name>` deletes a stopped VM's private directory through the daemon and replies
`removed`. It refuses with `busy` while that name is active in any phase other than
`stopped` or while a machine object exists, never defaults the name (`vmctl rm` alone
is a usage error), and maps an older daemon's `invalid_command` to
`daemon_upgrade_required`. The integration test covers the busy refusal on a running VM,
removal of a never-started VM and of the last active VM, the missing-name error, a
repeat removal, and `list`/`status` afterwards. All 17 tests passed on the rebuilt,
signed binaries. Not exercised live: the running daemon predates `rm` while a Debian
install is in progress.

## IP column in list (2026-10-23)

`list` now prints `NAME\tSTATE\tIP`. The supervisor keeps the started VM's MAC in
memory (`activeMAC`) so neither `list` nor `ip` reads config files; the column is the
same `/var/db/dhcpd_leases` lookup as `ip` and shows `-` for stopped VMs and for a
running VM without a readable unexpired lease. All four `list` assertions in the daemon
tests were updated; the firmware-only Linux guest shows `-` while running, as expected
since it never requests a lease. All 17 tests passed. A real lease in the column is
untested until a Linux or macOS guest with networking is booted on the new daemon.

## Lease lookup fix (2026-10-23)

After the first real Debian install, `ip`/`list` reported 192.168.64.36 while the guest
was on .37. `/var/db/dhcpd_leases` held two unexpired leases for the VM's MAC: the
installer's client identified by bare MAC (`1,<mac>`), the installed dhcpcd by an
RFC 4361 identifier (`ff,<IAID><DUID-LLT>`) ending in the MAC. The old parser matched
only the bare form and walked the file oldest-first. The parser moved to
`VMCore/Leases.swift`, recognises type 1, DUID-LLT and DUID-LL identifiers, refuses
DUID-EN, and returns the unexpired lease with the latest expiry. Three unit tests use
the real file excerpt and synthetic variants. 20 tests pass. The new daemon has not been
restarted yet while `deb` is running, so the live column still shows .36 until then.

## Linux default disk 20 GiB; first live rm (2026-10-24)

The Linux default disk is now 20 GiB sparse (`linuxDiskSize`); macOS keeps 64 GiB
(`macDiskSize`). The daemon test asserts the default by stat. 20 tests pass. Live on
the new daemon: `stop deb` shut the installed Debian 13 guest down gracefully over
ACPI, the old daemon exited on SIGTERM, and `rm deb` / `rm dev` each replied `removed`,
leaving only `mac`. Earlier on 2026-10-23 the Debian arm64 netinst installed to the
virtio disk via the console window, rebooted from disk, obtained a NAT lease, and
accepted SSH on 192.168.64.37, so a real Linux guest boot and the console display are
now verified; cloud-init consumption still is not.
