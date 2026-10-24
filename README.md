# vmctl

I wanted the smallest possible way to run a macOS VM with an iPhone passed through
over USB, so Xcode in the guest could talk to a phone. macOS 27 added USB passthrough
to the Virtualization framework, so I built the supervisor and the Accessory Access
hand-over, and all of it worked right up to the last step: the framework rejects any
device with an isochronous endpoint in any of its USB configurations, and every
iPhone has one in its USB audio configuration. Apple does not allow it, full stop.
That dead end is written up in `docs/USB-PASSTHROUGH.md` for the next person who
hits the same wall.

What was left turned out to be useful on its own: a small Swift VM supervisor for
Apple Silicon that runs macOS or Linux guests, with first-boot user provisioning for
macOS and cloud-init for Linux. No third-party packages, guest agent, TCP control
port, or runtime dependency beyond macOS frameworks. The daemon never spawns a
command. The whole thing is small enough to read in one sitting, which was the point
while debugging USB and is still the point now.

Why not [Tart](https://tart.run)? Tart is the mature choice if you want OCI image
distribution, CI integration and a large feature set. vmctl is for when you want a
dependency-free supervisor you can audit in an afternoon.

One active local VM, named `mac` by default. The stored model includes a VM name,
so multiple inactive named VMs can exist, but v1 permits only one running or
installing VM at a time, whichever kind it is.

## Build and use

Requires an Apple Silicon Mac, macOS 13 or later, and Xcode or Command Line Tools
with Swift and the macOS 27 SDK (Xcode 27+) to build. The daemon deliberately fails compilation for Intel.

```sh
make
```

Fastest path: a Debian cloud image, a key-only user created by cloud-init on first
boot, SSH a few minutes later.

```sh
curl -LO https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.raw
./bin/vmctl create lin --linux --image "$PWD/debian-13-genericcloud-arm64.raw"
./bin/vmctl start lin --user dev --ssh-key ~/.ssh/id_ed25519.pub
./bin/vmctl list                     # the IP column fills once the guest has a lease
ssh dev@"$(./bin/vmctl ip lin)"
./bin/vmctl stop lin
```

Installing from an arm64 ISO through a console window is under "Linux guests" below.
A macOS guest needs a local Apple restore image and a long install:

```sh
./bin/vmctl create mac --restore /absolute/path/to/Apple.ipsw
./bin/vmctl start mac
./bin/vmctl status mac
./bin/vmctl ip mac
./bin/vmctl logs mac
./bin/vmctl stop mac
```

`make` builds release binaries and ad-hoc signs them; `SIGN_IDENTITY=... make` uses a
Developer ID instead. `make test` runs the suite and `make clean` removes `.build`
and `bin`. Keep `vmctl` and `vmctld` next to each other, for example in a private
user-owned `bin` directory. The Makefile selects SwiftPM's native engine for
compatibility with older Swift tools and this environment (`BUILD_SYSTEM=` overrides
it); Swift 6.4 warns that this engine is deprecated. It disables release debug
symbols. No Homebrew, Go, Node, Python, or package downloads are used.

`create` requires a **local Apple macOS restore IPSW**, obtained separately. It
validates compatibility through Apple's restore-image APIs; it does not download
an image or invoke another VM tool. Installation is long-running. The client
waits, but closing the client does not cancel installation. `status`/`logs` can be
used independently during installation. Default resources are 4 CPUs, 8 GiB RAM,
and a sparse 64 GiB disk (or the restore image's higher minimum CPU/RAM values).
The host must have enough resources for configuration validation and installation.

## First-boot user and SSH setup (macOS 27+)

Build this version with the macOS 27 SDK (Xcode 27+). Normal lifecycle commands
retain the macOS 13 deployment baseline; provisioning requires macOS 27+ on both
host and guest. Apple provides `VZMacGuestProvisioningOptions` for creating the
initial account and enabling SSH without a console window.

```sh
./bin/vmctl create dev --restore "$HOME/Downloads/UniversalMac_27.0_26A428_Restore.ipsw"
./bin/vmctl start dev --user dev --full-name "Developer"
# Enter and confirm the guest password at the hidden terminal prompts.
./bin/vmctl ip dev
ssh dev@GUEST_IP
```

Do not start this fresh VM without `--user` first. Apple only evaluates provisioning
on the first boot after restore. The manager records eligibility during creation
and consumes it before *any* start attempt, including ordinary start. After a
failed/crashed start the guest may already have booted, so provisioning is not
retried automatically. Recreate under another name if needed. Existing VMs from
older vmctl versions have unknown boot history and cannot use this operation.
This is initial setup, not an add-user or reset-password command for existing VMs.

`--full-name` defaults to the username. SSH is enabled and automatic login is
explicitly disabled. Passwords are read using `readpassphrase` on the controlling
terminal, confirmed, and sent only through the authenticated private Unix socket.
They are not accepted via flags, environment variables, or stdin and are never
written to config/logs. They necessarily exist briefly in process/framework memory;
Swift String copies cannot be guaranteed to be securely erased. The terminal input
buffer is cleared after reading. Failed provisioning API validation/start returns
generic errors to avoid reflecting credentials from framework error descriptions.

`running` still means VM start succeeded, not that guest user creation or SSH has
finished. Wait for guest setup before connecting. Xcode installation is
separate. Screen Sharing is not enabled automatically; use the optional local
console below to enable it in guest System Settings.

### Upgrading an already running daemon

Replacing the binary does not replace the running process. First stop your active
VM with `./bin/vmctl stop mac`, then quit your `vmctld` process in Activity Monitor.
The next CLI call starts the newly signed daemon. Do this **before** creating the
new VM, so its first-boot eligibility and guest version are recorded. Your existing
`mac` directory is preserved; use a new name such as `dev` for the new installation.
Builds replace executables atomically so an existing daemon keeps its original
executable. An old daemon rejects the distinct provisioning wire command rather
than silently starting a VM without account creation.

Apple reference: [Guest provisioning](https://developer.apple.com/documentation/virtualization/vzmacguestprovisioningoptions).

## Linux guests

Linux VMs use Apple's generic platform with EFI boot, a persisted
`VZGenericMachineIdentifier`, an EFI variable store, and virtio disk, network,
entropy and graphics devices. NAT, `ip`, `console`, `stop`, `logs` and `list` behave
as for macOS guests. Restart an older daemon before using these commands.

The cloud-image route is the quickstart above. The other route installs from an
arm64 ISO through the local console window:

```sh
./bin/vmctl create deb --linux
./bin/vmctl start deb --iso "$HOME/Downloads/debian-13.7.0-arm64-netinst.iso"
./bin/vmctl console deb          # install, create your user, tick "SSH server"
./bin/vmctl start deb            # boots from disk; --iso is per boot, never stored
```

`create --linux` prepares a sparse disk, or copies the raw image into it and extends
it to the disk size (cloud images grow their root filesystem on first boot). The copy
is an instant APFS clone on the same volume. The Linux disk defaults to 20 GiB;
`--disk 40G` (also `512M`, `1T`, or a bare number of GiB) picks another size between
1 GiB and 4 TiB, in whole MiB. The size is a ceiling the guest sees, not space taken: the file
is sparse and grows only with what the guest writes, which `du -h` on `disk.img` shows.
An image larger than the chosen disk is rejected. qcow2 images are rejected; convert
them elsewhere. Names containing `amd64`, `x86_64` or `i386` are refused, because only
arm64 guests boot here; an unbootable image otherwise shows up as `running` followed a
second later by a `guest_powered_off` log event. Image and ISO paths must be absolute
local regular files. Resources default to 4 CPUs and 8 GiB, clamped to the host's
allowed range. `created` means the disk is prepared, not that anything is installed.
If `create --disk` reports `daemon_upgrade_required`, the running daemon predates the
flag and built the default size; remove that VM directory, restart the daemon and retry.

`--iso` attaches the installer as a read-only USB mass storage device for that boot
only. `--user` on a Linux VM writes a cloud-init NoCloud seed (`cloud-init.img`, a
FAT12 volume labelled `CIDATA` holding `user-data` and `meta-data`) and attaches it
read-only. The same first-boot rule as macOS provisioning applies, and it only has
an effect on images that run cloud-init, such as Debian, Ubuntu or Fedora cloud
images. For ISO installs, create the user in the installer instead. Only the
configured account is created, not the image's default user. It gets `/bin/bash`
and passwordless sudo.

With `--ssh-key`, which takes a public key line or the path of a `.pub` file, the
account is key-only: no password prompt, password login locked, SSH password
authentication disabled. Without it, the password is prompted as for macOS and SSH
password login is enabled. The seed holds the sha512-crypt hash of the password,
never the plaintext, and the public key. vmctl never generates, stores or reads
private keys; `docs/AGENT-ACCESS.md` explains how that fits an AI-agent workflow.
`--ssh-key` and `--iso` are rejected for macOS VMs; `--restore` for Linux VMs.

Graceful `stop` sends an ACPI power-button event; a guest that ignores it is forced
off after 30 seconds. Shared folders, Rosetta, serial consoles and nested
virtualization are not configured.

## Design notes

Architecture and lifecycle, storage and security, the Apple APIs used, and the
validation record are in `docs/DESIGN.md` and `docs/VALIDATION.md`.

## List saved VMs

```sh
./bin/vmctl list
# NAME    STATE     IP
# dev     running   192.168.64.3
# mac     stopped   -
```

Names are sorted alphabetically. States come from the supervisor, just like
`status`; listing never opens config files or disk images. The IP column is the
same best-effort NAT lease lookup as `ip`, using the MAC the supervisor kept in
memory when it started the VM; it shows `-` for every VM that is not running and
for a running VM with no readable unexpired lease yet. An empty store prints
only the header. Only private, user-owned VM directories with valid names are
listed; symlinks and unrelated entries are ignored. A saved directory can represent
an incomplete installation, so `stopped` does not imply it is bootable.
`list` takes no arguments. Restart an older daemon to enable this new command.

## Open a local console and enable Screen Sharing

After upgrading, stop the active VM and quit the old `vmctld` process in Activity
Monitor. Run the updated binaries from Terminal in your logged-in desktop session.
Restarting the VM supplies the new virtual keyboard and mouse devices. Do not
repeat `--user` for an already-booted VM.

```sh
./bin/vmctl start dev
./bin/vmctl console dev
```

`console` requires the named VM to be running. It opens (or brings forward) one
native window displaying the existing daemon-owned `VZVirtualMachine`. It never
opens a second disk attachment, transfers VM ownership, or launches a second VM.
The CLI returns after requesting the window. Clicking inside it sends keyboard
and pointer input to the guest; host system shortcuts remain available. The
initial display uses the host screen’s pixel density for a 1024×768-point window.
On macOS 14+, Apple’s automatic display reconfiguration updates the guest display
as the window resizes or moves between screens. On macOS 13, the initial display
configuration remains fixed. Without a host screen, the fallback is 2048×1536
pixels at 160 PPI. Guest-supported display modes can still affect effective scaling.
The console window uses an explicit sRGB color space as an SDR baseline; AppKit
handles output conversion to the host display. HDR/wide-gamut fidelity is not a
console feature. The visual result still depends on the guest display profile.

Closing the window leaves the VM and daemon running. Calling `console` again
reopens it. Guest shutdown/error closes the view and releases its VM reference.
Quitting the daemon through its Dock icon uses the existing graceful/forced
shutdown sequence. A daemon started without a desktop session can still manage
VMs headlessly, but it cannot show a console; restart it in a desktop Terminal.
No additional entitlements, TCP listeners, clipboard bridge or guest agent are added.

In the **guest**, open **System Settings → General → Sharing**. Turn off Remote
Management if enabled, turn on **Screen Sharing**, and allow your guest account.
You can also complete Setup Assistant through this console on an older installation.
Then, on the **host**, connect using:

```sh
open "vnc://$(./bin/vmctl ip dev)"
```

After confirming the remote connection works, close the local console window.
Apple's guide: [Turn Mac screen sharing on or off](https://support.apple.com/guide/mac-help/mh11848/mac).

## Shutdown completion and immediate power-off

Normal `stop` keeps a 30-second graceful-shutdown deadline. In addition to Apple's
guest-stop delegate callback, the daemon checks `VZVirtualMachine.state` every
100 ms while waiting and completes as soon as it observes `.stopped`. Every control
request also reconciles a running/stopping VM against the live framework state.
No disk inspection or IP/ping timeout is used to decide that the VM is off.
Already-stopped state wins over the timeout, and cancelled timers cannot act on a
replacement VM. Multiple stop callers share the same shutdown operation.

If the guest does not shut down in response to the request, normal stop still waits
for the grace period. For intentional immediate power-off instead:

```sh
./bin/vmctl stop dev --force
```

This bypasses graceful shutdown and can lose unsaved guest data. It also escalates
an already-pending graceful stop; duplicate forced-stop requests do not start
multiple framework stop operations. The CLI still waits for confirmed termination.
An older running daemon must be restarted to understand this option.

## USB passthrough

Not in the shipping daemon. The attempt, what worked, and the Apple restriction that
ends it are in `docs/USB-PASSTHROUGH.md`; the retired code is under
`experiments/usb-passthrough/`. Normal lifecycle and console operation use vmctld
directly and require no USB provisioning profile.

## Repository layout

```text
Package.swift, Sources/, Tests/   # the SwiftPM package
Makefile, vmctld.entitlements     # release build/test targets and daemon entitlements
bin/                              # signed binaries produced by make (gitignored)
docs/DESIGN.md                    # architecture, storage, security, Apple APIs used
docs/VALIDATION.md                # record of what was tested and when
docs/AGENT-ACCESS.md              # giving an AI agent SSH access without the private key
docs/USB-PASSTHROUGH.md           # the iPhone passthrough attempt and why Apple blocks it
experiments/                      # retired USB passthrough code and a console smoke test
LICENSE                           # BSD 3-Clause
```

## License

BSD 3-Clause. See `LICENSE`.
