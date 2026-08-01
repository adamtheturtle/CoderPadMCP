import CoderPadToolCore
import Testing

@Test func `core validation is runnable`() {
    #expect(positiveID(1) == 1)
    #expect(positiveID(0) == nil)
}

@Test func `pagination token tracker rejects a cycle`() {
    var tracker = PaginationTokenTracker()
    let first = tracker.accept("page-2")
    let second = tracker.accept("page-3")
    let repeated = tracker.accept("page-2")
    #expect(first)
    #expect(second)
    #expect(!repeated)
}

@Test func `pad record tracker deduplicates ids and rejects missing identity`() {
    var tracker = RecordIdentityTracker()
    let first = tracker.acceptPad(["id": " pad-1 "])
    let duplicate = tracker.acceptPad(["slug": "pad-1"])
    let numeric = tracker.acceptPad(["id": 42])
    let missing = tracker.acceptPad(["title": "Missing"])
    #expect(first == .accepted)
    #expect(duplicate == .duplicate)
    #expect(numeric == .accepted)
    #expect(missing == .invalid)
}

@Test func `question record tracker deduplicates positive ids`() {
    var tracker = RecordIdentityTracker()
    let first = tracker.acceptQuestion(["id": 42])
    let duplicate = tracker.acceptQuestion(["id": " 42 "])
    let zero = tracker.acceptQuestion(["id": 0])
    let missing = tracker.acceptQuestion(["title": "Missing"])
    #expect(first == .accepted)
    #expect(duplicate == .duplicate)
    #expect(zero == .invalid)
    #expect(missing == .invalid)
}

@Test func `aggregate fields ignore surrounding whitespace`() {
    #expect(aggregateField(for: " owner ") == "owner_email")
    #expect(questionAggregateField(for: "\n language\t") == "language")
}

@Test func `pad filter echo matches applied filters`() {
    #expect(filtersEcho(owner: "  ", state: "\nstarted ", language: " Swift ") as? [String: String] == [
        "state": "started",
        "language": "Swift",
    ])
}

@Test func `question filter echo matches applied filters`() {
    let filters = questionFiltersEcho(owner: " ", author: "\nAda ", language: "\t", type: " live ")
    #expect(filters as? [String: String] == ["author": "Ada", "type": "live"])
}

@Test func `pad title validation enforces the API limit`() {
    #expect(padTitleValidationError(String(repeating: "a", count: 255)) == nil)
    #expect(padTitleValidationError(String(repeating: "a", count: 256)) == "title must be at most 255 characters.")
}

@Test func `pad update title validation rejects blank values`() {
    #expect(padUpdateTitleValidationError(nil) == nil)
    #expect(padUpdateTitleValidationError("Interview") == nil)
    #expect(padUpdateTitleValidationError("") == "title must not be empty or whitespace-only.")
    #expect(padUpdateTitleValidationError(" \n\t") == "title must not be empty or whitespace-only.")
}

@Test func `pad owner email validation rejects malformed addresses`() {
    for email in [
        "not an address", "a@localhost", "a@@example.com", "a@example..com",
        " a@example.com", "a@example.com\n", "a@-example.com", "ü@example.com",
    ] {
        #expect(ownerEmailValidationError(email) != nil)
    }
    #expect(ownerEmailValidationError("ada.lovelace+interview@example.co.uk") == nil)
    #expect(ownerEmailValidationError(nil) == nil)
}

@Test func `create pad language validation canonicalizes supported codes`() {
    #expect(validatedCreatePadLanguage(" Python3 \n") == "python3")
    #expect(validatedCreatePadLanguage("OBJECTIVE-C") == "objective-c")
    #expect(validatedCreatePadLanguage("react") == nil)
    #expect(validatedCreatePadLanguage("definitely-not-a-language") == nil)
    #expect(createPadLanguageValidationError("react")?.contains("python3") == true)
}

@Test func `pad filenames reject traversal and remain unique`() {
    let environment = PadCodeEnvironment(id: 1, object: [
        "file_contents": [
            ["path": "../../secret.txt", "contents": "first"],
            ["path": #"..\secret.txt"#, "contents": "windows traversal"],
            ["path": #"C:\temp\payload.swift"#, "contents": "windows absolute"],
            ["path": "/etc/passwd", "contents": "posix absolute"],
            ["path": "main.txt", "contents": "second"],
            ["path": "main.txt", "contents": "third"],
        ],
    ])
    let files = padCodeFiles(pad: [:], environments: [environment], maxFileChars: nil)

    #expect(files.compactMap { $0["filename"] as? String } == [
        "main.txt", "main-2.txt", "main-3.txt", "main-4.txt", "main-5.txt", "main-6.txt",
    ])
}

@Test func `pad filename limits count UTF-8 bytes`() {
    let environment = PadCodeEnvironment(id: 1, object: [
        "file_contents": [["path": String(repeating: "🦺", count: 65), "contents": "code"]],
    ])
    let files = padCodeFiles(pad: [:], environments: [environment], maxFileChars: nil)

    #expect(files.first?["filename"] as? String == "main.txt")
}

@Test func `pad file language metadata is bounded and control-free`() {
    let environment = PadCodeEnvironment(id: 1, object: [
        "language": "swift",
        "file_contents": [
            ["path": "first.swift", "language": "bad\nvalue", "contents": "one"],
            ["path": "second.swift", "language": String(repeating: "x", count: 101), "contents": "two"],
            ["path": "third.swift", "language": "ruby", "contents": "three"],
        ],
    ])
    let files = padCodeFiles(pad: [:], environments: [environment], maxFileChars: nil)

    #expect(files[0]["language"] as? String == "swift")
    #expect(files[1]["language"] as? String == "swift")
    #expect(files[2]["language"] as? String == "ruby")
}

@Test func `pad filenames are unique on case-insensitive filesystems`() {
    let environment = PadCodeEnvironment(id: 1, object: [
        "file_contents": [
            ["path": "A.swift", "contents": "one"],
            ["path": "a.swift", "contents": "two"],
        ],
    ])
    let files = padCodeFiles(pad: [:], environments: [environment], maxFileChars: nil)

    #expect(files.compactMap { $0["filename"] as? String } == ["A.swift", "a-2.swift"])
}

@Test func `pad filenames avoid file and directory conflicts`() {
    let environment = PadCodeEnvironment(id: 1, object: [
        "file_contents": [
            ["path": "src", "contents": "file"],
            ["path": "src/main.swift", "contents": "nested"],
            ["path": "lib/main.swift", "contents": "nested first"],
            ["path": "lib", "contents": "file second"],
        ],
    ])
    let files = padCodeFiles(pad: [:], environments: [environment], maxFileChars: nil)

    #expect(files.compactMap { $0["filename"] as? String } == [
        "src", "src-main.swift", "lib/main.swift", "lib-2",
    ])
}

@Test func `aggregate values trim whitespace and classify blanks`() {
    let records: [[String: Any]] = [
        ["owner_email": "  ada@example.com \n"],
        ["owner_email": "\t "],
        [:],
    ]

    #expect(aggregateCounts(pads: records, field: "owner_email") == [
        "ada@example.com": 1,
        aggregateMissingGroup: 2,
    ])
}

@Test func `month aggregation rejects malformed timestamps`() {
    let records: [[String: Any]] = [
        ["created_at": "not-a-date"],
        ["created_at": "2026-07-29T12:30:00Z"],
    ]

    #expect(aggregateCounts(pads: records, field: "month") == [
        "2026-07": 1,
        aggregateMissingGroup: 1,
    ])
}

@Test func `HTTP errors expose no response body data`() {
    let secret = String(repeating: "sensitive-token-", count: 20)
    let message = sanitizedHTTPErrorMessage(
        status: 502,
        body: "<html>\n\(secret)\n\(String(repeating: "proxy failure ", count: 1000))</html>",
    )

    #expect(message.hasPrefix("HTTP 502 [body-id: "))
    #expect(!message.contains(secret))
    #expect(!message.contains("response body"))
    #expect(!message.contains("secret123456789"))
    #expect(!sanitizedHTTPErrorMessage(
        status: 404,
        body: "candidate ada.lovelace+interview@example.co.uk used secret123456789",
    ).contains("ada.lovelace"))
}

@Test func `HTTP error diagnostic identifiers are stable and distinguish bodies`() {
    let first = sanitizedHTTPErrorMessage(status: 500, body: "first failure")
    let repeated = sanitizedHTTPErrorMessage(status: 500, body: "first failure")
    let second = sanitizedHTTPErrorMessage(status: 500, body: "second failure")

    #expect(first == repeated)
    #expect(first != second)
    #expect(!second.contains("second failure"))
}
