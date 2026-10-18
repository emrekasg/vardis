import Testing
@testable import VardisSampling

struct SampleSystemTests {
    @Test func cheapTickCarriesAppsFromLastFullSample() async {
        let sampler = Sampler()
        let before = await sampler.sampleSystem()
        #expect(before.apps.isEmpty)
        #expect(before.memory.total > 0)
        let full = await sampler.sample()
        let cheap = await sampler.sampleSystem()
        #expect(cheap.apps.map(\.id) == full.apps.map(\.id))
        #expect(cheap.processCount == full.processCount)
        #expect(cheap.timestamp >= full.timestamp)
    }

    @Test func cheapTickIsMuchCheaperThanFull() async {
        let sampler = Sampler()
        _ = await sampler.sample()
        let clock = ContinuousClock()
        let fullTime = await clock.measure { _ = await sampler.sample() }
        let cheapTime = await clock.measure { _ = await sampler.sampleSystem() }
        #expect(cheapTime * 5 < fullTime)
    }
}
