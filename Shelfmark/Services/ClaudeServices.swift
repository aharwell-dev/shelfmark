import Foundation

/// Minimal non-streaming client for the Claude Messages API (raw HTTPS; there is no official Swift SDK).
struct ClaudeClient {
    var apiKey: String = AppSettings.apiKey
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Sends a request body and returns the decoded response. Retries rate limits and server errors.
    func send(_ body: [String: Any], timeout: TimeInterval = 300) async throws -> [String: Any] {
        guard !apiKey.isEmpty else { throw ClaudeError.missingKey }
        var body = body
        // If a safety classifier declines, let the API retry on a fallback model in the same call.
        body["fallbacks"] = "default"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var delay: UInt64 = 2_000_000_000
        for attempt in 1...3 {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ClaudeError.badResponse(String(data: data, encoding: .utf8) ?? "")
                }
                if json["stop_reason"] as? String == "refusal" {
                    let why = (json["stop_details"] as? [String: Any])?["explanation"] as? String
                    throw ClaudeError.refused(why ?? "no explanation")
                }
                return json
            }
            let retryable = [408, 429, 500, 502, 503, 504, 529].contains(status)
            if !retryable || attempt == 3 {
                throw ClaudeError.http(status, String(data: data, encoding: .utf8) ?? "")
            }
            try await Task.sleep(nanoseconds: delay)
            delay *= 2
        }
        throw ClaudeError.badResponse("retries exhausted")
    }

    /// The text of the last text block in a response.
    static func text(of response: [String: Any]) -> String? {
        let blocks = response["content"] as? [[String: Any]] ?? []
        return blocks.last { $0["type"] as? String == "text" }?["text"] as? String
    }

    /// Decodes a structured-output response into a Codable type.
    static func decode<T: Decodable>(_ type: T.Type, from response: [String: Any]) throws -> T {
        if response["stop_reason"] as? String == "max_tokens" { throw ClaudeError.truncated }
        guard let text = text(of: response), let data = text.data(using: .utf8) else {
            throw ClaudeError.badResponse("no text in response")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Librarian: catalog research with web search

/// When the fast catalog sources come up short, asks Claude to research the book on the web,
/// the way a cataloger would: LC catalog first, then WorldCat and other national catalogs,
/// publisher CIP data, and booksellers for edition details.
struct LibrarianService {
    private let client = ClaudeClient()

    private static let system = """
    You are a professional cataloger at the Library of Congress. Given clues read from a book's \
    spine (or cover) in a private library, find the authoritative bibliographic record for the \
    exact edition on the shelf and record it with the record_catalog_entry tool.

    Research order:
    1. The Library of Congress catalog (catalog.loc.gov, lccn.loc.gov). Prefer its LC call number \
       (MARC 050), subject headings (LCSH, 650/651), main entry (100) and edition (250).
    2. WorldCat and other national or university library catalogs, including records that carry an \
       LC call number assigned by another library.
    3. The publisher's Cataloging-in-Publication data (often shown on publisher or Google Books pages).
    4. Open Library, Google Books and booksellers (including Amazon listings that appear in search \
       results) for ISBN, edition statement, publisher and date.

    Identify the edition: use the publisher, series design, colors and typography described on \
    the spine to choose among editions (e.g. a Penguin Modern Classics paperback vs. the first \
    US hardcover). Give the ISBN of that edition when it can be determined.

    Follow LC conventions exactly:
    - Call number as displayed in the LC catalog from MARC 050, e.g. "HT167.J3 1961" or \
      "PS3545.H16 Z46 1990". Never invent one silently. If no catalog provides a call number, \
      construct one from the LC Classification schedules and Cutter table and set \
      call_number_source to "Proposed (LC-style)".
    - Subject headings in LCSH form with " -- " between subdivisions, e.g. \
      "City planning -- United States". Use headings from a catalog record when one exists.
    - author_heading in LC name-authority form, e.g. "Jacobs, Jane, 1916-2006".
    - Title and subtitle as transcribed by LC (sentence case is fine); edition as in the 250 field.
    - Never fabricate an ISBN or LCCN; leave a field empty if you cannot verify it.
    Set found to false only if you cannot identify the book at all.
    """

    private static let recordTool: [String: Any] = [
        "name": "record_catalog_entry",
        "description": "Record the bibliographic data for the book, following Library of Congress conventions. Call this exactly once, when research is complete.",
        "strict": true,
        "input_schema": [
            "type": "object",
            "properties": [
                "found": ["type": "boolean"],
                "title": ["type": "string"],
                "subtitle": ["type": "string"],
                "authors": ["type": "array", "items": ["type": "string"], "description": "Display form, e.g. Jane Jacobs"],
                "author_heading": ["type": "string"],
                "edition": ["type": "string"],
                "place": ["type": "string"],
                "publisher": ["type": "string"],
                "year": ["type": "string"],
                "isbn": ["type": "string"],
                "lccn": ["type": "string"],
                "lc_call_number": ["type": "string"],
                "call_number_source": ["type": "string",
                                       "enum": ["Library of Congress", "WorldCat", "Other library catalog",
                                                "Publisher CIP", "Open Library", "Proposed (LC-style)", "None"]],
                "subjects": ["type": "array", "items": ["type": "string"]],
                "catalog_url": ["type": "string"],
                "confidence": ["type": "number"]
            ],
            "required": ["found", "title", "subtitle", "authors", "author_heading", "edition", "place",
                         "publisher", "year", "isbn", "lccn", "lc_call_number", "call_number_source",
                         "subjects", "catalog_url", "confidence"],
            "additionalProperties": false
        ]
    ]

    func research(_ clues: BookClues, partial: CatalogRecord) async throws -> CatalogRecord? {
        var prompt = "Book to catalog:\n"
        prompt += "Title (as read): \(clues.title)\n"
        if !clues.authors.isEmpty { prompt += "Author(s): \(clues.authors.joined(separator: "; "))\n" }
        if !clues.publisher.isEmpty { prompt += "Publisher on spine: \(clues.publisher)\n" }
        if !clues.spineText.isEmpty { prompt += "Full spine text: \(clues.spineText)\n" }
        if !clues.designNotes.isEmpty { prompt += "Spine design: \(clues.designNotes)\n" }
        if !clues.isbn.isEmpty { prompt += "ISBN: \(clues.isbn)\n" }
        if !partial.isbn.isEmpty || !partial.lccn.isEmpty || !partial.lcCallNumber.isEmpty {
            prompt += "\nAlready found (verify and complete): ISBN \(partial.isbn), LCCN \(partial.lccn), "
            prompt += "call number \(partial.lcCallNumber) from \(partial.callNumberSource), publisher \(partial.publisher), year \(partial.year)\n"
        }

        var messages: [[String: Any]] = [["role": "user", "content": prompt]]
        let base: [String: Any] = [
            "model": AppSettings.model,
            "max_tokens": 16000,
            "system": Self.system,
            "output_config": ["effort": "medium"],
            "tools": [
                ["type": "web_search_20260209", "name": "web_search", "max_uses": 6],
                ["type": "web_fetch_20260209", "name": "web_fetch", "max_uses": 4],
                Self.recordTool
            ],
            "tool_choice": ["type": "auto"]
        ]

        // Server-side tools can pause a long turn; resume by sending the turn back as-is.
        for _ in 0..<4 {
            var body = base
            body["messages"] = messages
            let response = try await client.send(body, timeout: 600)
            let content = response["content"] as? [[String: Any]] ?? []

            if let call = content.first(where: { $0["type"] as? String == "tool_use" && $0["name"] as? String == "record_catalog_entry" }),
               let input = call["input"] as? [String: Any] {
                return Self.record(from: input)
            }
            guard response["stop_reason"] as? String == "pause_turn" else { return nil }
            messages = [messages[0], ["role": "assistant", "content": content]]
        }
        return nil
    }

    private static func record(from i: [String: Any]) -> CatalogRecord? {
        guard i["found"] as? Bool == true else { return nil }
        var r = CatalogRecord()
        r.title = i["title"] as? String ?? ""
        r.subtitle = i["subtitle"] as? String ?? ""
        r.authors = i["authors"] as? [String] ?? []
        r.authorHeading = i["author_heading"] as? String ?? ""
        r.edition = i["edition"] as? String ?? ""
        r.place = i["place"] as? String ?? ""
        r.publisher = i["publisher"] as? String ?? ""
        r.year = i["year"] as? String ?? ""
        r.isbn = i["isbn"] as? String ?? ""
        r.lccn = i["lccn"] as? String ?? ""
        let source = i["call_number_source"] as? String ?? "None"
        if source != "None" {
            r.lcCallNumber = i["lc_call_number"] as? String ?? ""
            r.callNumberSource = source
        }
        r.subjects = i["subjects"] as? [String] ?? []
        r.catalogURL = i["catalog_url"] as? String ?? ""
        r.sources = ["Claude research (web)"]
        return r
    }
}

// MARK: - Cover reading

/// Identifies a book from a photo of its cover or title page.
struct CoverReader {
    struct Result: Codable {
        let title: String
        let subtitle: String
        let authors: [String]
        let publisher: String
        let edition: String
        let isbn: String
        let year: String
        let notes: String
        let confidence: Double
    }

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": ["type": "string"], "subtitle": ["type": "string"],
            "authors": ["type": "array", "items": ["type": "string"]],
            "publisher": ["type": "string"], "edition": ["type": "string"],
            "isbn": ["type": "string"], "year": ["type": "string"],
            "notes": ["type": "string"], "confidence": ["type": "number"]
        ],
        "required": ["title", "subtitle", "authors", "publisher", "edition", "isbn", "year", "notes", "confidence"],
        "additionalProperties": false
    ]

    func identify(jpeg: Data) async throws -> Result {
        let body: [String: Any] = [
            "model": AppSettings.model,
            "max_tokens": 4000,
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": Self.schema]],
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                    ["type": "text", "text": """
                     This is a photo of a book's cover, title page, or copyright page. Identify the book and, \
                     as precisely as the image allows, the edition: title, subtitle, authors (display form), \
                     publisher, edition statement, year, and ISBN if printed (digits only). Use notes for \
                     anything that distinguishes the edition (series, format, printing). Leave unknown fields empty.
                     """]
                ]
            ]]
        ]
        let response = try await ClaudeClient().send(body)
        return try ClaudeClient.decode(Result.self, from: response)
    }
}

// MARK: - Natural-language search

/// Searches the catalog with a natural-language question ("books about housing policy in
/// New Haven", "the yellow MIT Press book about Las Vegas", "everything by Alexander").
struct CatalogSearchService {
    struct Hit: Codable { let index: Int; let reason: String }
    struct Result: Codable { let interpretation: String; let results: [Hit] }

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "interpretation": ["type": "string"],
            "results": ["type": "array", "items": [
                "type": "object",
                "properties": ["index": ["type": "integer"], "reason": ["type": "string"]],
                "required": ["index", "reason"],
                "additionalProperties": false
            ]]
        ],
        "required": ["interpretation", "results"],
        "additionalProperties": false
    ]

    /// `catalog` is one line per book, numbered from 1; results refer to those numbers.
    func search(_ query: String, catalog: String) async throws -> Result {
        let body: [String: Any] = [
            "model": AppSettings.model,
            "max_tokens": 8000,
            "system": [
                ["type": "text", "text": """
                 You search a private library catalog for its owner. Each line is one book: \
                 number | title | authors | date | LC call number | subjects | edition/publisher | \
                 shelf address | spine description | notes. Answer the owner's request by returning \
                 the numbers of the books that match, best first (at most 40), with a short reason \
                 for each. Interpret the request generously: topics, people, places, periods, \
                 physical descriptions ("the thick red one"), locations ("on bookcase B"), and \
                 related subjects all count. Use your knowledge of the books themselves, not just \
                 the words in the catalog. If nothing matches, return an empty list. In \
                 interpretation, restate in a few words what you searched for.
                 """],
                ["type": "text", "text": "CATALOG\n" + catalog, "cache_control": ["type": "ephemeral"]]
            ],
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": Self.schema]],
            "messages": [["role": "user", "content": query]]
        ]
        let response = try await ClaudeClient().send(body, timeout: 120)
        return try ClaudeClient.decode(Result.self, from: response)
    }
}
