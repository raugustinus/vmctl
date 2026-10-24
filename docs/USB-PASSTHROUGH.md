# iPhone USB passthrough: what works and where Apple stops it

vmctl exists because of this experiment. The goal was the smallest possible macOS VM
that could have an iPhone passed through over USB, so Xcode in the guest could pair
with a phone. macOS 27 added USB passthrough to the Virtualization framework, and
everything up to the hand-over works. The last step does not, and it is Apple's rule,
not a bug anyone can fix from outside.

**What works** (verified 2026-09-23 on a macOS 27 host with a profile-signed app):

- Registering the daemon as an Accessory Access client with the
  `com.apple.developer.accessory-access.usb` entitlement.
- The system **Virtual Machine Accessories** menu-bar item appearing, listing the
  iPhone, and the user assigning it to the app.
- macOS handing the device to the daemon, which attaches an XHCI controller to the VM.

**What fails:** creating the `VZUSBPassthroughDevice` for the iPhone. The framework
rejects any device that advertises an isochronous endpoint in *any* of its USB
configurations. Every iPhone carries one in its USB audio configuration, even when that
configuration is not the active one, so every iPhone is rejected with "A USB passthrough
device with isochronous endpoints is not supported." The framework also documents that
USB hubs and USB 3 ports are unsupported. Apple decides which accessories can be assigned;
no code on the host side can force an unsupported device through.

**What is left:** devices without isochronous endpoints, such as storage and serial
adapters, are what the API is for. That path is untested here, because the original
need was the phone. The USB code was removed from the shipping daemon on 2026-09-24 and
is kept under `experiments/usb-passthrough/` with the instructions below. The rest of
this document is the original working notes.

## Signing and building

The USB code is not part of the `vmctl` package any more. To rebuild it, copy
`build-usb.sh` and `USBApp/Info.plist` from `experiments/usb-passthrough/` back to the
package root beside the `Makefile`, and restore `USBPassthrough.swift` into
`Sources/vmctld/`. The notes below are as written when it was live.

The normal ad-hoc `make` build still works for lifecycle/console commands. USB uses
a separate app bundle because Accessory Access requires an ordinary Dock-visible
application and `com.apple.developer.accessory-access.usb` authorization.

1. In your Apple developer signing setup, create an explicit macOS App ID for
   this tool and enable **Accessory Access / Claim USB Accessory**. If the
   capability requires approval for your team, obtain it before proceeding.
2. Generate/download a macOS provisioning profile for that App ID and your signing
   certificate, with the USB entitlement included. A development profile must
   authorize this Mac. An iOS profile or an unrelated app's profile will not work.
3. Build from this project directory:

```sh
USB_PROFILE="/absolute/path/to/VMControl.provisionprofile" \
SIGN_IDENTITY="Apple Development: Your Name (IDENTIFIER)" \
./build-usb.sh
```

The script checks for the entitlement, uses the profile's App ID as the bundle
identifier, embeds the profile, and signs `bin/VMControlUSB.app`. It does not
request entitlements, change your developer account, or modify existing profiles.
It may prompt for local signing-key access. No private key is copied into the app.
The normal daemon remains in `bin/vmctld`. Once the USB app exists beside `vmctl`,
the CLI prefers it for automatic daemon startup and launches it through
LaunchServices (`/usr/bin/open`) rather than as a direct child. This matters: a
daemon exec'd from a terminal inherits the terminal as its responsible process,
TCC then attributes it to the terminal app, and the accessory menu never appears.
Startup errors of a LaunchServices-launched daemon go to the unified log rather
than `daemon.log`. Run `build-usb.sh`
after USB app updates; running only `make` does not refresh an existing USB app.
To return to the ordinary supervisor, stop the VM, quit the supervisor, and move
`VMControlUSB.app` out of `bin` before starting again.

## Assign a device

Stop your active VM and quit the older `vmctld` in Activity Monitor once, then:

```sh
./bin/vmctl start dev
./bin/vmctl usb on dev
```

The VM now has an XHCI controller. The app registers interest in all USB devices,
as Apple's sample does (a vendor-filtered criteria object built through the Swift
overlay never produced a match), and stays visible in the Dock while USB support
is enabled. Connect the device. A **Virtual Machine Accessories** status item, a
cable-connector icon, appears at the top right of the menu bar next to Wi-Fi and
battery; on a notched MacBook display it can be hidden if the menu bar is full.
Click it and choose **Use with VMControl USB** for the device. This user selection
is required; the CLI never silently seizes host devices. Do not select your host
keyboard or mouse. A previously assigned accessory may be reattached when you
explicitly enable USB.

```sh
./bin/vmctl usb status dev
./bin/vmctl logs dev
```

`enabled` means the listener registered; it does **not** mean a device attached.
`attached registry-id=...` means Apple's virtual USB controller accepted the
device, not that Xcode pairing succeeded. Framework errors are returned or retained
in `usb status` and logged under the VM directory. Unlock/trust and Developer Mode
prompts on the phone remain your responsibility. We do not import host pairing
records, bypass phone permissions, enable recovery mode, or run guest commands.

To detach after stopping any guest device operation:

```sh
./bin/vmctl usb off dev
```

This detaches virtual devices and unregisters the listener. If macOS still assigns
the accessory to the app, release it back to the host through the accessory menu.
Closing the VM console does not disable USB or remove the Dock app. Stopping the
VM clears its USB session; explicit `usb on` is required after a VM restart.
Fast user switching, logout, unplug/replug and device mode changes can disconnect
and reconnect accessories. No permanent auto-capture setting or device catalog
is saved. Host and guest cannot exclusively use the same device simultaneously.

## Current validation boundary

Verified on 2026-09-23 with a profile-signed `VMControlUSB.app` on a macOS 27
host: listener registration, the Virtual Machine Accessories menu, user assignment
of an iPhone, and the hand-over to the daemon all work. The Virtualization
framework then rejects the iPhone at `VZUSBPassthroughDevice` creation because of
its isochronous endpoints, so no iPhone reached the guest and Xcode pairing was
never exercised. No non-isochronous device has been attached yet either; that
remains untested.

References:
- [Apple's USB passthrough walkthrough](https://developer.apple.com/videos/play/wwdc2026/224/)
- [Accessory Access manager](https://developer.apple.com/documentation/accessoryaccess/aausbaccessorymanager)
- [USB entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.accessory-access.usb)
