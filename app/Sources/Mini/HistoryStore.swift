import Foundation

struct HistoryPage: Sendable {
    let url: String
    let title: String
    let visitCount: Int
    let lastVisit: Date

    /// The title, or the URL without its scheme when the page has none.
    var displayTitle: String {
        title.isEmpty ? HistoryStore.bare(url) : title
    }
}

/// Mini's browsing history: one row per URL, in `history.sqlite` in the data
/// folder. Chromium keeps its own History file, but CEF has no API for it and
/// holds it locked. Database work runs on a serial queue.
final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore(path: DataDirectory.file("history.sqlite"))

    private let queue = DispatchQueue(label: "dev.sorrycc.mini.history")
    /// Only touched on `queue`. Nil if the file couldn't be opened.
    private let db: SQLiteDatabase?

    init(path: String) {
        do {
            let db = try SQLiteDatabase(path: path)
            try db.execute("""
                PRAGMA journal_mode = WAL;
                CREATE TABLE IF NOT EXISTS pages (
                    url TEXT PRIMARY KEY,
                    title TEXT NOT NULL DEFAULT '',
                    visit_count INTEGER NOT NULL DEFAULT 0,
                    last_visit REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS pages_last_visit ON pages (last_visit DESC);
                """)
            self.db = db
        } catch {
            NSLog("Mini: history unavailable: \(error)")
            db = nil
        }
    }

    /// Counts a visit to `url`, and keeps `title` unless it is empty.
    func recordVisit(url: String, title: String) {
        write("""
            INSERT INTO pages (url, title, visit_count, last_visit) VALUES (?, ?, 1, ?)
            ON CONFLICT (url) DO UPDATE SET
                visit_count = visit_count + 1,
                last_visit = excluded.last_visit,
                title = CASE WHEN excluded.title = '' THEN title ELSE excluded.title END
            """, [url, title, Date().timeIntervalSince1970])
    }

    func setTitle(_ title: String, for url: String) {
        write("UPDATE pages SET title = ? WHERE url = ?", [title, url])
    }

    func clear() {
        write("DELETE FROM pages", [])
    }

    /// Most recently visited first. Blocks until the query finishes, which is
    /// quick for a small `limit`.
    func recent(limit: Int) -> [HistoryPage] {
        queue.sync {
            (try? db?.query(
                "SELECT url, title, visit_count, last_visit FROM pages ORDER BY last_visit DESC LIMIT ?",
                [limit], row: Self.page
            )) ?? []
        }
    }

    /// Pages whose URL or title contains `text`, best first: URLs that start
    /// with it, then titles with a word that starts with it, then the rest,
    /// each by visit count. `completion` runs on the store's queue.
    func search(_ text: String, limit: Int, completion: @escaping @Sendable ([HistoryPage]) -> Void) {
        queue.async { [db] in
            let pattern = "%" + text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_") + "%"
            let pages = (try? db?.query("""
                SELECT url, title, visit_count, last_visit FROM pages
                WHERE url LIKE ?1 ESCAPE '\\' OR title LIKE ?1 ESCAPE '\\'
                ORDER BY visit_count DESC, last_visit DESC LIMIT 300
                """, [pattern], row: Self.page)) ?? []
            let query = text.lowercased()
            let ranked = pages.map { page -> (HistoryPage, Int) in
                if Self.bare(page.url).lowercased().hasPrefix(query) { return (page, 2) }
                let words = page.title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                return (page, words.contains { $0.hasPrefix(query) } ? 1 : 0)
            }
            // A stable sort keeps the query's visit-count order within each rank.
            let best = ranked.enumerated().sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }
            completion(best.prefix(limit).map(\.element.0))
        }
    }

    /// Merges pages from another browser. An existing page keeps its title and
    /// takes the higher visit count and later visit. Reports how many were
    /// merged, on the store's queue.
    func importPages(_ pages: [HistoryPage], completion: @escaping @Sendable (Result<Int, Error>) -> Void) {
        queue.async { [db] in
            guard let db else { return completion(.failure(SQLiteError(description: "history database unavailable"))) }
            completion(Result {
                try db.transaction {
                    for page in pages {
                        try db.run("""
                            INSERT INTO pages (url, title, visit_count, last_visit) VALUES (?, ?, ?, ?)
                            ON CONFLICT (url) DO UPDATE SET
                                visit_count = max(visit_count, excluded.visit_count),
                                last_visit = max(last_visit, excluded.last_visit),
                                title = CASE WHEN title = '' THEN excluded.title ELSE title END
                            """, [page.url, page.title, page.visitCount, page.lastVisit.timeIntervalSince1970])
                    }
                    return pages.count
                }
            })
        }
    }

    private func write(_ sql: String, _ values: [Any?]) {
        // Values are strings and numbers, which are safe to hand to the queue.
        nonisolated(unsafe) let values = values
        queue.async { [db] in
            do {
                try db?.run(sql, values)
            } catch {
                NSLog("Mini: history write failed: \(error)")
            }
        }
    }

    private static func page(_ row: SQLiteDatabase.Row) -> HistoryPage {
        HistoryPage(
            url: row.string(0), title: row.string(1), visitCount: Int(row.int(2)),
            lastVisit: Date(timeIntervalSince1970: row.double(3))
        )
    }

    /// `url` without its scheme and a leading "www.".
    static func bare(_ url: String) -> String {
        var rest = Substring(url)
        if let range = rest.range(of: "://") { rest = rest[range.upperBound...] }
        if rest.hasPrefix("www.") { rest = rest.dropFirst(4) }
        return String(rest)
    }
}
