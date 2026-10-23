import XCTest
import Foundation
@testable import VMCore

final class ShutdownWatchTests: XCTestCase {
    func testDetectsShutdownWithoutDelegateAndCancelsDeadline() {
        let queue = DispatchQueue(label: "shutdown-test")
        let watch = ShutdownWatch()
        let finished = expectation(description: "guest stopped detected")
        let noForce = expectation(description: "no forced power off"); noForce.isInverted = true
        queue.async {
            var stopped = false
            watch.start(on: queue, timeout: 0.2, interval: 0.01,
                        isStopped: { stopped }, stopped: { finished.fulfill() },
                        timedOut: { noForce.fulfill() })
            queue.asyncAfter(deadline: .now() + 0.03) { stopped = true }
        }
        wait(for: [finished, noForce], timeout: 0.4)
    }

    func testStoppedStateWinsAtDeadline() {
        let queue = DispatchQueue(label: "shutdown-test")
        let watch = ShutdownWatch()
        let finished = expectation(description: "already off")
        queue.async {
            watch.start(on: queue, timeout: 0, isStopped: { true },
                        stopped: { finished.fulfill() }, timedOut: { XCTFail("Must not force an already stopped VM") })
        }
        wait(for: [finished], timeout: 1)
    }

    func testTimeoutOnlyOnce() {
        let queue = DispatchQueue(label: "shutdown-test")
        let watch = ShutdownWatch()
        let timedOut = expectation(description: "forced fallback once")
        timedOut.assertForOverFulfill = true
        let settled = expectation(description: "past several subsequent ticks")
        queue.async {
            watch.start(on: queue, timeout: 0.03, interval: 0.005, isStopped: { false },
                        stopped: { XCTFail("Guest is still running") }, timedOut: { timedOut.fulfill() })
            queue.asyncAfter(deadline: .now() + 0.15) { settled.fulfill() }
        }
        wait(for: [timedOut, settled], timeout: 1)
    }

    func testReplacementAndCancellationInvalidateOldTicks() {
        let queue = DispatchQueue(label: "shutdown-test")
        let watch = ShutdownWatch()
        let noCallback = expectation(description: "cancelled generations cannot act"); noCallback.isInverted = true
        queue.async {
            watch.start(on: queue, timeout: 0, isStopped: { true },
                        stopped: { noCallback.fulfill() }, timedOut: { noCallback.fulfill() })
            watch.start(on: queue, timeout: 0, isStopped: { false },
                        stopped: { noCallback.fulfill() }, timedOut: { noCallback.fulfill() })
            watch.cancel()
        }
        wait(for: [noCallback], timeout: 0.2)
    }
}
