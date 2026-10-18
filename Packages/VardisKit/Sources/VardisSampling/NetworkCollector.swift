import Darwin
import VardisCore

/// Total traffic over non-loopback interfaces from `getifaddrs` link-layer counters.
final class NetworkCollector {
    /// Per interface index: last raw 32-bit counters and the 64-bit totals extended from them.
    private struct Counters {
        var rawIn: UInt32
        var rawOut: UInt32
        var totalIn: UInt64
        var totalOut: UInt64
        var generation: UInt64
    }

    private var interfaces: [UInt16: Counters] = [:]
    private var lastIn: UInt64 = 0
    private var lastOut: UInt64 = 0
    private var lastNanos: UInt64 = 0
    private var generation: UInt64 = 0

    /// Bytes moved between two readings of a 32-bit counter that may have wrapped once.
    @inline(__always) static func counterDelta(previous: UInt32, current: UInt32) -> UInt64 {
        UInt64(current &- previous)
    }

    func sample(now: UInt64) -> NetworkSample {
        generation &+= 1
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return NetworkSample(receivedBytesPerSecond: 0, sentBytesPerSecond: 0, receivedTotal: lastIn, sentTotal: lastOut) }
        defer { freeifaddrs(head) }

        var cursor = head
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  ifa.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let data = ifa.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            let index = addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee.sdl_index }
            let rawIn = data.pointee.ifi_ibytes, rawOut = data.pointee.ifi_obytes
            if var c = interfaces[index] {
                c.totalIn &+= Self.counterDelta(previous: c.rawIn, current: rawIn)
                c.totalOut &+= Self.counterDelta(previous: c.rawOut, current: rawOut)
                c.rawIn = rawIn
                c.rawOut = rawOut
                c.generation = generation
                interfaces[index] = c
            } else {
                interfaces[index] = Counters(rawIn: rawIn, rawOut: rawOut, totalIn: UInt64(rawIn), totalOut: UInt64(rawOut), generation: generation)
            }
        }

        var totalIn: UInt64 = 0, totalOut: UInt64 = 0
        var gone = false
        for c in interfaces.values {
            if c.generation == generation { totalIn &+= c.totalIn; totalOut &+= c.totalOut } else { gone = true }
        }
        if gone { interfaces = interfaces.filter { $0.value.generation == generation } }

        var inRate = 0.0, outRate = 0.0
        if lastNanos != 0, now > lastNanos {
            let seconds = Double(now - lastNanos) / 1e9
            inRate = Double(totalIn >= lastIn ? totalIn - lastIn : 0) / seconds
            outRate = Double(totalOut >= lastOut ? totalOut - lastOut : 0) / seconds
        }
        lastIn = totalIn
        lastOut = totalOut
        lastNanos = now
        return NetworkSample(receivedBytesPerSecond: inRate, sentBytesPerSecond: outRate, receivedTotal: totalIn, sentTotal: totalOut)
    }
}
