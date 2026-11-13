import Foundation
import Testing
@testable import out_of_space_swiftly

/// `Blocking.run`: the answer of a call that returns, and giving up on one that doesn't. As in
/// `VolumesTests` there is no clock in the expectations: the call that hangs is released by the test.
struct BlockingTests {
    @Test func givesTheAnswerOfACallThatReturns() async {
        let answer = await Blocking.run("Test", timeout: .seconds(60)) { 6 * 7 }
        #expect(answer == 42)
    }

    @Test func withoutATimeoutItWaitsForTheAnswer() async {
        let answer = await Blocking.run("Test") { 6 * 7 }
        #expect(answer == 42)
    }

    @Test func givesUpOnACallThatTakesTooLong() async {
        let release = DispatchSemaphore(value: 0)
        let gaveUp = Flag()
        defer { release.signal() }
        let answer = await Blocking.run("Test", timeout: .milliseconds(200)) {
            if release.wait(timeout: .now() + 30) == .timedOut { gaveUp.set() }
            return 42
        }
        #expect(answer == nil)
        #expect(gaveUp.isSet == false, "run returned only after the call had")
    }

    @MainActor @Test func runsTheCallOffTheMainThread() async {
        #expect(pthread_main_np() != 0)
        let wasOnMainThread = await Blocking.run("Test", timeout: .seconds(60)) { pthread_main_np() != 0 }
        #expect(wasOnMainThread == false)
    }
}
