import ApplicationServices
import Testing
@testable import DesktopCore

/// Reads (never acts on) the frontmost app with the real backend. Runs only when this test process is AX-trusted,
/// which it normally is not; it is skipped otherwise. Chromium apps are not asked to expose web content.
@Suite struct RealAXTests {
    @Test(.enabled(if: AXIsProcessTrusted(), "this process is not trusted for Accessibility"))
    func observeFrontmostAppReadOnly() throws {
        let service = DesktopService(backend: AXBackend(pokeChromium: false), settleDelay: 0)
        let observation = try service.observe(ObserveRequest(maxElements: 40))
        #expect(observation.observation.hasPrefix("o-"))
        #expect(!observation.application.isEmpty)
        #expect(observation.elements.count <= 40)
        #expect(observation.elements.enumerated().allSatisfy { $0.element.index == $0.offset + 1 && $0.element.ref == "e\($0.offset + 1)" })
        #expect(observation.available.apps.count <= Available.appsLimit)
        #expect(observation.available.menus.count <= Available.menusLimit)
    }
}
