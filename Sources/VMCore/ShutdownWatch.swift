import Foundation

/// Runs on the VM's serial queue. Checks completion before timeout so an already
/// stopped guest is never force-stopped. Cancellation also invalidates queued ticks.
public final class ShutdownWatch {
    private var timer: DispatchSourceTimer?
    private var generation = UUID()
    public init() {}

    public func start(on queue: DispatchQueue, timeout: TimeInterval = 30,
                      interval: TimeInterval = 0.1,
                      isStopped: @escaping () -> Bool,
                      stopped: @escaping () -> Void,
                      timedOut: @escaping () -> Void) {
        cancel()
        let token = generation
        let deadline = DispatchTime.now() + timeout
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self, self.generation == token else { return }
            if isStopped() {
                self.cancel(); stopped()
            } else if DispatchTime.now() >= deadline {
                self.cancel(); timedOut()
            }
        }
        self.timer = timer
        timer.resume()
    }

    public func cancel() {
        generation = UUID()
        timer?.cancel(); timer = nil
    }

    deinit { timer?.cancel() }
}
