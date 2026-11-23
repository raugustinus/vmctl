import Foundation
import Darwin

/// A directory of a Linux guest mounted on this Mac over NFS: the reverse of `--share`. The guest
/// keeps the files on its own disk and sees nothing of the Mac; the Mac reads and writes them.
///
/// The guest exports the one directory to the one address this Mac has on the VM network, and maps
/// every access to the account `vmctl start --user` created, so files written from the Mac belong
/// to that account. vmctl sets the export up over SSH, as that account, the first time.
public enum GuestMount {
    /// One mount of one VM, kept in the VM's directory so `start` can mount it again and `stop`
    /// can unmount it before the server goes away.
    public struct Record: Codable, Equatable {
        public let guestPath: String
        public let mountPoint: String
        public init(guestPath: String, mountPoint: String) { self.guestPath = guestPath; self.mountPoint = mountPoint }
    }
    public static let recordsFile = "mounts.json"

    /// An absolute guest path of plain characters, normalised. It goes into a shell script, an
    /// exports line and a mount argument, so anything that would need quoting in one of them is
    /// refused rather than escaped three ways.
    public static func validate(guestPath: String) throws -> String {
        let invalid = Failure("invalid_guest_path", "Give an absolute directory in the guest, of letters, digits, '.', '_', '-' and '/', such as /home/dev/project.")
        guard guestPath.hasPrefix("/"), guestPath.utf8.count <= 1024,
              guestPath.range(of: "^[A-Za-z0-9._/-]+\\z", options: .regularExpression) != nil else { throw invalid }
        let parts = guestPath.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else {
            throw parts.isEmpty ? Failure("invalid_guest_path", "The guest's / cannot be mounted; name a directory in it.") : invalid
        }
        return "/" + parts.joined(separator: "/")
    }

    /// `~/vm/<name>/<directory name>`: where a guest directory lands when no mount point is given.
    public static func defaultMountPoint(home: String, name: String, guestPath: String) -> String {
        "\(home)/vm/\(name)/\(URL(fileURLWithPath: guestPath).lastPathComponent)"
    }

    /// The exports file of one guest directory: one file per directory, so removing one export
    /// never touches another, nor anything the guest's owner put in /etc/exports.
    public static func exportsFile(guestPath: String) -> String {
        "/etc/exports.d/vmctl" + guestPath.replacingOccurrences(of: "/", with: "-") + ".exports"
    }

    /// What ssh runs in the guest: the script on stdin, as root, told this Mac's address as the
    /// guest sees it (from the SSH connection itself) and the account's own uid and gid.
    public static let remoteCommand = #"sudo -n sh -s -- "${SSH_CONNECTION%% *}" "$(id -u)" "$(id -g)""#

    /// Exports `guestPath` to the calling address only. Idempotent. Installs the NFS server where
    /// it is missing and apt-get exists; elsewhere it says what to install.
    public static func exportScript(guestPath: String) throws -> String {
        let dir = try validate(guestPath: guestPath)
        return """
        set -eu
        client=$1 uid=$2 gid=$3
        dir='\(dir)'
        [ -d "$dir" ] || { echo "vmctl: $dir is not a directory in the guest" >&2; exit 3; }
        case "$client" in ''|*[!0-9a-fA-F.:]*) echo "vmctl: cannot tell this Mac's address as the guest sees it" >&2; exit 4 ;; esac
        if ! command -v exportfs >/dev/null 2>&1; then
            if command -v apt-get >/dev/null 2>&1; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nfs-kernel-server >/dev/null
            else
                echo "vmctl: the guest has no NFS server; install it (nfs-kernel-server or nfs-utils) and mount again" >&2; exit 5
            fi
        fi
        mkdir -p /etc/exports.d
        [ -e /etc/exports ] || : > /etc/exports
        printf '%s %s(rw,sync,no_subtree_check,all_squash,anonuid=%s,anongid=%s,insecure)\\n' "$dir" "$client" "$uid" "$gid" > '\(exportsFile(guestPath: dir))'
        exportfs -ra
        systemctl enable --now nfs-server >/dev/null 2>&1 || systemctl enable --now nfs-kernel-server >/dev/null 2>&1 || true
        """
    }

    /// Removes the export of `guestPath` again.
    public static func unexportScript(guestPath: String) throws -> String {
        let dir = try validate(guestPath: guestPath)
        return """
        set -eu
        rm -f '\(exportsFile(guestPath: dir))'
        command -v exportfs >/dev/null 2>&1 && exportfs -ra || true
        """
    }

    /// Arguments of /sbin/mount_nfs. NFSv3 over TCP from an unprivileged port (the export says
    /// `insecure`), so no root is needed on the Mac. `soft,intr`: a guest that is gone gives an
    /// error after a while, not a hang for ever. File locks stay on this Mac (`locallocks`): the
    /// guest's lock daemon is not reachable through a default firewall and one user has no use
    /// for it. Nothing in a guest's directory is trusted as a device or a setuid program.
    public static func mountArguments(address: String, guestPath: String, mountPoint: String) throws -> [String] {
        let dir = try validate(guestPath: guestPath)
        guard Provisioning.isIPAddress(address) else { throw Failure("invalid_address", "Not an IP address: \(address).") }
        let host = address.contains(":") ? "[\(address)]" : address
        return ["-o", "vers=3,tcp,rw,noresvport,soft,intr,locallocks,nodev,nosuid", "\(host):\(dir)", mountPoint]
    }

    /// A mount point is a directory of the user's that is empty, or does not exist yet below one
    /// that does. `/`, the home directory itself and anything inside the store are refused.
    public static func validate(mountPoint: String, home: String, store: String) throws {
        let path = URL(fileURLWithPath: mountPoint).standardizedFileURL.path
        guard mountPoint.hasPrefix("/"), path != "/", path != home, path != store, !path.hasPrefix(store + "/"),
              !mountPoint.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure("invalid_mount_point", "Mount on an empty directory of your own, not on /, your home directory or \(store).")
        }
    }

    public static func records(in vmDirectory: URL) throws -> [Record] {
        let url = vmDirectory.appendingPathComponent(recordsFile)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Record].self, from: Store.read(url))
    }
    public static func save(_ records: [Record], in vmDirectory: URL) throws {
        let url = vmDirectory.appendingPathComponent(recordsFile)
        if records.isEmpty {
            if unlink(url.path) != 0 && errno != ENOENT { throw systemFailure("unlink \(recordsFile)") }
            return
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Store.write(encoder.encode(records), to: url)
    }
    /// The records with one added: a mount point is used once, and mounting the same guest
    /// directory at the same place again changes nothing.
    public static func adding(_ record: Record, to records: [Record]) throws -> [Record] {
        if records.contains(record) { return records }
        if let other = records.first(where: { $0.mountPoint == record.mountPoint }) {
            throw Failure("mount_point_in_use", "\(record.mountPoint) is the mount point of \(other.guestPath) already. Unmount that first.")
        }
        return records + [record]
    }
}
