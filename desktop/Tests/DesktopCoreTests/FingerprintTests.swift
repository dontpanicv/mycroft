import Foundation
import Testing
@testable import DesktopCore

@Suite struct FingerprintTests {
    func digest(_ items: [(String, String, String?)]) -> ScreenFingerprint.Digest {
        var digest = ScreenFingerprint.Digest()
        for (role, label, value) in items { digest.add(role: role, label: label, value: value) }
        return digest
    }

    let base = ScreenFingerprint(pid: 1, window: "Notes", windowFrame: "0,0/800x600", focused: "AXTextArea|Body|Milk",
                                 elementCount: 12, digest: 99)

    @Test func digestIsDeterministic() {
        let items = [("AXButton", "New Note", nil), ("AXTextArea", "Body", "Milk")] as [(String, String, String?)]
        #expect(digest(items).value == digest(items).value)
        #expect(digest(items).count == 2)
        // FNV-1a, so the value is stable across processes and runs.
        #expect(ScreenFingerprint.Digest().value == 0xcbf2_9ce4_8422_2325)
    }

    @Test func digestSeesValuesOrderAndBoundaries() {
        let one = digest([("AXTextArea", "Body", "Milk")]).value
        #expect(one != digest([("AXTextArea", "Body", "Milk and eggs")]).value)
        #expect(one != digest([("AXTextArea", "Body", nil)]).value)
        #expect(digest([("A", "b", nil), ("C", "d", nil)]).value != digest([("C", "d", nil), ("A", "b", nil)]).value)
        #expect(digest([("ab", "c", nil)]).value != digest([("a", "bc", nil)]).value)
        #expect(digest([("A", "", "")]).value != digest([("A", "", nil)]).value)
    }

    @Test func sameScreenIsUnchanged() {
        #expect(!base.differs(from: base))
        #expect(!ScreenFingerprint.empty.differs(from: .empty))
    }

    @Test func eachPartCountsAsAChange() {
        var other = base
        other.pid = 2
        #expect(base.differs(from: other))
        other = base
        other.window = "Groceries"
        #expect(base.differs(from: other))
        other = base
        other.windowFrame = "0,0/400x600"
        #expect(base.differs(from: other))
        other = base
        other.focused = "AXTextArea|Body|Milk, eggs"
        #expect(base.differs(from: other))
        other = base
        other.elementCount = 13
        #expect(base.differs(from: other))
        other = base
        other.digest = 100
        #expect(base.differs(from: other))
        #expect(base.differs(from: .empty))
    }

    @Test func serviceComparesBeforeAndAfter() throws {
        let backend = FakeBackend()
        let service = DesktopService(backend: backend, settleDelay: 0, firstObservation: 1)
        _ = try service.observe(ObserveRequest())
        backend.fingerprints = [base, base, base]
        #expect(try service.act(ActRequest(observation: "o-1", operation: .press, ref: "e1")).screenChanged == false)
        var typed = base
        typed.focused = "AXTextArea|Body|Milk, eggs"
        backend.fingerprints = [base, base, base, typed]
        #expect(try service.act(ActRequest(observation: "o-1", operation: .typeText, ref: "e2", text: ", eggs")).screenChanged == true)
    }

    @Test func serviceWaitsBetweenFingerprints() throws {
        let backend = FakeBackend()
        let service = DesktopService(backend: backend, settleDelay: 0.05, firstObservation: 1)
        _ = try service.observe(ObserveRequest())
        let started = Date()
        _ = try service.act(ActRequest(observation: "o-1", operation: .press, ref: "e1"))
        #expect(Date().timeIntervalSince(started) >= 0.05)
    }
}
