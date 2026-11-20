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

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Add your Claude API key in Settings before scanning."
        case .http(let code, let body): return "Claude API error \(code): \(body.prefix(300))"
        case .refused(let why): return "The request was declined: \(why)"
        case .truncated: return "The response was cut off. Try a photo of fewer books."
        case .badResponse(let s): return "Unexpected response: \(s.prefix(200))"
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

    /// Reads all spines in one image (a tile of a shelf photo).
    func readSpines(jpeg: Data, ocrHints: [String]) async throws -> [SpineReading] {
        guard !apiKey.isEmpty else { throw ClaudeError.missingKey }

        var userText = "Identify every book spine in this shelf photo, left to right."
        if !ocrHints.isEmpty {
            userText += "\n\nOn-device OCR found these text fragments (roughly left to right; may contain errors):\n"
            userText += ocrHints.prefix(160).joined(separator: " · ")
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": Self.systemPrompt,
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
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await sendWithRetry(request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.badResponse("no HTTP response") }
        guard http.statusCode == 200 else {
            throw ClaudeError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.badResponse(String(data: data, encoding: .utf8) ?? "")
        }
        let stopReason = json["stop_reason"] as? String
        if stopReason == "refusal" {
            let details = (json["stop_details"] as? [String: Any])?["explanation"] as? String
            throw ClaudeError.refused(details ?? "no explanation")
        }
        if stopReason == "max_tokens" { throw ClaudeError.truncated }

        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let text = blocks.last(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let textData = text.data(using: .utf8) else {
            throw ClaudeError.badResponse("no text block")
        }
        struct Envelope: Codable { let books: [SpineReading] }
        return try JSONDecoder().decode(Envelope.self, from: textData).books
    }

    /// Retries rate limits, overloads and server errors with exponential backoff.
    private func sendWithRetry(_ request: URLRequest, attempts: Int = 4) async throws -> (Data, URLResponse) {
        var delay: UInt64 = 2_000_000_000
        for attempt in 1...attempts {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse,
                   [408, 429, 500, 502, 503, 504, 529].contains(http.statusCode), attempt < attempts {
                    if let ra = http.value(forHTTPHeaderField: "retry-after"), let s = Double(ra) {
                        try await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
                    } else {
                        try await Task.sleep(nanoseconds: delay)
                    }
                    delay *= 2
                    continue
                }
                return (data, response)
            } catch let error as URLError where attempt < attempts && error.code != .cancelled {
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
        }
        throw ClaudeError.badResponse("retries exhausted")
    }
}
