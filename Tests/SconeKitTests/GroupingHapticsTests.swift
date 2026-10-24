import Foundation
import Testing
@testable import SconeStore
@testable import SconeUI

struct GroupingHapticsTests {
    @Test func everyGroupingEventMapsToItsLevel() {
        let expected: [GroupingEvent: GroupingHaptic] = [
            .pickedUp: .tick,
            .reachedTarget: .tick,
            .setDown: .tick,
            .command(.sent): .snap,
            .command(.grouped): .joined,
            .command(.ungrouped): .split,
            .command(.failed): .failed,
        ]
        let actual = Dictionary(uniqueKeysWithValues: expected.keys.map { ($0, $0.haptic) })
        #expect(actual == expected)
    }

    @Test func iPhoneHapticsEscalateFromTickToJoined() {
        func totalIntensity(_ haptic: GroupingHaptic) -> Float {
            haptic.pulses.reduce(0) { $0 + $1.intensity }
        }
        let tick = totalIntensity(.tick)
        let snap = totalIntensity(.snap)
        let joined = totalIntensity(.joined)
        let split = totalIntensity(.split)
        #expect(tick < snap)
        #expect(snap < joined)
        #expect(joined == split)
        let joinedPulses = GroupingHaptic.joined.pulses
        let splitPulses = GroupingHaptic.split.pulses
        #expect(joinedPulses != splitPulses)
        let failedBeats = GroupingHaptic.failed.pulses.count
        let otherBeats = GroupingHaptic.allCases.filter { $0 != .failed }.map(\.pulses.count)
        #expect(otherBeats.allSatisfy { $0 < failedBeats })
    }

    #if os(macOS)
    @Test func trackpadHapticsKeepTheHierarchy() {
        let beats = GroupingHaptic.allCases.map(\.trackpadPulses.count)
        #expect(beats.allSatisfy { $0 > 0 })
        let joined = GroupingHaptic.joined.trackpadPulses
        let split = GroupingHaptic.split.trackpadPulses
        #expect(joined != split)
        let failedBeats = GroupingHaptic.failed.trackpadPulses.count
        #expect(failedBeats > joined.count)
    }
    #endif

    @Test func tickGateKeepsTicksFromStuttering() {
        var gate = TickGate()
        let t0 = ContinuousClock.now
        func at(_ milliseconds: Int) -> ContinuousClock.Instant { t0.advanced(by: .milliseconds(milliseconds)) }
        let kitchen = AnyHashable("kitchen")
        let dining = AnyHashable("dining")

        let fresh = gate.allows(target: nil, at: at(0))
        #expect(fresh)
        let tooSoon = gate.allows(target: kitchen, at: at(50))
        #expect(!tooSoon)
        let otherTarget = gate.allows(target: dining, at: at(150))
        #expect(otherTarget)

        let jitter = [300, 600, 900].map { gate.allows(target: dining, at: at($0)) }
        #expect(jitter == [false, false, false])
        let afterQuiet = gate.allows(target: dining, at: at(1_400))
        #expect(afterQuiet)

        var unreset = gate
        let sameTargetWithoutReset = unreset.allows(target: dining, at: at(1_550))
        #expect(!sameTargetWithoutReset)
        gate.reset()
        let sameTargetAfterReset = gate.allows(target: dining, at: at(1_550))
        #expect(sameTargetAfterReset)
    }
}
