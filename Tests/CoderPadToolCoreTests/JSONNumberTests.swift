import CoderPadToolCore
import Foundation
import Testing

@Suite("Parsed JSON numeric values")
struct JSONNumberTests {
    @Test
    func `numbers zero and one remain distinct from booleans`() throws {
        let values = try #require(JSONSerialization.jsonObject(with: Data("[0,1,2,true,false]".utf8)) as? [Any])
        #expect(values.map(isJSONBoolean) == [false, false, false, true, true])
        #expect(isJSONBoolean(true))
        #expect(isJSONBoolean(false))
        #expect(!isJSONBoolean(0))
        #expect(!isJSONBoolean(1))
        #expect(!isJSONBoolean(nil))
        #expect(!isJSONBoolean("true"))
        #expect(nextPageContinuation(values[1]) == .page("1"))
        #expect(nextPageContinuation(values[3]) == .malformed)
        #expect(compactPaginationMetadata(values[0]) as? Int64 == 0)
        #expect(compactPaginationMetadata(values[1]) as? Int64 == 1)
        #expect(compactPaginationMetadata(values[3]) == nil)
        var questions = RecordIdentityTracker()
        let booleanQuestion = questions.acceptQuestion(["id": values[3]])
        let numericQuestion = questions.acceptQuestion(["id": values[1]])
        #expect(booleanQuestion == .invalid)
        #expect(numericQuestion == .accepted)
        var pads = RecordIdentityTracker()
        let booleanPad = pads.acceptPad(["id": values[3]])
        let numericPad = pads.acceptPad(["id": values[1]])
        #expect(booleanPad == .invalid)
        #expect(numericPad == .accepted)
        let environments = parsePadEnvironmentIDs(in: ["pad_environment_ids": [values[1], values[3], values[2]]])
        #expect(environments.ids == [1, 2])
        #expect(environments.rejectedElement)
    }
}
