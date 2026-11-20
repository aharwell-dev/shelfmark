import Foundation
import CoreGraphics

/// One spine as read by the vision model, in the coordinate space of the image it was given.
struct SpineReading: Codable, Hashable, Sendable {
    var title: String
    var authors: [String]
    var spineText: String
    var publisher: String
    var xStart: Double
    var xEnd: Double
    var yTop: Double
    var yBottom: Double
    var primaryColor: String
    var accentColor: String
    var graphicNotes: String
    var confidence: Double

    enum CodingKeys: String, CodingKey {
        case title, authors, publisher, confidence
        case spineText = "spine_text"
        case xStart = "x_start", xEnd = "x_end", yTop = "y_top", yBottom = "y_bottom"
        case primaryColor = "primary_color", accentColor = "accent_color"
        case graphicNotes = "graphic_notes"
    }
}

enum ClaudeError: LocalizedError {
    case missingKey
    case http(Int, String)
    case refused(String)
    case truncated
    case badResponse(String)
    case stream(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Add your Claude API key in Settings before scanning."
        case .http(let code, let body): return "Claude API error \(code): \(body.prefix(300))"
        case .refused(let why): return "The request was declined: \(why)"
        case .truncated: return "The response was cut off. Try a photo of fewer books."
        case .badResponse(let s): return "Unexpected response: \(s.prefix(200))"
        case .stream(let s): return "Claude reported an error: \(s)"
        }
    }
}

/// Calls the Claude Messages API over HTTPS (there is no official Swift SDK, so this uses raw HTTP).
struct ClaudeVisionService {
    var apiKey: String = AppSettings.apiKey
    var model: String = AppSettings.model
    var effort: String = AppSettings.effort

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private static let systemPrompt = """
    You are an expert rare-book librarian and book designer who can identify books from their \
    spines alone. You are shown a photograph of part of a bookshelf. Identify every book whose \
    spine is visible, working strictly from LEFT to RIGHT.

    Use every clue on the spine together: title and author lettering, typeface, spine colors, \
    bands and rules, series design (e.g. Penguin Classics black with orange band, Library of \
    America black with flag stripes, Everyman's Library, Loeb red/green, Taschen, Phaidon, MIT \
    Press, university press house styles), publisher logos and colophons at the foot of the spine. \
    When lettering is partly unreadable, combine the readable fragments with color and graphic \
    design to infer the most likely edition, and lower your confidence accordingly.

    For each spine give its horizontal extent (x_start, x_end) and vertical extent (y_top, y_bottom) \
    as fractions 0–1 of the image width and height, origin at top-left. Adjacent spines should \
    not overlap. Colors are hex like #1A2B3C: primary_color is the dominant spine color, \
    accent_color the most prominent lettering or band color. graphic_notes briefly describes the \
    design (e.g. "cream spine, red serif caps, black publisher torch at foot"). spine_text is the \
    literal visible text. confidence is 0–1 for the title/author identification.

    Include spines you cannot identify, with title set to an empty string, so the shelf positions \
    stay correct. Do not include objects that are not books. Return only the JSON.
    """

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "books": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "authors": ["type": "array", "items": ["type": "string"]],
                        "spine_text": ["type": "string"],
                        "publisher": ["type": "string"],
                        "x_start": ["type": "number"],
                        "x_end": ["type": "number"],
                        "y_top": ["type": "number"],
                        "y_bottom": ["type": "number"],
                        "primary_color": ["type": "string"],
                        "accent_color": ["type": "string"],
                        "graphic_notes": ["type": "string"],
                        "confidence": ["type": "number"]
                    ],
                    "required": ["title", "authors", "spine_text", "publisher", "x_start", "x_end",
                                 "y_top", "y_bottom", "primary_color", "accent_color",
                                 "graphic_notes", "confidence"],
                    "additionalProperties": false
                ]
            ]
        ],
        "required": ["books"],
        "additionalProperties": false
    ]

    /// Reads all spines in one image (a tile of a shelf photo), streaming progress as it goes.
    ///
    /// `onEvent` is called from a background task for every server event, so the UI can show
    /// that the request is alive, what Claude is examining, and each title as it is written.
    func readSpines(jpeg: Data, ocrHints: [String],
                    onEvent: @escaping @Sendable (SpineStreamEvent) -> Void = { _ in }) async throws -> [SpineReading] {
        guard !apiKey.isEmpty else { throw ClaudeError.missingKey }

        var userText = "Identify every book spine in this shelf photo, left to right."
        if !ocrHints.isEmpty {
            userText += "\n\nOn-device OCR found these text fragments (roughly left to right; may contain errors):\n"
            userText += ocrHints.prefix(160).joined(separator: " · ")
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 32000,
            "stream": true,
            "system": Self.systemPrompt,
            // Summarized thinking costs nothing extra and lets the app show what Claude is examining.
            "thinking": ["type": "adaptive", "display": "summarized"],
            "output_config": [
                "effort": effort,
                "format": ["type": "json_schema", "schema": Self.schema]
            ],
            // If a safety classifier declines, let the API retry on a fallback model in the same call.
            "fallbacks": "default",
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/jpeg",
                                "data": jpeg.base64EncodedString()]],
                    ["type": "text", "text": userText]
                ]
            ]]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // With streaming this is the longest allowed silence between packets, not the total time.
        // The server sends keep-alive pings, so a stall this long means the connection is dead.
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        onEvent(.uploading(bytes: jpeg.count))
        let bytes = try await openStream(request, onEvent: onEvent)
        onEvent(.connected)

        var text = ""
        var thinking = ""
        var stopReason: String?
        var refusalExplanation: String?
        var lastTitleCount = 0
        var lastThoughtEmit = Date.distantPast

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            onEvent(.heartbeat)

            switch event["type"] as? String {
            case "content_block_delta":
                let delta = event["delta"] as? [String: Any] ?? [:]
                switch delta["type"] as? String {
                case "text_delta":
                    text += delta["text"] as? String ?? ""
                    let titles = Self.partialTitles(in: text)
                    if titles.count != lastTitleCount {
                        lastTitleCount = titles.count
                        onEvent(.writing(titles: titles))
                    }
                case "thinking_delta":
                    thinking += delta["thinking"] as? String ?? ""
                    if Date().timeIntervalSince(lastThoughtEmit) > 0.6, let snippet = Self.latestThought(thinking) {
                        lastThoughtEmit = Date()
                        onEvent(.thinking(snippet))
                    }
                default: break
                }
            case "content_block_start":
                let block = event["content_block"] as? [String: Any] ?? [:]
                if block["type"] as? String == "fallback" { onEvent(.fellBack) }
                if block["type"] as? String == "text" && text.isEmpty { onEvent(.writing(titles: [])) }
            case "message_delta":
                let delta = event["delta"] as? [String: Any] ?? [:]
                if let reason = delta["stop_reason"] as? String { stopReason = reason }
                if let details = delta["stop_details"] as? [String: Any] {
                    refusalExplanation = details["explanation"] as? String
                }
            case "error":
                let err = event["error"] as? [String: Any] ?? [:]
                throw ClaudeError.stream(err["message"] as? String ?? "The stream ended with an error.")
            default:
                break
            }
        }

        if stopReason == "refusal" { throw ClaudeError.refused(refusalExplanation ?? "no explanation") }
        if stopReason == "max_tokens" { throw ClaudeError.truncated }
        guard let textData = text.data(using: .utf8), !text.isEmpty else {
            throw ClaudeError.badResponse("The response contained no results.")
        }
        struct Envelope: Codable { let books: [SpineReading] }
        do {
            return try JSONDecoder().decode(Envelope.self, from: textData).books
        } catch {
            throw ClaudeError.badResponse("Couldn't read the results: \(text.prefix(120))")
        }
    }

    /// Opens the event stream, retrying rate limits and server errors before any data has arrived.
    private func openStream(_ request: URLRequest, attempts: Int = 3,
                            onEvent: @Sendable (SpineStreamEvent) -> Void) async throws -> URLSession.AsyncBytes {
        var delay: UInt64 = 2_000_000_000
        for attempt in 1...attempts {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ClaudeError.badResponse("no HTTP response") }
            if http.statusCode == 200 { return bytes }

            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 2000 { break } }
            let retryable = [408, 429, 500, 502, 503, 504, 529].contains(http.statusCode)
            guard retryable, attempt < attempts else { throw ClaudeError.http(http.statusCode, body) }

            var wait = delay
            if let ra = http.value(forHTTPHeaderField: "retry-after"), let s = Double(ra) { wait = UInt64(s * 1_000_000_000) }
            onEvent(.retrying(attempt: attempt + 1, of: attempts, reason: http.statusCode == 429 ? "rate limited" : "server busy"))
            try await Task.sleep(nanoseconds: wait)
            delay *= 2
        }
        throw ClaudeError.badResponse("retries exhausted")
    }

    /// Titles of every book object completed so far in a partial JSON response.
    static func partialTitles(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return titleRegex.matches(in: text, range: range).compactMap { m in
            Range(m.range(at: 1), in: text).map { String(text[$0]).replacingOccurrences(of: "\\\"", with: "\"") }
        }
    }

    private static let titleRegex = try! NSRegularExpression(pattern: #""title"\s*:\s*"((?:[^"\\]|\\.)*)""#)

    /// The most recent line of Claude's summarized reasoning, trimmed for display.
    static func latestThought(_ thinking: String) -> String? {
        let lines = thinking.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 8 }
        guard var last = lines.last else { return nil }
        last = last.replacingOccurrences(of: "**", with: "")
        return last.count > 140 ? "…" + last.suffix(139) : last
    }
}

/// Progress reported while a spine-reading request streams.
enum SpineStreamEvent: Sendable {
    case uploading(bytes: Int)
    case retrying(attempt: Int, of: Int, reason: String)
    case connected
    case heartbeat
    case thinking(String)
    case writing(titles: [String])
    case fellBack
}
