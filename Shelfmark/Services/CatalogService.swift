import Foundation

/// A bibliographic record assembled from the Library of Congress and Open Library.
struct CatalogRecord: Sendable {
    var title: String = ""
    var authors: [String] = []
    var publisher: String = ""
    var year: String = ""
    var isbn: String = ""
    var lccn: String = ""
    var lcCallNumber: String = ""
    var subjects: [String] = []
    var sources: [String] = []

    var lcClass: String { LCCallNumber.classLetters(lcCallNumber) }
    var isComplete: Bool { !lcCallNumber.isEmpty && !title.isEmpty }
}

/// Looks up Library of Congress cataloging data for a title/author read from a spine.
///
/// Strategy:
/// 1. Open Library search (fast, tolerant of partial titles) → ISBN, LCCN, normalized LCC.
/// 2. If an LCCN is known, fetch the LC record from loc.gov for the authoritative call number
///    and subject headings; otherwise search loc.gov's books collection directly.
struct CatalogService {
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "Shelfmark/0.1 (iOS personal library cataloger)"]
        return URLSession(configuration: config)
    }()

    func lookup(title: String, authors: [String], publisherHint: String = "") async -> CatalogRecord? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return nil }
        let author = authors.first ?? ""

        var record = CatalogRecord()
        if let ol = await openLibrary(title: cleanTitle, author: author) {
            record = ol
        }

        if !record.lccn.isEmpty, let lc = await locItem(lccn: record.lccn) {
            merge(lc, into: &record)
        } else if let lc = await locSearch(title: cleanTitle, author: author) {
            merge(lc, into: &record)
        }

        if record.title.isEmpty && record.lcCallNumber.isEmpty { return nil }
        if record.title.isEmpty { record.title = cleanTitle }
        if record.authors.isEmpty { record.authors = authors }
        return record
    }

    private func merge(_ lc: CatalogRecord, into record: inout CatalogRecord) {
        // LC is authoritative for call number and subject headings.
        if !lc.lcCallNumber.isEmpty { record.lcCallNumber = lc.lcCallNumber }
        if !lc.subjects.isEmpty { record.subjects = lc.subjects }
        if record.lccn.isEmpty { record.lccn = lc.lccn }
        if record.title.isEmpty { record.title = lc.title }
        if record.year.isEmpty { record.year = lc.year }
        if record.authors.isEmpty { record.authors = lc.authors }
        record.sources.append(contentsOf: lc.sources)
    }

    // MARK: Open Library

    private func openLibrary(title: String, author: String) async -> CatalogRecord? {
        var c = URLComponents(string: "https://openlibrary.org/search.json")!
        c.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "fields", value: "title,author_name,lcc,lccn,isbn,first_publish_year,publisher,subject")
        ]
        if !author.isEmpty { c.queryItems?.append(URLQueryItem(name: "author", value: author)) }
        guard let json = await getJSON(c.url!) as? [String: Any],
              let docs = json["docs"] as? [[String: Any]], !docs.isEmpty else { return nil }

        let best = docs.max { a, b in
            TextMatch.score(title, (a["title"] as? String) ?? "") < TextMatch.score(title, (b["title"] as? String) ?? "")
        }!
        guard TextMatch.score(title, (best["title"] as? String) ?? "") > 0.35 else { return nil }

        var r = CatalogRecord()
        r.title = best["title"] as? String ?? ""
        r.authors = best["author_name"] as? [String] ?? []
        r.publisher = (best["publisher"] as? [String])?.first ?? ""
        if let y = best["first_publish_year"] as? Int { r.year = String(y) }
        let isbns = best["isbn"] as? [String] ?? []
        r.isbn = isbns.first(where: { $0.count == 13 }) ?? isbns.first ?? ""
        r.lccn = (best["lccn"] as? [String])?.first ?? ""
        if let lcc = (best["lcc"] as? [String])?.first { r.lcCallNumber = LCCallNumber.fromOpenLibrary(lcc) }
        r.subjects = Array((best["subject"] as? [String] ?? []).prefix(8))
        r.sources = ["Open Library"]
        return r
    }

    // MARK: Library of Congress (loc.gov JSON API)

    private func locItem(lccn: String) async -> CatalogRecord? {
        let clean = lccn.replacingOccurrences(of: " ", with: "")
        guard let url = URL(string: "https://www.loc.gov/item/\(clean)/?fo=json"),
              let json = await getJSON(url) as? [String: Any],
              let item = json["item"] as? [String: Any] else { return nil }
        var r = CatalogRecord()
        r.lccn = clean
        r.title = item["title"] as? String ?? ""
        r.lcCallNumber = Self.firstString(item["call_number"])
        r.subjects = Self.strings(item["subject_headings"]).isEmpty
            ? Self.strings(item["subjects"]) : Self.strings(item["subject_headings"])
        r.year = Self.firstString(item["date"])
        r.authors = Self.strings(item["contributor_names"])
        r.sources = ["Library of Congress"]
        return r.lcCallNumber.isEmpty && r.subjects.isEmpty ? nil : r
    }

    private func locSearch(title: String, author: String) async -> CatalogRecord? {
        var c = URLComponents(string: "https://www.loc.gov/books/")!
        c.queryItems = [
            URLQueryItem(name: "q", value: [title, author].filter { !$0.isEmpty }.joined(separator: " ")),
            URLQueryItem(name: "fo", value: "json"),
            URLQueryItem(name: "c", value: "8"),
            URLQueryItem(name: "at", value: "results")
        ]
        guard let json = await getJSON(c.url!) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }

        let candidates = results.filter { !Self.firstString($0["call_number"]).isEmpty }
        guard let best = candidates.max(by: {
            TextMatch.score(title, $0["title"] as? String ?? "") < TextMatch.score(title, $1["title"] as? String ?? "")
        }), TextMatch.score(title, best["title"] as? String ?? "") > 0.4 else { return nil }

        var r = CatalogRecord()
        r.title = best["title"] as? String ?? ""
        r.lcCallNumber = Self.firstString(best["call_number"])
        r.lccn = Self.firstString(best["number_lccn"])
        r.subjects = Array(Self.strings(best["subject"]).prefix(8))
        r.year = Self.firstString(best["date"])
        r.authors = Self.strings(best["contributor"])
        r.sources = ["Library of Congress"]
        return r
    }

    // MARK: Helpers

    private func getJSON(_ url: URL) async -> Any? {
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data)
        } catch { return nil }
    }

    private static func strings(_ any: Any?) -> [String] {
        if let a = any as? [String] { return a }
        if let s = any as? String { return [s] }
        return []
    }

    private static func firstString(_ any: Any?) -> String { strings(any).first ?? "" }
}

// MARK: - Title matching

enum TextMatch {
    static func tokens(_ s: String) -> Set<String> {
        let stop: Set<String> = ["the", "a", "an", "of", "and", "in", "on", "to", "for"]
        return Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stop.contains($0) })
    }

    /// Overlap of the query's tokens with the candidate's, 0–1. Weighted toward the query
    /// so that a short spine title still matches a long catalog title with subtitle.
    static func score(_ query: String, _ candidate: String) -> Double {
        let q = tokens(query), c = tokens(candidate)
        guard !q.isEmpty, !c.isEmpty else { return 0 }
        let inter = Double(q.intersection(c).count)
        return 0.75 * inter / Double(q.count) + 0.25 * inter / Double(c.count)
    }
}

// MARK: - LC call numbers

enum LCCallNumber {
    /// Converts Open Library's normalized LCC ("HT-0123.00000000.J3 1961") to display form ("HT123 .J3 1961").
    static func fromOpenLibrary(_ normalized: String) -> String {
        let parts = normalized.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return normalized }
        let letters = parts[0]
        var rest = parts[1]
        var number = ""
        // Leading class number: digits with an optional decimal part.
        let numChars = rest.prefix { $0.isNumber || $0 == "." }
        rest.removeFirst(numChars.count)
        let numParts = numChars.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(Int(numParts.first ?? "0") ?? 0)
        let frac = numParts.count > 1 ? numParts[1].replacingOccurrences(of: "0+$", with: "", options: .regularExpression) : ""
        number = frac.isEmpty ? whole : "\(whole).\(frac)"
        // Cutters follow; ensure a space+dot before the first cutter.
        var tail = rest.trimmingCharacters(in: .whitespaces)
        if tail.hasPrefix(".") { tail = " " + tail }
        else if !tail.isEmpty { tail = " " + tail }
        return letters + number + tail
    }

    static func classLetters(_ call: String) -> String {
        String(call.trimmingCharacters(in: .whitespaces).prefix { $0.isLetter }).uppercased()
    }

    /// A sortable key that orders call numbers the way they sit on a library shelf:
    /// class letters alphabetically, class number numerically, then cutters as decimals.
    static func sortKey(_ call: String) -> String {
        let s = call.uppercased().trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return "~" }
        let letters = String(s.prefix { $0.isLetter })
        var rest = s.dropFirst(letters.count).drop { $0 == " " }
        let numStr = String(rest.prefix { $0.isNumber || $0 == "." })
        rest = rest.dropFirst(numStr.count)
        let num = Double(numStr) ?? 0
        let numKey = String(format: "%010.4f", num)
        let cutters = rest.replacingOccurrences(of: " ", with: "")
        return letters.padding(toLength: 3, withPad: " ", startingAt: 0) + numKey + cutters
    }
}
