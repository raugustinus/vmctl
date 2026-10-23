import AppKit
import Virtualization
import VMCore

// Lives in the VM owner, on its main thread/queue. No VM crosses the IPC boundary.
final class Console: NSObject, NSWindowDelegate {
    static let initialSize = NSSize(width: 1024, height: 768)
    private var window: NSWindow?
    private var view: VZVirtualMachineView?

    static var hasDesktopSession: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let uid = session[kCGSessionUserIDKey as String] as? NSNumber,
              uid.uint32Value == getuid(),
              session[kCGSessionLoginDoneKey as String] as? Bool == true else { return false }
        return true
    }

    func show(_ machine: VZVirtualMachine?, name: String) throws {
        guard Thread.isMainThread, Self.hasDesktopSession else {
            throw Failure("console_unavailable", "Console requires a daemon launched in your logged-in macOS desktop session. Stop the VM and restart vmctld from Terminal in that session.")
        }
        let app = NSApplication.shared
        if app.activationPolicy() != .regular {
            _ = app.setActivationPolicy(.regular)
        }
        // A failed Dock-policy transition does not imply windows are forbidden:
        // accessory apps can also create and activate windows.
        guard app.activationPolicy() != .prohibited else {
            throw Failure("console_unavailable", "Supervisor activation policy is prohibited (\(app.activationPolicy().rawValue)); macOS does not allow this process to create windows. Stop the VM and relaunch the supervisor from your desktop session.")
        }
        if window == nil {
            let frame = NSRect(origin: .zero, size: Self.initialSize)
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            // Explicit SDR output space; AppKit handles conversion to the host
            // display profile. This console does not promise HDR/wide-gamut fidelity.
            window.colorSpace = .sRGB
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 640, height: 480)
            window.delegate = self
            let view = VZVirtualMachineView(frame: frame)
            view.autoresizingMask = [.width, .height]
            if #available(macOS 14.0, *) {
                // Let Virtualization negotiate actual guest pixels/DPI as the
                // window resizes or moves between Retina and external displays.
                view.automaticallyReconfiguresDisplay = true
            }
            // Host system shortcuts remain available for switching away from the console.
            view.capturesSystemKeys = false
            window.contentView = view
            self.window = window; self.view = view
            window.center()
        }
        view?.virtualMachine = machine
        window?.title = "vmctl — \(name) (closing this window keeps the VM running)"
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(view)
        app.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        view?.virtualMachine = nil
        window?.delegate = nil
        view = nil; window = nil
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

final class ConsoleApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Route AppKit Quit through the daemon's existing graceful shutdown path.
        kill(getpid(), SIGTERM)
        return .terminateCancel
    }
}
