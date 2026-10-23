p='outputs/vmctl/README.md';s=File.read(p)
a=s.index('**Provisioning limitation:**');b=s.index('## Architecture',a)
s[a...b]=<<'DOC'
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
finished. Wait for guest setup before connecting. Xcode/Codex installation is
separate. Screen Sharing is not enabled. A virtual graphics device remains
configured for macOS boot without a local window or UI.

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

DOC
s=s.sub('with Swift 5.9+ to build.', 'with Swift and the macOS 27 SDK (Xcode 27+) to build.')
s=s.sub('version, name, CPU, RAM, MAC, installed flag', 'version, name, CPU, RAM, MAC, installed flag, guest version, first-boot eligibility')
s=s.sub('or use of private APIs.', 'or use of private APIs.')
s=s.sub('Newer\nAPIs', 'Newer\nAPIs')
s=s.sub('Cross-user authentication rejection', 'Provisioning tests also cover account validation, first-boot/version gates, legacy\nconfiguration compatibility, and absence of credentials in the stored model.\nCross-user authentication rejection')
File.write(p,s)
