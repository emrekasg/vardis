import Testing
@testable import VardisStore

@Test func databaseRoundTrip() throws {
    let db = try Database(url: nil)
    try db.execute("CREATE TABLE t(a INTEGER, b TEXT)")
    try db.prepare("INSERT INTO t VALUES(?1, ?2)").run([.int(7), .text("x")])
    let rows = try db.prepare("SELECT a, b FROM t").all { ($0.int(0), $0.text(1)) }
    #expect(rows.count == 1 && rows[0].0 == 7 && rows[0].1 == "x")
}

@Test func fts5IsAvailable() throws {
    let db = try Database(url: nil)
    try db.execute("CREATE VIRTUAL TABLE f USING fts5(body)")
    try db.prepare("INSERT INTO f VALUES(?1)").run([.text("redis EPERM on startup")])
    let n = try db.prepare("SELECT count(*) FROM f WHERE f MATCH ?1").all([.text("eperm")]) { $0.int(0) }
    #expect(n.first == 1)
}
