import AppKit
import Virtualization

let app = NSApplication.shared
let delegate = ConsoleApplicationDelegate()
app.delegate = delegate
app.setActivationPolicy(.prohibited)
let console = Console()
DispatchQueue.main.async {
    do {
        try console.show(nil, name: "console smoke test (no guest)")
        let windows = app.windows.filter { $0.isVisible }
        precondition(windows.count == 1)
        precondition(windows[0].contentView is VZVirtualMachineView)
        try console.show(nil, name: "console smoke test (reused)")
        precondition(app.windows.filter { $0.isVisible }.count == 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            console.close()
            precondition(app.windows.filter { $0.isVisible }.isEmpty)
            precondition(app.activationPolicy() == .prohibited)
            do {
                try console.show(nil, name: "console smoke test (reopened)")
                precondition(app.windows.filter { $0.isVisible }.count == 1)
                console.close()
                print("PASS: console opens, reuses its window, closes without terminating, and reopens")
                exit(0)
            } catch { fputs("\(error)\n", stderr); exit(1) }
        }
    } catch { fputs("\(error)\n", stderr); exit(1) }
}
app.run()
