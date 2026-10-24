import AppKit
import AccessoryAccess
import Virtualization
import Security
import VMCore

/// Main-queue state; AccessoryAccess callbacks are marshalled from its own queue.
@available(macOS 27.0, *)
final class USBPassthrough: NSObject, AAUSBAccessoryListener, @unchecked Sendable {
    private weak var machine: VZVirtualMachine?
    private var generation = UUID()
    private var enabled = false
    private var registering = false
    private var disabling = false
    private var pending: Set<UInt64> = []
    private var disconnected: Set<UInt64> = []
    private var devices: [UInt64: VZUSBPassthroughDevice] = [:]
    private var failure: Failure?
    private var log: (String, Error?) -> Void = { _, _ in }
    var keepVisible: ((Bool) -> Void)?

    func start(machine: VZVirtualMachine, log: @escaping (String, Error?) -> Void,
               reply: @escaping (Reply) -> Void) throws {
        guard !registering, !disabling else { throw Failure("usb_busy", "USB setup/cleanup is still in progress.") }
        if enabled { reply(Reply(value: status)); return }
        guard Console.hasDesktopSession, Thread.isMainThread,
              Bundle.main.bundleURL.pathExtension == "app" else {
            throw Failure("usb_app_required", "Run the experimental VMControlUSB.app supervisor from your desktop session. See docs/USB-PASSTHROUGH.md.")
        }
        guard let task = SecTaskCreateFromSelf(nil),
              SecTaskCopyValueForEntitlement(task, "com.apple.developer.accessory-access.usb" as CFString, nil) as? Bool == true else {
            throw Failure("usb_entitlement_required", "This build needs an Accessory Access signing profile. Build with build-usb.sh; see docs/USB-PASSTHROUGH.md.")
        }
        guard !machine.usbControllers.isEmpty else { throw Failure("usb_controller_missing", "Restart the VM with this version to add its USB controller.") }
        // Apple's sample registers with no criteria so the system menu offers every
        // USB device. The user still chooses explicitly which one to assign; the
        // dictionary initializers return nil on macOS 27 and a vendor-only filter
        // built through the Swift overlay never produced a match for an iPhone.
        self.machine = machine; self.log = log; failure = nil
        enabled = true; registering = true; generation = UUID()
        let token = generation
        keepVisible?(true)
        // Capture self until registration completes, even if the VM stops meanwhile.
        AAUSBAccessoryManager.shared.registerListener(self, matchingCriteria: []) { accessories, error in
            DispatchQueue.main.async {
                self.registering = false
                guard self.generation == token, self.enabled else {
                    if error == nil {
                        self.disabling = true
                        AAUSBAccessoryManager.shared.unregisterListener(self) {
                            DispatchQueue.main.async { self.disabling = false }
                        }
                    }
                    reply(Reply(error: Failure("usb_cancelled", "VM stopped during USB registration.")))
                    return
                }
                if let error {
                    self.enabled = false; self.machine = nil; self.keepVisible?(false)
                    self.record(error, event: "usb_registration_failed")
                    reply(Reply(error: self.failure)); return
                }
                accessories.forEach { self.attach($0) }
                self.log("usb_enabled", nil)
                reply(Reply(value: "USB enabled. Connect the device; then assign it to VMControl USB from the Virtual Machine Accessories menu bar item. Check vmctl usb status for attachment results."))
            }
        }
    }

    var status: String {
        var lines = ["\(disabling ? "disabling" : (registering ? "registering" : (enabled ? "enabled" : "disabled")))"]
        lines += devices.keys.sorted().map { "attached registry-id=\($0)" }
        lines += pending.sorted().map { "attaching registry-id=\($0)" }
        if let failure { lines.append(failure.description) }
        return lines.joined(separator: "\n")
    }

    func usbAccessoryDidConnect(_ accessory: AAUSBAccessory) {
        DispatchQueue.main.async { self.attach(accessory) }
    }
    func usbAccessoryDidDisconnect(_ accessory: AAUSBAccessory) {
        DispatchQueue.main.async {
            // VZ automatically detaches a physically disconnected device. Keep
            // pending IDs until their completion to avoid duplicate hot-plug work.
            if self.pending.contains(accessory.registryID) { self.disconnected.insert(accessory.registryID) }
            if self.devices.removeValue(forKey: accessory.registryID) != nil {
                self.log("usb_disconnected", nil)
            }
        }
    }

    private func attach(_ accessory: AAUSBAccessory) {
        guard enabled, !disabling, let machine, machine.state == .running,
              let controller = machine.usbControllers.first else { return }
        let id = accessory.registryID
        guard devices[id] == nil, !pending.contains(id) else { return }
        let token = generation
        let device: VZUSBPassthroughDevice
        do { device = try VZUSBPassthroughDevice(configuration: VZUSBPassthroughDeviceConfiguration(device: accessory)) }
        catch { record(error, event: "usb_device_init_failed"); return }
        pending.insert(id)
        controller.attach(device: device) { error in
            guard self.enabled, self.generation == token else {
                if error == nil { controller.detach(device: device) { _ in } }
                return
            }
            self.pending.remove(id)
            if self.disconnected.remove(id) != nil {
                if error == nil, device.usbController != nil { controller.detach(device: device) { _ in } }
                return
            }
            if let error { self.record(error, event: "usb_attach_failed") }
            else if device.usbController != nil {
                self.devices[id] = device
                self.failure = nil
                self.log("usb_attached", nil)
            }
        }
    }

    func disable(reply: @escaping (Reply) -> Void) throws {
        guard !registering, !disabling, pending.isEmpty else {
            throw Failure("usb_busy", "Wait for the current USB operation, then retry usb off.")
        }
        guard enabled else { reply(Reply(value: "disabled")); return }
        // Keep the session active until all explicit detaches succeed.
        disabling = true
        let group = DispatchGroup()
        var detachError: Error?
        for (id, device) in Array(devices) {
            guard let controller = device.usbController else { devices.removeValue(forKey: id); continue }
            group.enter()
            controller.detach(device: device) { error in
                if let error { detachError = error } else { self.devices.removeValue(forKey: id) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if let error = detachError {
                self.disabling = false; self.record(error, event: "usb_detach_failed")
                reply(Reply(error: self.failure)); return
            }
            self.enabled = false; self.generation = UUID()
            AAUSBAccessoryManager.shared.unregisterListener(self) {
                DispatchQueue.main.async {
                    self.disabling = false; self.machine = nil; self.keepVisible?(false)
                    self.log("usb_disabled", nil); reply(Reply(value: "disabled"))
                }
            }
        }
    }

    /// Called after VZ stops. The VM has already released its USB controller.
    func machineStopped() {
        enabled = false; generation = UUID(); machine = nil
        devices.removeAll(); pending.removeAll(); disconnected.removeAll()
        keepVisible?(false)
        if !registering, !disabling {
            disabling = true
            AAUSBAccessoryManager.shared.unregisterListener(self) {
                DispatchQueue.main.async { self.disabling = false }
            }
        }
    }
    private func record(_ error: Error, event: String) {
        // Framework USB errors carry their real cause in userInfo, not localizedDescription.
        let nsError = error as NSError
        var detail = Failure.wrapping(error).description
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            detail += " underlying=\(underlying.domain).\(underlying.code) \(underlying.localizedDescription)"
        }
        let extra = nsError.userInfo.filter { $0.key != NSUnderlyingErrorKey && $0.key != NSLocalizedDescriptionKey }
        if !extra.isEmpty { detail += " userInfo=\(extra)" }
        failure = Failure(nsError.domain + "." + String(nsError.code), detail); log(event, failure)
    }
}
