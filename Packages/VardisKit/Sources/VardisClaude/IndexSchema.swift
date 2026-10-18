import Foundation
import VardisStore

enum IndexSchema {
    static let version = 2

    static func migrate(_ db: Database) throws {
        var current = 0
        try db.prepare("PRAGMA user_version").query { current = Int($0.int(0)); return false }
        if current == version { return }
        if current != 0 {
            // Derived data only: rebuild from the transcripts.
            for t in ["files", "sessions", "usage_events", "usage_slots", "turns", "fts"] { try db.execute("DROP TABLE IF EXISTS \(t)") }
        }
        try db.execute("""
        CREATE TABLE IF NOT EXISTS files(
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            home TEXT NOT NULL,
            session_id TEXT NOT NULL,
            offset INTEGER NOT NULL,
            size INTEGER NOT NULL,
            mtime REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sessions(
            id TEXT PRIMARY KEY,
            home TEXT NOT NULL,
            project_path TEXT,
            project_slug TEXT,
            git_branch TEXT,
            title TEXT,
            title_kind INTEGER NOT NULL DEFAULT 0,
            first_prompt TEXT,
            started_at REAL,
            last_activity_at REAL,
            user_prompts INTEGER NOT NULL DEFAULT 0,
            message_count INTEGER NOT NULL DEFAULT 0,
            tool_calls INTEGER NOT NULL DEFAULT 0,
            failed_tool_calls INTEGER NOT NULL DEFAULT 0,
            input INTEGER NOT NULL DEFAULT 0,
            output INTEGER NOT NULL DEFAULT 0,
            cache_creation INTEGER NOT NULL DEFAULT 0,
            cache_read INTEGER NOT NULL DEFAULT 0,
            cost_usd REAL NOT NULL DEFAULT 0,
            has_unpriced INTEGER NOT NULL DEFAULT 0,
            model TEXT
        );
        CREATE INDEX IF NOT EXISTS sessions_activity ON sessions(last_activity_at DESC);
        CREATE INDEX IF NOT EXISTS sessions_project ON sessions(project_path, last_activity_at DESC);
        CREATE TABLE IF NOT EXISTS usage_events(
            key TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            ts REAL NOT NULL,
            model TEXT NOT NULL,
            input INTEGER NOT NULL,
            output INTEGER NOT NULL,
            cache_creation INTEGER NOT NULL,
            cache_creation_1h INTEGER NOT NULL,
            cache_read INTEGER NOT NULL,
            cost REAL NOT NULL,
            priced INTEGER NOT NULL,
            sidechain INTEGER NOT NULL
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS usage_session_ts ON usage_events(session_id, ts);
        -- Usage pre-aggregated per 15-minute slot, session and model; what charts and session totals read.
        CREATE TABLE IF NOT EXISTS usage_slots(
            slot INTEGER NOT NULL,
            session_id TEXT NOT NULL,
            model TEXT NOT NULL,
            messages INTEGER NOT NULL,
            main_messages INTEGER NOT NULL,
            unpriced INTEGER NOT NULL,
            input INTEGER NOT NULL,
            output INTEGER NOT NULL,
            cache_creation INTEGER NOT NULL,
            cache_creation_1h INTEGER NOT NULL,
            cache_read INTEGER NOT NULL,
            cost REAL NOT NULL,
            PRIMARY KEY(slot, session_id, model)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS usage_slots_session ON usage_slots(session_id);
        CREATE TABLE IF NOT EXISTS turns(
            session_id TEXT NOT NULL,
            idx INTEGER NOT NULL,
            file_id INTEGER NOT NULL,
            ts REAL,
            prompt TEXT NOT NULL,
            steps INTEGER NOT NULL,
            failures INTEGER NOT NULL,
            files TEXT NOT NULL,
            reply TEXT,
            last_msg TEXT,
            PRIMARY KEY(session_id, idx)
        ) WITHOUT ROWID;
        CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(
            text, session_id UNINDEXED, role UNINDEXED, ts UNINDEXED, file_id UNINDEXED,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        PRAGMA user_version = \(version);
        """)
    }
}
