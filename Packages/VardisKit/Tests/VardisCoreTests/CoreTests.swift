import Testing
@testable import VardisCore

@Test func ringBufferKeepsNewestInOrder() {
    var r = RingBuffer<Int>(capacity: 3, filler: 0)
    for i in 1...5 { r.append(i) }
    #expect(r.elements == [3, 4, 5])
    #expect(r.last == 5)
    #expect(r.count == 3)
}

@Test func formatsNumbers() {
    #expect(Fmt.bytes(21_400_000_000) == "21.4 GB")
    #expect(Fmt.bytes(512) == "512 B")
    #expect(Fmt.percent(0.183) == "18%")
    #expect(Fmt.percent(0.0006) == "0.1%")
    #expect(Fmt.duration(7_560) == "2 h 6 m")
    #expect(Fmt.tokens(4_100_000) == "4.1M")
    #expect(Fmt.tokens(412_000) == "412k")
    #expect(Fmt.usd(6.4) == "$6.40")
    #expect(Fmt.usd(9666) == "$9,666")
    #expect(Fmt.tokens(28_420_400_000) == "28.4B")
}
