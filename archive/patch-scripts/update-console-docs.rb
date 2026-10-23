p='outputs/vmctl/README.md'; s=File.read(p)
s=s.sub('No third-party packages, guest agent, UI, TCP control port, or', 'No third-party packages, guest agent, TCP control port, or')
s=s.sub("separate. Screen Sharing is not enabled. A virtual graphics device remains\nconfigured for macOS boot without a local window or UI.", "separate. Screen Sharing is not enabled automatically; use the optional local\nconsole below to enable it in guest System Settings.")
s=s.sub("continues running through `dispatchMain()`.", "uses AppKit's main event loop in a logged-in desktop session (without a window\nuntil requested), or `dispatchMain()` when no desktop session is available.")
s=s.sub('  virtual macOS display without `VZVirtualMachineView` or AppKit.', '  virtual macOS display, optionally shown by `VZVirtualMachineView` in an AppKit window.\n- `VZUSBKeyboardConfiguration`, `VZUSBScreenCoordinatePointingDeviceConfiguration`:\n  input devices for the local console.')
s=s.gsub('window.\\n-', "window.\n-").gsub('Configuration`:\\n', "Configuration`:\n")
s += <<'DOC'

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
virtual display stays at 1024×768; resizing the window scales the view.

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
DOC
File.write(p,s)
