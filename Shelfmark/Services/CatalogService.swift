import Foundation

/// A bibliographic record assembled from the Library of Congress and other sources,
/// normalized to LC conventions so every book in the catalog reads the same way.
struct CatalogRecord: Sendable {
    var title: String = ""
    var subtitle: String = ""
    var authors: [String] = []          // display form, "Jane Jacobs"
    var authorHeading: String = ""      // LC main entry, "Jacobs, Jane, 1916-2006"
    var edition: String = ""
    var place: String = ""
    var publisher: String = ""
    var year: String = ""
    var isbn: String = ""
    var lccn: String = ""
    var lcCallNumber: String = ""
    var callNumberSource: String = ""
    var subjects: [String] = []
    var sources: [String] = []
    var catalogURL: String = ""

    var lcClass: String { LCCallNumber.classLetters(lcCallNumber) }
    var isComplete: Bool { !lcCallNumber.isEmpty && !title.isEmpty }
    var hasAuthoritativeCallNumber: Bool {
        !lcCallNumber.isEmpty && !callNumberSource.lowercased().contains("proposed")
    }

    /// Applies LC formatting conventions to every field.
    mutating func normalize() {
        lcCallNumber = LCCallNumber.normalize(lcCallNumber)
        subjects = LCSH.normalize(subjects)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "/:;,.")))
        subtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "/:;,.")))
        authorHeading = authorHeading.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.")))
        if authors.isEmpty, !authorHeading.isEmpty { authors = [LCName.displayForm(authorHeading)] }
        if authorHeading.isEmpty, let first = authors.first { authorHeading = LCName.headingForm(first) }
        publisher = publisher.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",:;")))
        place = place.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "[]:;,")))
        year = LCDate.year(from: year)
        isbn = isbn.replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespaces)
        lccn = lccn.replacingOccurrences(of: " ", with: "")
    }

    /// Fills empty fields from another record without overwriting what is already known.
    mutating func fillGaps(from o: CatalogRecord) {
        if title.isEmpty { title = o.title }
        if subtitle.isEmpty { subtitle = o.subtitle }
        if authors.isEmpty { authors = o.authors }
        if authorHeading.isEmpty { authorHeading = o.authorHeading }
        if edition.isEmpty { edition = o.edition }
        if place.isEmpty { place = o.place }
        if publisher.isEmpty { publisher = o.publisher }
        if year.isEmpty { year = o.year }
        if isbn.isEmpty { isbn = o.isbn }
        if lccn.isEmpty { lccn = o.lccn }
        if lcCallNumber.isEmpty { lcCallNumber = o.lcCallNumber; callNumberSource = o.callNumberSource }
        if subjects.isEmpty { subjects = o.subjects }
        if catalogURL.isEmpty { catalogURL = o.catalogURL }
        for s in o.sources where !sources.contains(s) { sources.append(s) }
    }
}

/// What the spine (or cover) tells us, used to find the right record and edition.
struct BookClues: Sendable {
    var title: String
    var authors: [String]
    var publisher: String = ""
    var spineText: String = ""
    var designNotes: String = ""
    var isbn: String = ""
}

/// Finds Library of Congress cataloging for a book, trying sources from most to least authoritative:
///
/// 1. Candidate editions from Google Books and Open Library (tolerant of partial spine titles),
///    choosing the edition whose publisher matches the spine where possible.
/// 2. The LC catalog itself, by ISBN, LCCN, then title and author (MODS records via LC's SRU
///    server and lccn.loc.gov permalinks): authoritative call number, subject headings,
///    main-entry heading, edition and imprint.
/// 3. Open Library edition records (`lc_classifications`) and loc.gov search as fallbacks.
/// 4. Optionally, a Claude research pass with web search for anything still missing, which can
///    consult WorldCat, publisher CIP data and other catalogs, and proposes an LC-style call
///    number (clearly labelled) only when no catalog has one.
struct CatalogService {
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "Shelfmark/0.2 (personal library cataloging app)"]
        return URLSession(configuration: config)
    }()

    func lookup(title: String, authors: [String], publisherHint: String = "") async -> CatalogRecord? {
        await lookup(BookClues(title: title, authors: authors, publisher: publisherHint), deep: AppSettings.deepCatalogSearch)
    }

    func lookup(_ clues: BookClues, deep: Bool) async -> CatalogRecord? {
        let title = clues.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !clues.isbn.isEmpty else { return nil }
        let author = clues.authors.first ?? ""

        // 1. Candidate editions.
        async let gb = googleBooks(title: title, author: author, isbn: clues.isbn)
        async let ol = openLibrarySearch(title: title, author: author)
        var candidates = (await gb) + (await ol)
        candidates.sort { score($0, clues) > score($1, clues) }
        candidates = candidates.filter { score($0, clues) > 0.45 || (!clues.isbn.isEmpty && $0.isbn == clues.isbn) }

        var record = candidates.first ?? CatalogRecord()
        let isbns = ([clues.isbn] + candidates.prefix(3).map(\.isbn)).filter { !$0.isEmpty }
        let lccns = candidates.prefix(3).map(\.lccn).filter { !$0.isEmpty }

        // 2. The LC catalog.
        var lc: CatalogRecord?
        for lccn in lccns where lc == nil { lc = await lcByLCCN(lccn) }
        for isbn in isbns.prefix(3) where lc == nil { lc = await lcSRU(query: "bath.isbn=\(isbn)", clues: clues) }
        if lc == nil, !title.isEmpty {
            let t = title.replacingOccurrences(of: "\"", with: "")
            var q = "dc.title=\"\(t)\""
            if let surname = author.split(separator: " ").last { q += " and dc.creator=\"\(surname)\"" }
            lc = await lcSRU(query: q, clues: clues)
        }
        if var lc {
            lc.fillGaps(from: record)
            record = lc
        }

        // 3. Open Library edition records and loc.gov search.
        if record.lcCallNumber.isEmpty {
            for isbn in isbns.prefix(3) where record.lcCallNumber.isEmpty {
                if let ed = await openLibraryEdition(isbn: isbn) { record.fillGaps(from: ed) }
            }
        }
        if record.lcCallNumber.isEmpty, !title.isEmpty, let loc = await locSearch(title: title, author: author) {
            record.fillGaps(from: loc)
        }

        // 4. Claude research with web search.
        if deep, !record.hasAuthoritativeCallNumber || record.subjects.isEmpty,
           let researched = try? await LibrarianService().research(clues, partial: record) {
            var merged = researched
            merged.fillGaps(from: record)
            // Keep an authoritative LC call number over anything proposed.
            if record.hasAuthoritativeCallNumber { merged.lcCallNumber = record.lcCallNumber; merged.callNumberSource = record.callNumberSource }
            record = merged
        }

        if record.title.isEmpty && record.lcCallNumber.isEmpty { return nil }
        if record.title.isEmpty { record.title = title }
        if record.authors.isEmpty { record.authors = clues.authors }
        record.normalize()
        return record
    }

    /// How well a candidate edition matches the clues: title most of all, then author and publisher.
    private func score(_ c: CatalogRecord, _ clues: BookClues) -> Double {
        var s = TextMatch.score(clues.title, c.title + " " + c.subtitle)
        if let a = clues.authors.first, !a.isEmpty {
            let surname = a.split(separator: " ").last.map(String.init) ?? a
            if c.authors.joined(separator: " ").localizedCaseInsensitiveContains(surname) { s += 0.25 }
        }
        if !clues.publisher.isEmpty, TextMatch.score(clues.publisher, c.publisher) > 0.5 { s += 0.2 }
        if !clues.isbn.isEmpty, c.isbn == clues.isbn { s += 1 }
        return s
    }

    // MARK: Google Books

    private func googleBooks(title: String, author: String, isbn: String) async -> [CatalogRecord] {
        var q: String
        if !isbn.isEmpty { q = "isbn:\(isbn)" }
        else {
            q = "intitle:\(title)"
            if let surname = author.split(separator: " ").last { q += " inauthor:\(surname)" }
        }
        var c = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "maxResults", value: "10"),
                        URLQueryItem(name: "printType", value: "books")]
        guard let json = await getJSON(c.url!) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let v = item["volumeInfo"] as? [String: Any] else { return nil }
            var r = CatalogRecord()
            r.title = v["title"] as? String ?? ""
            r.subtitle = v["subtitle"] as? String ?? ""
            r.authors = v["authors"] as? [String] ?? []
            r.publisher = v["publisher"] as? String ?? ""
            r.year = v["publishedDate"] as? String ?? ""
            let ids = v["industryIdentifiers"] as? [[String: Any]] ?? []
            r.isbn = (ids.first { $0["type"] as? String == "ISBN_13" } ?? ids.first { $0["type"] as? String == "ISBN_10" })?["identifier"] as? String ?? ""
            r.sources = ["Google Books"]
            return r
        }
    }

    // MARK: Open Library

    private func openLibrarySearch(title: String, author: String) async -> [CatalogRecord] {
        guard !title.isEmpty else { return [] }
        var c = URLComponents(string: "https://openlibrary.org/search.json")!
        c.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "fields", value: "title,subtitle,author_name,lcc,lccn,isbn,first_publish_year,publisher,subject")
        ]
        if !author.isEmpty { c.queryItems?.append(URLQueryItem(name: "author", value: author)) }
        guard let json = await getJSON(c.url!) as? [String: Any],
              let docs = json["docs"] as? [[String: Any]] else { return [] }
        return docs.map { d in
            var r = CatalogRecord()
            r.title = d["title"] as? String ?? ""
            r.subtitle = d["subtitle"] as? String ?? ""
            r.authors = d["author_name"] as? [String] ?? []
            r.publisher = (d["publisher"] as? [String])?.first ?? ""
            if let y = d["first_publish_year"] as? Int { r.year = String(y) }
            let isbns = d["isbn"] as? [String] ?? []
            r.isbn = isbns.first(where: { $0.count == 13 }) ?? isbns.first ?? ""
            r.lccn = (d["lccn"] as? [String])?.first ?? ""
            if let lcc = (d["lcc"] as? [String])?.first {
                r.lcCallNumber = LCCallNumber.fromOpenLibrary(lcc)
                r.callNumberSource = "Open Library"
            }
            r.sources = ["Open Library"]
            return r
        }
    }

    private func openLibraryEdition(isbn: String) async -> CatalogRecord? {
        guard let url = URL(string: "https://openlibrary.org/isbn/\(isbn).json"),
              let e = await getJSON(url) as? [String: Any] else { return nil }
        var r = CatalogRecord()
        r.title = e["title"] as? String ?? ""
        r.subtitle = e["subtitle"] as? String ?? ""
        r.edition = e["edition_name"] as? String ?? ""
        r.publisher = (e["publishers"] as? [String])?.first ?? ""
        r.place = (e["publish_places"] as? [String])?.first ?? ""
        r.year = e["publish_date"] as? String ?? ""
        r.lccn = (e["lccn"] as? [String])?.first ?? ""
        r.isbn = isbn
        if let lcc = (e["lc_classifications"] as? [String])?.first(where: { !$0.isEmpty }) {
            r.lcCallNumber = lcc
            r.callNumberSource = "Open Library"
        }
        r.sources = ["Open Library"]
        r.catalogURL = "https://openlibrary.org/isbn/\(isbn)"
        return r
    }

    // MARK: Library of Congress catalog

    /// LC's catalog over SRU. Returns the record that best matches the clues.
    private func lcSRU(query: String, clues: BookClues) async -> CatalogRecord? {
        var c = URLComponents(string: "http://lx2.loc.gov:210/lcdb")!
        c.queryItems = [
            URLQueryItem(name: "version", value: "1.1"),
            URLQueryItem(name: "operation", value: "searchRetrieve"),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "maximumRecords", value: "5"),
            URLQueryItem(name: "recordSchema", value: "mods")
        ]
        guard let url = c.url, let data = await getData(url) else { return nil }
        let records = MODSParser.parse(data)
        let best = records.max { TextMatch.score(clues.title, $0.title + " " + $0.subtitle) < TextMatch.score(clues.title, $1.title + " " + $1.subtitle) }
        guard var r = best else { return nil }
        if !clues.title.isEmpty, TextMatch.score(clues.title, r.title + " " + r.subtitle) < 0.45, !query.hasPrefix("bath.isbn") { return nil }
        r.sources = ["Library of Congress"]
        if !r.lcCallNumber.isEmpty { r.callNumberSource = "Library of Congress" }
        if !r.lccn.isEmpty { r.catalogURL = "https://lccn.loc.gov/\(r.lccn)" }
        return r
    }

    /// LC permalink record by LCCN.
    private func lcByLCCN(_ lccn: String) async -> CatalogRecord? {
        let clean = lccn.replacingOccurrences(of: " ", with: "")
        guard let url = URL(string: "https://lccn.loc.gov/\(clean)/mods"),
              let data = await getData(url),
              var r = MODSParser.parse(data).first else { return nil }
        if r.lccn.isEmpty { r.lccn = clean }
        r.sources = ["Library of Congress"]
        if !r.lcCallNumber.isEmpty { r.callNumberSource = "Library of Congress" }
        r.catalogURL = "https://lccn.loc.gov/\(clean)"
        return r
    }

    /// loc.gov collections search (JSON), a weaker fallback.
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
        let withCall = results.filter { !Self.firstString($0["call_number"]).isEmpty }
        guard let best = withCall.max(by: {
            TextMatch.score(title, $0["title"] as? String ?? "") < TextMatch.score(title, $1["title"] as? String ?? "")
        }), TextMatch.score(title, best["title"] as? String ?? "") > 0.45 else { return nil }
        var r = CatalogRecord()
        r.title = best["title"] as? String ?? ""
        r.lcCallNumber = Self.firstString(best["call_number"])
        r.callNumberSource = "Library of Congress"
        r.lccn = Self.firstString(best["number_lccn"])
        r.subjects = Array(Self.strings(best["subject"]).prefix(8))
        r.year = Self.firstString(best["date"])
        r.sources = ["Library of Congress"]
        r.catalogURL = best["id"] as? String ?? ""
        return r
    }

    // MARK: Helpers

    private func getData(_ url: URL) async -> Data? {
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        } catch { return nil }
    }

    private func getJSON(_ url: URL) async -> Any? {
        guard let data = await getData(url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func strings(_ any: Any?) -> [String] {
        if let a = any as? [String] { return a }
        if let s = any as? String { return [s] }
        return []
    }

    private static func firstString(_ any: Any?) -> String { strings(any).first ?? "" }
}

// MARK: - MODS parsing

/// Parses MODS XML (from LC's SRU server or lccn.loc.gov) into catalog records.
final class MODSParser: NSObject, XMLParserDelegate {
    private var records: [CatalogRecord] = []
    private var current: CatalogRecord?
    private var path: [(name: String, attrs: [String: String])] = []
    private var text = ""
    private var subjectParts: [String] = []
    private var nameParts: [String] = []
    private var nameDate = ""
    private var nameIsPrimary = false
    private var sawTitle = false
    private var nonSort = ""

    static func parse(_ data: Data) -> [CatalogRecord] {
        let delegate = MODSParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.records
    }

    private func inside(_ name: String) -> Bool { path.contains { $0.name == name } }
    private func attr(_ element: String, _ key: String) -> String? { path.last { $0.name == element }?.attrs[key] }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        path.append((elementName, attributeDict))
        text = ""
        switch elementName {
        case "mods":
            current = CatalogRecord()
            sawTitle = false
        case "subject": subjectParts = []
        case "name":
            nameParts = []; nameDate = ""
            nameIsPrimary = attributeDict["usage"] == "primary"
        case "titleInfo": nonSort = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { if !path.isEmpty { path.removeLast() }; text = "" }
        guard current != nil else { return }

        switch elementName {
        case "nonSort" where inside("titleInfo"):
            nonSort = text
        case "title" where inside("titleInfo") && !inside("relatedItem"):
            // The first titleInfo without a type is the title proper.
            if !sawTitle && attr("titleInfo", "type") == nil {
                current?.title = (nonSort + value).trimmingCharacters(in: .whitespaces)
                sawTitle = true
            }
        case "subTitle" where inside("titleInfo") && !inside("relatedItem"):
            if current?.subtitle.isEmpty == true && attr("titleInfo", "type") == nil { current?.subtitle = value }
        case "namePart" where inside("name") && !inside("subject") && !inside("relatedItem"):
            if path.last?.attrs["type"] == "date" { nameDate = value } else if !value.isEmpty { nameParts.append(value) }
        case "name" where !inside("subject") && !inside("relatedItem"):
            let base = nameParts.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
            guard !base.isEmpty else { break }
            let heading = nameDate.isEmpty ? base : "\(base), \(nameDate)"
            // The primary name is the main entry; otherwise the first personal name stands in.
            if nameIsPrimary || current?.authorHeading.isEmpty == true { current?.authorHeading = heading }
            current?.authors.append(LCName.displayForm(base))
        case "edition" where inside("originInfo"):
            if current?.edition.isEmpty == true { current?.edition = value }
        case "placeTerm" where inside("originInfo"):
            if path.last?.attrs["type"] == "text", current?.place.isEmpty == true { current?.place = value }
        case "publisher" where inside("originInfo"):
            if current?.publisher.isEmpty == true { current?.publisher = value }
        case "dateIssued" where inside("originInfo"):
            if current?.year.isEmpty == true { current?.year = value }
        case "topic", "geographic", "temporal", "genre":
            if inside("subject") && !value.isEmpty { subjectParts.append(value) }
        case "subject":
            let auth = path.last?.attrs["authority"] ?? ""
            if !subjectParts.isEmpty && (auth.isEmpty || auth == "lcsh") {
                current?.subjects.append(subjectParts.joined(separator: " -- "))
            }
        case "classification":
            if path.last?.attrs["authority"] == "lcc", current?.lcCallNumber.isEmpty == true { current?.lcCallNumber = value }
        case "identifier" where !inside("relatedItem"):
            let type = path.last?.attrs["type"] ?? ""
            if type == "isbn", current?.isbn.isEmpty == true {
                current?.isbn = String(value.split(separator: " ").first ?? "")
            } else if type == "lccn", current?.lccn.isEmpty == true {
                current?.lccn = value
            }
        case "mods":
            if let r = current { records.append(r) }
            current = nil
        default: break
        }
    }
}

// MARK: - LC conventions

enum LCName {
    /// "Jacobs, Jane, 1916-2006" → "Jane Jacobs"
    static func displayForm(_ heading: String) -> String {
        let parts = heading.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, !parts[1].isEmpty, !(parts[1].first?.isNumber ?? false) else {
            return parts.first ?? heading
        }
        return "\(parts[1]) \(parts[0])"
    }

    /// "Jane Jacobs" → "Jacobs, Jane"
    static func headingForm(_ display: String) -> String {
        if display.contains(",") { return display }
        let words = display.split(separator: " ").map(String.init)
        guard words.count >= 2, let last = words.last else { return display }
        return "\(last), \(words.dropLast().joined(separator: " "))"
    }
}

enum LCDate {
    /// Pulls a four-digit year out of strings like "[1961]", "c1961.", "March 3, 1998".
    static func year(from s: String) -> String {
        guard let r = s.range(of: #"(1[5-9]|20)\d{2}"#, options: .regularExpression) else {
            return s.trimmingCharacters(in: .whitespaces)
        }
        return String(s[r])
    }
}

enum LCSH {
    /// Uses " -- " between subdivisions, removes trailing periods and duplicates.
    static func normalize(_ headings: [String]) -> [String] {
        var seen = Set<String>()
        return headings.compactMap { h in
            var s = h.replacingOccurrences(of: "—", with: " -- ")
                .replacingOccurrences(of: "–", with: " -- ")
                .replacingOccurrences(of: #"\s*--\s*"#, with: " -- ", options: .regularExpression)
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: " .;,"))
            guard !s.isEmpty, seen.insert(s.lowercased()).inserted else { return nil }
            return s
        }
    }

    /// The main heading before any subdivision ("City planning -- United States" → "City planning").
    static func main(_ heading: String) -> String {
        heading.components(separatedBy: " -- ").first ?? heading
    }
}

// MARK: - Title matching

enum TextMatch {
    static func tokens(_ s: String) -> Set<String> {
        let stop: Set<String> = ["the", "a", "an", "of", "and", "in", "on", "to", "for"]
        return Set(s.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
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
    /// Converts Open Library's normalized LCC ("HT-0123.00000000.J3 1961") to display form.
    static func fromOpenLibrary(_ normalized: String) -> String {
        let parts = normalized.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return normalized }
        let letters = parts[0]
        var rest = parts[1]
        let numChars = rest.prefix { $0.isNumber || $0 == "." }
        rest.removeFirst(numChars.count)
        let numParts = numChars.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(Int(numParts.first ?? "0") ?? 0)
        let frac = numParts.count > 1 ? numParts[1].replacingOccurrences(of: "0+$", with: "", options: .regularExpression) : ""
        let number = frac.isEmpty ? whole : "\(whole).\(frac)"
        return normalize(letters + number + rest)
    }

    /// One consistent form for every call number, following the LC catalog's display of
    /// MARC 050: class letters and number, the first cutter joined with a period, then any
    /// further cutters and the date separated by single spaces. e.g. "HT167.J3 1961".
    static func normalize(_ raw: String) -> String {
        var s = raw.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // Class letters followed by a space before the number: "HT 167" → "HT167"
        s = s.replacingOccurrences(of: #"^([A-Z]{1,3})\s+(\d)"#, with: "$1$2", options: .regularExpression)
        // First cutter: "HT167 .J3" / "HT167 J3" → "HT167.J3"
        s = s.replacingOccurrences(of: #"^([A-Z]{1,3}\d+(?:\.\d+)?)\s*\.?\s*([A-Z]\d)"#, with: "$1.$2", options: .regularExpression)
        // Later cutters written with a period: " .Z46" → " Z46"
        s = s.replacingOccurrences(of: #"\s\.([A-Z]\d)"#, with: " $1", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func classLetters(_ call: String) -> String {
        String(call.trimmingCharacters(in: .whitespaces).prefix { $0.isLetter }).uppercased()
    }

    /// Breaks a call number into spine-label lines: "HT\n167\n.J3\n1961".
    static func labelLines(_ call: String) -> [String] {
        let n = normalize(call)
        guard !n.isEmpty else { return [] }
        let letters = classLetters(n)
        var rest = String(n.dropFirst(letters.count))
        var lines = [letters]
        if let dot = rest.range(of: #"\.[A-Z]"#, options: .regularExpression) {
            lines.append(String(rest[..<dot.lowerBound]))
            rest = String(rest[dot.lowerBound...])
        } else if let space = rest.firstIndex(of: " ") {
            lines.append(String(rest[..<space]))
            rest = String(rest[space...])
        } else {
            lines.append(rest); rest = ""
        }
        lines += rest.split(separator: " ").map(String.init)
        return lines.filter { !$0.isEmpty }
    }

    /// A sortable key that orders call numbers the way they sit on a library shelf:
    /// class letters alphabetically, class number numerically, then cutters as decimals.
    static func sortKey(_ call: String) -> String {
        let s = normalize(call)
        guard !s.isEmpty else { return "~" }
        let letters = String(s.prefix { $0.isLetter })
        var rest = s.dropFirst(letters.count).drop { $0 == " " }
        let numStr = String(rest.prefix { $0.isNumber || $0 == "." }.reversed().drop { $0 == "." }.reversed())
        rest = rest.dropFirst(numStr.count)
        let num = Double(numStr) ?? 0
        let numKey = String(format: "%010.4f", num)
        let cutters = rest.replacingOccurrences(of: " ", with: "")
        return letters.padding(toLength: 3, withPad: " ", startingAt: 0) + numKey + cutters
    }
}
