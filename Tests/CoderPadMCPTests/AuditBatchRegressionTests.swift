@testable import CoderPadMCP
@testable import CoderPadToolCore
import Foundation
import MCP
import Testing

@Suite("Audit batch regressions")
struct AuditBatchRegressionTests {
    @Test
    func `compare_pads requires at least two distinct pad ids`() {
        #expect(throws: PromptError.invalidArgument(
            name: "pad_ids",
            reason: "must contain at least 2 distinct pads",
        )) {
            try renderPrompt(name: "compare_pads", arguments: ["pad_ids": "only-one"])
        }
        #expect(throws: PromptError.invalidArgument(
            name: "pad_ids",
            reason: "must not contain duplicate pad identifiers",
        )) {
            try renderPrompt(name: "compare_pads", arguments: ["pad_ids": "same, same"])
        }
    }

    @Test
    func `draft_question rejects invalid optional arguments`() {
        let oversized = String(repeating: "a", count: maximumPromptArgumentUTF8Length + 1)
        #expect(throws: PromptError.invalidArgument(
            name: "language",
            reason: "must be at most \(maximumPromptArgumentUTF8Length) UTF-8 bytes",
        )) {
            try renderPrompt(
                name: "draft_question",
                arguments: ["topic": "graphs", "language": oversized],
            )
        }
        #expect(throws: PromptError.invalidArgument(
            name: "difficulty",
            reason: "must not contain Unicode format controls",
        )) {
            try renderPrompt(
                name: "draft_question",
                arguments: ["topic": "graphs", "difficulty": "easy\u{202E}"],
            )
        }
    }

    @Test
    func `raw JSON success requires object or array shapes`() {
        #expect(isValidJSONObjectOrArray(Data(#"{"ok":true}"#.utf8)))
        #expect(isValidJSONObjectOrArray(Data("[1]".utf8)))
        #expect(!isValidJSONObjectOrArray(Data("null".utf8)))
        #expect(!isValidJSONObjectOrArray(Data("true".utf8)))
        #expect(!isValidJSONObjectOrArray(Data("42".utf8)))
        #expect(!isValidJSONObjectOrArray(Data(#""text""#.utf8)))
        #expect(apiErrorEnvelopeMessage(in: Data(#"{"status":"ERROR","message":"nope"}"#.utf8)) != nil)
        #expect(apiErrorEnvelopeMessage(in: Data(#"{"status":"ok"}"#.utf8)) == nil)
    }

    @Test
    func `toolResult rejects HTTP 200 error envelopes and scalar JSON`() {
        let errorEnvelope = toolResult(APIResponse(
            status: 200,
            body: #"{"status":"ERROR","message":"gateway failed"}"#,
        ))
        #expect(errorEnvelope.isError == true)

        let scalar = toolResult(APIResponse(status: 200, body: "null"))
        #expect(scalar.isError == true)

        let transport = toolResult(transportFailureResponse(.timeout))
        #expect(transport.isError == true)
        guard case let .text(text, _, _)? = transport.content.first else {
            Issue.record("expected text")
            return
        }
        #expect(text == "Transport failure: timeout")
    }

    @Test
    func `screen ids stay within int32 and candidate emails follow kit length`() {
        #expect(positiveScreenID(maximumScreenID) == maximumScreenID)
        #expect(positiveScreenID(maximumScreenID + 1) == nil)
        #expect(maxScreenCandidateEmailCharacters > maxOwnerEmailBytes)
        let local = String(repeating: "a", count: 64)
        let domain = (0 ..< 4).map { _ in String(repeating: "d", count: 50) }.joined(separator: ".") + ".com"
        let longEmail = "\(local)@\(domain)"
        #expect(longEmail.utf8.count > maxOwnerEmailBytes)
        #expect(longEmail.count <= maxScreenCandidateEmailCharacters)
        #expect(ownerEmailValidationError(longEmail) != nil)
        #expect(screenCandidateEmailValidationError(longEmail) == nil)
        #expect(screenCandidateEmailValidationError(
            String(repeating: "a", count: maxScreenCandidateEmailCharacters) + "@x.co",
        ) != nil)
    }

    @Test
    func `date bounds reject impossible timestamps and offsets`() {
        #expect(dateBoundValidationError(after: "2026-02-30T00:00:00Z", before: nil) != nil)
        #expect(dateBoundValidationError(after: "2026-01-01T24:00:00Z", before: nil) != nil)
        #expect(dateBoundValidationError(after: "2026-01-01T00:00:00+24:00", before: nil) != nil)
        #expect(dateBoundValidationError(after: "2026-01-01T00:00:00+99:99", before: nil) != nil)
        #expect(dateBoundValidationError(after: "2026-01-01T00:00:00Z", before: nil) == nil)
    }

    @Test
    func `fractional final-second ranges and padded created_at are accepted`() {
        #expect(dateBoundValidationError(
            after: "2026-01-31T23:59:59.500Z",
            before: "2026-01",
        ) == nil)
        let padded: [String: Any] = ["created_at": " 2026-01-15T12:00:00Z "]
        #expect(withinDateRange(padded, after: "2026-01", before: "2026-01"))
        #expect(createdAtPresence(padded) == .present)
        #expect(createdAtPresence(["created_at": "not-a-date"]) == .malformed)
    }

    @Test
    func `aggregate sentinels and distinct cardinality stay collision-proof`() {
        var sentinels = AggregateAccumulation()
        accumulateCounts(
            &sentinels,
            pads: [
                ["language": aggregateMissingGroup],
                ["language": aggregateMissingGroup + " [literal value]"],
                ["language": aggregateLiteralPrefix + "x"],
            ],
            field: "language",
        )
        #expect(sentinels.counts[aggregateLiteralPrefix + aggregateMissingGroup] == 1)
        #expect(sentinels.counts[aggregateMissingGroup + " [literal value]"] == 1)
        #expect(sentinels.counts[aggregateLiteralPrefix + aggregateLiteralPrefix + "x"] == 1)

        var accumulation = AggregateAccumulation()
        let pads = (0 ..< (maxAggregateGroups + 5)).map { ["language": "lang-\($0)"] }
        accumulateCounts(&accumulation, pads: pads, field: "language")
        #expect(accumulation.counts[aggregateOverflowGroup] != nil)
        #expect(accumulation.distinctGroups > accumulation.counts.count)
    }

    @Test
    func `interview type aliases fold only known spellings`() {
        #expect(canonicalInterviewType("take-home") == "takehome")
        #expect(canonicalInterviewType("take_home") == "takehome")
        #expect(canonicalInterviewType("a-b") == "a-b")
        #expect(canonicalInterviewType("a_b") == "a_b")
        var accumulation = AggregateAccumulation()
        accumulateCounts(
            &accumulation,
            pads: [
                ["pad_type": "take-home"],
                ["pad_type": "take_home"],
                ["pad_type": "a-b"],
                ["pad_type": "a_b"],
            ],
            field: "pad_type",
        )
        #expect(accumulation.counts["takehome"] == 2)
        #expect(accumulation.counts["a-b"] == 1)
        #expect(accumulation.counts["a_b"] == 1)
    }

    @Test
    func `compact scalars keep ellipsis inside character and UTF-8 caps`() {
        let long = String(repeating: "a", count: maxCompactScalarCharacters + 10)
        let truncated = compactScalar(long) as? String
        #expect(truncated?.count == maxCompactScalarCharacters)
        #expect(truncated?.hasSuffix("…") == true)

        let heavy = String(repeating: "🦺", count: 2000)
        let utf8Truncated = compactScalar(heavy) as? String
        #expect((utf8Truncated?.utf8.count ?? .max) <= maxCompactScalarUTF8Bytes)
        #expect(utf8Truncated?.hasSuffix("…") == true)

        #expect(compactPaginationMetadata(["nested": 1]) == nil)
        #expect(compactPaginationMetadata(12) as? Int64 == 12)
        #expect(compactPaginationMetadata(true) == nil)
    }
}
