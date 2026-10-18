import Foundation

/// Docker objects nobody has used in a while, read from `docker system df -v --format json` plus
/// batched `inspect` calls for the dates df does not print. Every item is removed by the Docker
/// CLI, permanently; nothing here ever goes through the Trash.
enum DockerScan {
    struct DF: Decodable {
        struct Image: Decodable {
            var Containers: String?
            var CreatedAt: String?
            var Digest: String?
            var ID: String
            var Repository: String?
            var Tag: String?
            var Size: String?
            var UniqueSize: String?
        }
        struct Container: Decodable {
            var ID: String
            var Names: String?
            var Image: String?
            var State: String?
            var Status: String?
            var Size: String?
            var CreatedAt: String?
        }
        struct Volume: Decodable {
            var Name: String
            var Links: String?
            var Size: String?
            var Labels: String?
        }
        struct Cache: Decodable {
            var ID: String?
            var InUse: String?
            var Shared: String?
            var Size: String?
            var LastUsedAt: String?
            var CreatedAt: String?
        }
        var Images: [Image]?
        var Containers: [Container]?
        var Volumes: [Volume]?
        var BuildCache: [Cache]?
    }

    static func items(runner: any DockerRunner, now: Date, cacheAgeDays: Int, enabled: Set<CleanupCategory>) async -> [CleanupItem] {
        guard let df = await runner.docker(["system", "df", "-v", "--format", "json"], timeout: 90), df.status == 0,
              let parsed = parse(df.stdout)
        else { return [] }
        let stopped = (parsed.Containers ?? []).filter { isStopped($0.State) }
        let unusedImages = (parsed.Images ?? []).filter { ($0.Containers ?? "") == "0" }
        let unusedVolumes = (parsed.Volumes ?? []).filter { ($0.Links ?? "") == "0" }

        // The dates df does not print, one batched call per kind.
        async let finished: [String: Date] = enabled.contains(.dockerContainers) && !stopped.isEmpty
            ? inspectDates(runner, ["inspect", "--format", "{{.Id}} {{.State.FinishedAt}}"] + stopped.map(\.ID)) : [:]
        async let tagged: [String: Date] = enabled.contains(.dockerImages) && !unusedImages.isEmpty
            ? inspectDates(runner, ["image", "inspect", "--format", "{{.Id}} {{.Metadata.LastTagTime}}"] + Array(Set(unusedImages.map(\.ID))).sorted()) : [:]
        async let created: [String: Date] = enabled.contains(.dockerVolumes) && !unusedVolumes.isEmpty
            ? inspectDates(runner, ["volume", "inspect", "--format", "{{.Name}} {{.CreatedAt}}"] + unusedVolumes.map(\.Name)) : [:]

        var out: [CleanupItem] = []
        if enabled.contains(.dockerImages) { out += images(unusedImages, lastTag: await tagged, now: now) }
        if enabled.contains(.dockerContainers) { out += containers(stopped, finished: await finished, now: now) }
        if enabled.contains(.dockerVolumes) { out += volumes(unusedVolumes, created: await created, now: now) }
        if enabled.contains(.dockerBuildCache) { out += buildCache(parsed.BuildCache ?? [], now: now, ageDays: cacheAgeDays) }
        return out.filter { $0.sizeBytes > 0 }
    }

    static func parse(_ data: Data) -> DF? {
        if let d = try? JSONDecoder().decode(DF.self, from: data) { return d }
        // Some versions print one object per line.
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            if let d = try? JSONDecoder().decode(DF.self, from: Data(line)) { return d }
        }
        return nil
    }

    static func isStopped(_ state: String?) -> Bool {
        switch (state ?? "").lowercased() {
        case "exited", "created", "dead": true
        default: false
        }
    }

    // MARK: Kinds

    static func images(_ rows: [DF.Image], lastTag: [String: Date], now: Date) -> [CleanupItem] {
        // One item per image id; every tag is removed together.
        var byID: [String: [DF.Image]] = [:]
        for r in rows { byID[r.ID, default: []].append(r) }
        return byID.sorted { $0.key < $1.key }.map { id, tags in
            let named = tags.compactMap { t -> String? in
                guard let repo = t.Repository, repo != "<none>", let tag = t.Tag, tag != "<none>" else { return nil }
                return "\(repo):\(tag)"
            }
            let first = tags[0]
            let dangling = named.isEmpty
            let createdAt = first.CreatedAt.flatMap(parseGoDate)
            let used = [createdAt, lastTag[id]].compactMap { $0 }.max()
            let unique = first.UniqueSize.flatMap { $0 == "N/A" ? nil : DockerParser.parseSize($0) }
            let size = unique ?? DockerParser.parseSize(first.Size ?? "0B")
            let short = shortID(id)
            let digest = (first.Digest ?? "").trimmingCharacters(in: .whitespaces)
            let pulled = !digest.isEmpty && digest != "<none>"
            var detail = dangling ? "Untagged, no container uses it" : "No container uses it"
            if let used { detail += " · not used for \(days(since: used, now: now)) days" }
            return CleanupItem(
                id: "docker-image:" + id, category: .dockerImages,
                title: dangling ? "Untagged image \(short)" : named.joined(separator: ", "),
                detail: detail, urls: [], sizeBytes: size, lastUsed: used,
                safety: pulled ? .redownloads : .rebuildable, selectedByDefault: dangling,
                docker: DockerRef(kind: .image, refs: dangling ? [id] : named),
                sizeIsUpperBound: unique == nil ? true : nil)
        }
    }

    static func containers(_ rows: [DF.Container], finished: [String: Date], now: Date) -> [CleanupItem] {
        rows.map { c in
            let created = c.CreatedAt.flatMap(parseGoDate)
            let ended = finished.first { $0.key.hasPrefix(c.ID) || c.ID.hasPrefix($0.key) }?.value
            let used = ended ?? created
            var detail = c.Image ?? ""
            if let used { detail += (detail.isEmpty ? "" : " · ") + "not run for \(days(since: used, now: now)) days" }
            let size = DockerParser.parseSize((c.Size ?? "0B").components(separatedBy: " (").first ?? "0B")
            return CleanupItem(
                id: "docker-container:" + c.ID, category: .dockerContainers,
                title: c.Names ?? shortID(c.ID), detail: detail, urls: [],
                // A stopped container with no writable data still holds its image; count at least a block.
                sizeBytes: max(size, 4_096), lastUsed: used, safety: .reviewFirst, selectedByDefault: false,
                docker: DockerRef(kind: .container, refs: [c.ID]))
        }
    }

    static func volumes(_ rows: [DF.Volume], created: [String: Date], now: Date) -> [CleanupItem] {
        rows.map { v in
            let anonymous = v.Name.count == 64 && v.Name.allSatisfy(\.isHexDigit)
            var detail = "No container uses it · may hold a database"
            if let c = created[v.Name] { detail = "Created \(days(since: c, now: now)) days ago · " + detail }
            return CleanupItem(
                id: "docker-volume:" + v.Name, category: .dockerVolumes,
                title: anonymous ? "Anonymous volume \(String(v.Name.prefix(12)))" : v.Name,
                detail: detail, urls: [], sizeBytes: DockerParser.parseSize(v.Size ?? "0B"), lastUsed: nil,
                safety: .notRebuildable, selectedByDefault: false,
                docker: DockerRef(kind: .volume, refs: [v.Name]))
        }
    }

    /// Two items: cache unused for `ageDays` (preselected) and the rest of the unused cache.
    static func buildCache(_ rows: [DF.Cache], now: Date, ageDays: Int) -> [CleanupItem] {
        let cutoff = now.addingTimeInterval(-Double(ageDays) * 86_400)
        var oldBytes: UInt64 = 0, newBytes: UInt64 = 0
        var oldNewest: Date?, newNewest: Date?
        var oldCount = 0, newCount = 0
        for r in rows where (r.InUse ?? "false") != "true" {
            let size = DockerParser.parseSize(r.Size ?? "0B")
            let used = (r.LastUsedAt.flatMap(parseGoDate)) ?? r.CreatedAt.flatMap(parseGoDate)
            if let used, used < cutoff {
                oldBytes += size; oldCount += 1
                oldNewest = max(oldNewest ?? used, used)
            } else {
                newBytes += size; newCount += 1
                if let used { newNewest = max(newNewest ?? used, used) }
            }
        }
        var out: [CleanupItem] = []
        out.append(CleanupItem(
            id: "docker-buildcache:old", category: .dockerBuildCache, title: "Not used in \(ageDays) days",
            detail: "\(oldCount) cache entries · the next build makes them again", urls: [], sizeBytes: oldBytes, lastUsed: oldNewest,
            safety: .rebuildable, selectedByDefault: true,
            docker: DockerRef(kind: .buildCache, refs: [], untilHours: ageDays * 24), sizeIsUpperBound: true))
        out.append(CleanupItem(
            id: "docker-buildcache:recent", category: .dockerBuildCache, title: "Used in the last \(ageDays) days",
            detail: "\(newCount) cache entries · removing them makes the next build slower", urls: [], sizeBytes: newBytes, lastUsed: newNewest,
            safety: .rebuildable, selectedByDefault: false,
            docker: DockerRef(kind: .buildCache, refs: []), sizeIsUpperBound: true))
        return out
    }

    // MARK: Removal

    /// Removes Docker items in a safe order: containers, then images, volumes and build cache.
    /// Pruning all cache also removes the old cache, so only one prune runs.
    static func remove(_ items: [CleanupItem], runner: any DockerRunner, into result: inout TrashResult) async {
        let order: [DockerRef.Kind] = [.container, .image, .volume, .buildCache]
        var list = items.filter { $0.docker != nil }.sorted { a, b in
            (order.firstIndex(of: a.docker!.kind) ?? 0) < (order.firstIndex(of: b.docker!.kind) ?? 0)
        }
        let isFullPrune: (CleanupItem) -> Bool = { $0.docker?.kind == .buildCache && $0.docker?.untilHours == nil }
        var covered: [CleanupItem] = []
        if list.contains(where: isFullPrune) {
            covered = list.filter { $0.docker?.kind == .buildCache && !isFullPrune($0) }
            list.removeAll { $0.docker?.kind == .buildCache && !isFullPrune($0) }
        }
        for item in list {
            guard let ref = item.docker else { continue }
            guard let out = await runner.docker(ref.arguments, timeout: 120) else {
                result.failures.append(.init(itemID: item.id, url: nil, reason: "Docker is not installed or not running"))
                continue
            }
            if out.status == 0 {
                record(item, &result)
                if isFullPrune(item) { for c in covered { record(c, &result) } }
            } else {
                let msg = out.stderr.split(separator: "\n").first.map(String.init) ?? "Docker refused (exit \(out.status))"
                result.failures.append(.init(itemID: item.id, url: nil, reason: msg))
            }
        }
    }

    private static func record(_ item: CleanupItem, _ result: inout TrashResult) {
        result.moved += 1
        result.permanentlyRemoved += 1
        result.movedIDs.append(item.id)
        result.bytes += item.sizeBytes
    }

    // MARK: Helpers

    static func inspectDates(_ runner: any DockerRunner, _ args: [String]) async -> [String: Date] {
        guard let out = await runner.docker(args, timeout: 60) else { return [:] }
        // `inspect` exits non-zero if one object vanished, but still prints the others.
        var map: [String: Date] = [:]
        for line in String(decoding: out.stdout, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let d = parseISO(parts[1]) ?? parseGoDate(parts[1]) else { continue }
            map[parts[0]] = d
        }
        return map
    }

    static func shortID(_ id: String) -> String {
        let hex = id.hasPrefix("sha256:") ? String(id.dropFirst(7)) : id
        return String(hex.prefix(12))
    }

    static func days(since d: Date, now: Date) -> Int { max(0, Int(now.timeIntervalSince(d) / 86_400)) }

    /// RFC 3339, with or without fractional seconds. Go's zero time (year 1) is nil.
    static func parseISO(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("0001-") else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: t) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: t)
    }

    /// Go's default time format: "2026-10-16 21:23:30.123 +0300 +03" or "… +0000 UTC".
    static func parseGoDate(_ s: String) -> Date? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        guard parts.count >= 3, !parts[0].hasPrefix("0001-") else { return nil }
        let time = parts[1].split(separator: ".").first.map(String.init) ?? parts[1]
        let off = parts[2]
        guard off.count == 5, let sign = off.first, sign == "+" || sign == "-" else { return nil }
        let iso = "\(parts[0])T\(time)\(off.prefix(3)):\(off.suffix(2))"
        return parseISO(iso)
    }
}
