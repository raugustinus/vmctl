import Foundation
import Darwin
import Virtualization
import AppKit
import VMCore

umask(0o077)
signal(SIGPIPE, SIG_IGN)
// Detach from the invoking terminal; no fork after initializing Virtualization.
_ = setsid()
var retainedLock: Int32 = -1
var retainedServer: Int32 = -1
var supervisor: Supervisor!
var signalSources: [DispatchSourceSignal] = []
let applicationDelegate = ConsoleApplicationDelegate()
do {
    guard CommandLine.arguments.count == 1 else { throw Failure("usage", "vmctld takes no arguments.") }
    let store = try Store()
    let lockURL = store.root.appendingPathComponent("daemon.lock")
    retainedLock = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard retainedLock >= 0 else { throw systemFailure("open daemon lock") }
    try Store.check(lockURL)
    guard flock(retainedLock, LOCK_EX | LOCK_NB) == 0 else { throw Failure("already_running", "Another daemon owns the lock.") }
    // The lock is authoritative. The PID file is diagnostic only and is never used to kill a process.
    let pidURL = store.root.appendingPathComponent("daemon.pid")
    try Store.write(Data("\(getpid())\n".utf8), to: pidURL)
    var st = stat()
    if lstat(store.socketPath, &st) == 0 {
        guard st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFSOCK else { throw Failure("unsafe_socket", "Refusing to replace a non-owned socket path.") }
        guard unlink(store.socketPath) == 0 else { throw systemFailure("unlink stale socket") }
    } else if errno != ENOENT { throw systemFailure("stat socket") }
    retainedServer = try Wire.socket()
    try Wire.address(store.socketPath) { a, n in
        guard bind(retainedServer, a, n) == 0 else { throw systemFailure("bind") }
    }
    guard chmod(store.socketPath, 0o600) == 0, listen(retainedServer, 16) == 0 else { throw systemFailure("listen") }
    supervisor = Supervisor(store: store)
    // Bound connections so a slow local client cannot grow an unlimited thread backlog.
    let slots = DispatchSemaphore(value: 16)
    let responses = DispatchQueue(label: "vmctld.responses", attributes: .concurrent)
    DispatchQueue.global().async {
        while true {
            let fd = accept(retainedServer, nil, nil)
            if fd < 0 { if errno == EINTR { continue }; exit(1) }
            guard slots.wait(timeout: .now()) == .success else { close(fd); continue }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
            Wire.timeout(fd, seconds: 5)
            DispatchQueue.global().async {
                let respond: (Reply) -> Void = { response in
                    responses.async {
                        try? Wire.send(response, to: fd)
                        close(fd); slots.signal()
                    }
                }
                do {
                    try Wire.authenticate(fd)
                    let request = try Wire.receive(Request.self, from: fd, limit: 8192)
                    DispatchQueue.main.async { supervisor.handle(request, reply: respond) }
                } catch { respond(Reply(error: Failure.wrapping(error))) }
            }
        }
    }
    for number in [SIGTERM, SIGINT, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            // Installation cannot safely be paused/stopped. Defer orderly daemon exit.
            guard supervisor.phase != "installing", supervisor.phase != "starting" else {
                if let name = supervisor.activeName { supervisor.log(name, "daemon_exit_deferred") }
                return
            }
            let finish: (Reply) -> Void = { reply in
                guard reply.error == nil else { return }
                unlink(store.socketPath); unlink(pidURL.path); exit(0)
            }
            if let name = supervisor.activeName, supervisor.machine != nil {
                supervisor.handle(Request(command: "stop", name: name), reply: finish)
            } else { finish(Reply(value: "stopped")) }
        }
        source.resume(); signalSources.append(source)
    }
    if Console.hasDesktopSession {
        // AppKit keeps the actual main thread alive for both VZ and UI events.
        let app = NSApplication.shared
        // Hidden state is accessory, not prohibited: a LaunchServices-launched app
        // cannot switch from prohibited back to regular when the console opens.
        app.setActivationPolicy(.accessory)
        app.delegate = applicationDelegate
        app.run()
    } else {
        // VM lifecycle remains available without an interactive desktop.
        dispatchMain()
    }
} catch {
    fputs("\(Failure.wrapping(error))\n", stderr)
    exit(1)
}
