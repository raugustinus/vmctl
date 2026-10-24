# vmctl design notes

How the daemon and CLI work, what is stored on disk, which Apple APIs are used, and
what has been validated. Moved out of the README so that one ends after usage.

## Architecture and lifecycle

`vmctl` is a short-lived synchronous socket client. On first use it starts the
signed sibling `vmctld` with Foundation `Process`, redirects its standard streams,
and waits up to five seconds for its private Unix socket. The daemon detaches from
the terminal with `setsid()`; it never forks a live Virtualization process. It
stays alive while idle and across independent CLI invocations. It is a per-user
background process, not a system daemon or an installed launchd service. Automatic
restart, login startup, reboot persistence and VM resume are intentionally absent.
Host sleep and logout are not promised uninterrupted guest uptime.

The daemon strongly retains the `VZVirtualMachine`, its delegate, and installer.
All VZ access and lifecycle transitions occur on the main dispatch queue, which
uses AppKit's main event loop in a logged-in desktop session (without a window
until requested), or `dispatchMain()` when no desktop session is available. Socket accept/read/write work runs
elsewhere; client disconnection does not destroy the VM. Requests and responses
are newline-delimited Codable JSON. Each connection carries one request/reply.
The server bounds connections (16), request size (8 KiB), and transport I/O time.
A client timeout reports uncertainty, not cancellation: query `status` afterward.

- `start`: constructs and validates configuration, then replies `running` only
  after `VZVirtualMachine.start` succeeds. It does not wait for guest login,
  networking, SSH, or tools. Repeated start while running is idempotent.
- `stop`: requests graceful shutdown if `canRequestStop`, awaits the delegate,
  then calls `stop` after 30 seconds if needed. If graceful shutdown is unavailable
  it forces immediately. Forced shutdown can lose unsaved guest data. Completion
  is reported only when stopped; framework failures become structured errors.
- `status`: reports `starting`, `running`, `stopping`, `installing`, `stopped`, or
  `error` from the daemon. It checks VM-directory existence but **never reads
  config, auxiliary storage, or the disk image**. Unknown names return an error.
- `ip`: matches the VM's MAC against unexpired records in `/var/db/dhcpd_leases`
  and returns the one with the latest expiry. A guest often holds two leases: the
  installer's DHCP client identifies by bare MAC, the installed system's client
  (dhcpcd, systemd-networkd) by an RFC 4361 identifier whose DUID-LLT or DUID-LL
  ends in the MAC; both forms are recognised. A DUID-EN identifier (systemd-networkd
  with its default `DUIDType=vendor`) contains no MAC and cannot be matched. This is
  best effort, because NAT exposes no public VZ guest-address API on the deployment
  baseline. The lease file is an undocumented host detail and may be missing or
  unreadable; then `ip_unknown` is returned. A lease is not proof that SSH is ready
  or that the guest has not changed its address.
- `logs`: returns approximately the last 24 KiB of `logs/daemon.jsonl`, containing
  timestamped lifecycle events and framework failures. It is not guest console
  output and does not stream. Log rotation is not implemented.
- `rm <name>`: deletes a stopped VM's directory, which is the whole VM: identity,
  firmware/auxiliary stores, disk image, cloud-init seed and logs. It refuses with
  `busy` while that VM is starting, running, stopping, installing or in `error`,
  never defaults the name, and cannot be undone. Nothing else needs cleaning up.

`create` reserves the directory without overwriting an existing VM, writes the
Mac identity and a configuration marked `installed: false`, creates auxiliary
storage and a disk, and runs `VZMacOSInstaller`. Only successful completion sets
`installed: true`. `start` rejects incomplete installations. A failed create keeps
its files and diagnostic logs; to retry, use a different name, or move the failed
directory aside **after the daemon is stopped**. Installation is not resumable.
`stop` is rejected during installation: Apple documents stopping/pausing at this
point as undefined behavior. TERM/INT/HUP during installation or startup are
ignored and logged; send again after that operation finishes.

A daemon crash destroys its ownership of the VM. Another process cannot adopt a
live `VZVirtualMachine`. On restart no VM is considered running; a later `start`
is a cold boot and may need guest filesystem recovery. On a normal TERM/INT/HUP
while running, the daemon uses the same graceful/forced stop sequence, then
removes its socket and PID file. It stays alive if shutdown fails.

## Storage, identity, and security

```text
~/.vmctl/
  control.sock           # private user-only control endpoint
  daemon.lock            # flock held for the daemon lifetime
  daemon.pid             # diagnostic, never treated as liveness authority
  daemon.log             # daemon startup errors
  vms/<name>/
    config.json          # version, name, kind, CPU, RAM, MAC, installed flag, guest version, first-boot eligibility
    hardware-model       # macOS: VZMacHardwareModel.dataRepresentation
    machine-identifier   # VZMacMachineIdentifier or VZGenericMachineIdentifier data
    auxiliary-storage    # macOS: persistent Mac auxiliary storage
    efi-variable-store   # Linux: persistent EFI variables, including boot order
    cloud-init.img       # Linux, after --user: NoCloud seed (password hash, public key)
    disk.img             # writable Virtio block image
    logs/daemon.jsonl
```

The Mac hardware model, machine identifier, auxiliary storage, disk, and MAC must
stay together between boots. The stored hardware model must still be supported
on the current host. The daemon validates the configuration before each boot.

The socket is mode 0600; directories are 0700 and files are 0600 under umask 077.
Both ends check socket peer UID with `getpeereid`. Names must match
`[a-z][a-z0-9-]{0,31}`. VM paths are derived internally, not accepted over IPC.
State directories/files are checked for ownership and private permissions;
symlinks and hard-linked state files are rejected. Restore, image and ISO paths
must be absolute local regular files; restore images are passed only to Apple's
restore-image API, ISOs only to read-only attachments. Existing unsafe state is
rejected rather than silently changing permissions.

An exclusive `flock` is acquired before replacing a stale socket or writing the
PID. Concurrent CLI startup attempts therefore cannot create two VM owners.
The PID file is informational; no lifecycle action sends a signal based on a
saved PID. `status` never guesses from a PID or opens a live disk to detect locks.
The current Unix user is the trust boundary: this does not isolate VM files from
other processes running as the same user. Do not run as root or put state in a
shared writable directory. No shell commands supplied by guests are executed.
The CLI's only child is the sibling daemon; the daemon spawns no commands.

`VMCTL_HOME` can override the absolute state directory for isolated testing. The
same environment must be used by clients targeting that daemon. Keep the path
short enough for macOS's Unix socket pathname limit (103 UTF-8 bytes including
`/control.sock`, excluding its terminating NUL).

## Apple APIs, signing, and version constraints

- `VZVirtualMachineConfiguration`, `VZVirtualMachine`, `VZVirtualMachineDelegate`:
  validation, asynchronous start, graceful `requestStop`, forced `stop`, and guest
  stop/error callbacks. All VM operations must use its serial queue.
- `VZMacOSBootLoader`, `VZMacPlatformConfiguration`, `VZMacHardwareModel`,
  `VZMacMachineIdentifier`, `VZMacAuxiliaryStorage`: Mac boot and persistent identity.
- `VZDiskImageStorageDeviceAttachment`, `VZVirtioBlockDeviceConfiguration`:
  persistent writable disk, never reopened by a second active VM.
- `VZVirtioNetworkDeviceConfiguration`, `VZMACAddress`,
  `VZNATNetworkDeviceAttachment`: stable guest MAC and framework-managed NAT.
- `VZMacGraphicsDeviceConfiguration` and `VZMacGraphicsDisplayConfiguration`:
  virtual macOS display, optionally shown by `VZVirtualMachineView` in an AppKit window.
- `VZUSBKeyboardConfiguration`, `VZUSBScreenCoordinatePointingDeviceConfiguration`:
  input devices for the local console.
- `VZMacOSRestoreImage`, `VZMacOSConfigurationRequirements`, `VZMacOSInstaller`:
  compatible image loading, minimum requirements, and macOS installation.
- `VZGenericPlatformConfiguration`, `VZGenericMachineIdentifier`, `VZEFIBootLoader`,
  `VZEFIVariableStore`, `VZUSBMassStorageDeviceConfiguration`,
  `VZVirtioGraphicsDeviceConfiguration`, `VZVirtioEntropyDeviceConfiguration`:
  Linux guests with EFI boot, per-boot installer ISOs, and a virtio display.

Mac guests and installation require Apple Silicon and were introduced in macOS
12. This package sets a macOS 13 host baseline; the core Mac APIs and forced stop
are available from 12, and every Linux API used is available from 13.
Host/guest/restore/hardware-model compatibility is checked at runtime rather than
assuming any IPSW can boot on any host. There is no Intel fallback, nested
virtualization, or use of private APIs. Newer APIs such as the public
`VZVirtualMachine.queue` property (macOS 26) are not needed.

Only `vmctld` needs `com.apple.security.virtualization`. Ad-hoc signing suffices
for local development. A distribution build should use the appropriate Developer
ID signing/notarization workflow, which this project does not automate. The
client has no special entitlements. NAT does not need the restricted bridged
network entitlement. App Sandbox is not enabled; adding it later would require a
new file-access and IPC design. Neither root nor a privileged helper is required.

Apple references:

- [Virtualization framework](https://developer.apple.com/documentation/virtualization)
- [Mac VM example](https://developer.apple.com/documentation/virtualization/running-macos-in-a-virtual-machine-on-apple-silicon)
- [Installing macOS](https://developer.apple.com/documentation/virtualization/installing-macos-on-a-virtual-machine)
- [VZMacOSInstaller lifecycle](https://developer.apple.com/documentation/virtualization/vzmacosinstaller)
- [GUI Linux VM example](https://developer.apple.com/documentation/virtualization/running-gui-linux-in-a-virtual-machine-on-a-mac)
- [Virtualization entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.virtualization)

## Validation

```sh
make test
```

Tests cover name/path rejection, file privacy, symlinks and hard links, bounded
socket frames, same-user peer authentication, separate CLI processes, singleton
daemon locking, private socket mode, structured errors, and orderly daemon exit.
The daemon integration test puts a FIFO at `disk.img` and no valid configuration:
status must still return without inspecting that image. Omitting `VMCTL_TEST_BIN`
skips daemon integration tests. Provisioning tests also cover account validation, first-boot/version gates, legacy
configuration compatibility, and absence of credentials in the stored model.
Linux coverage: sha512-crypt against the specification and OpenSSL vectors, the
FAT12 seed layout read back by an independent parser, public-key line validation,
and a daemon test that creates an EFI VM with no guest image, boots it to firmware
with a seed and a placeholder ISO attached, force-stops it, and boots it again.
Cross-user authentication rejection needs a
second local user and is not exercised by the single-user test suite.

Real restore/install/start/graceful-stop/forced-stop behavior needs a suitable
IPSW or Linux image and a hardware run; no guest image is bundled. Source
compilation and transport tests do not establish that an operating system was
booted or that cloud-init consumed a seed. No VM, image download, or files under
your default `~/.vmctl` are created by the test suite; the Linux daemon test does
start and stop a firmware-only VM under a temporary `VMCTL_HOME`.

