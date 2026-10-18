import CoreServices
import Foundation

/// FSEvents on a set of folders, directory-level events only (no per-file events), coalesced
/// over `latency` seconds. Events caused by this process (moving items to the Trash) are ignored.
public final class FileWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable ([ChangedPath]) -> Void

    private let paths: [String]
    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "app.vardis.cleanup.fsevents", qos: .utility)
    private let handler: Handler
    private var stream: FSEventStreamRef?

    public init(paths: [String], latency: TimeInterval = 5, handler: @escaping Handler) {
        self.paths = paths
        self.latency = latency
        self.handler = handler
    }

    deinit { stop() }

    public func start() {
        queue.sync {
            guard stream == nil, !paths.isEmpty else { return }
            var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagIgnoreSelf | kFSEventStreamCreateFlagWatchRoot)
            guard let s = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
                guard let info else { return }
                let me = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
                let list = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                var out: [ChangedPath] = []
                for i in 0..<count {
                    var p = String(cString: list[i])
                    while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
                    let f = Int(flags[i])
                    let recursive = f & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                        | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0
                    out.append(ChangedPath(path: p, recursive: recursive))
                }
                me.handler(out)
            }, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
            stream = s
        }
    }

    public func stop() {
        let s = stream
        stream = nil
        guard let s else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }
}
