import CoderPadToolCore
import Foundation
import Testing

@Suite("Cursor continuations")
struct CursorContinuationTests {
    @Test
    func `URL cursor data retains its query key and decoded opaque value`() {
        let continuation = nextPageContinuation("https://other.example/api/pads?cursor=a%26b%2Bc%3D")
        #expect(continuation == .cursor("a&b+c="))
        #expect(continuation.queryItem == URLQueryItem(name: "cursor", value: "a&b+c="))
        #expect(nextPageContinuation("/api/pads/?cursor=position") == .cursor("position"))
        #expect(nextPageContinuation("?page=2") == .page("2"))
        #expect(nextPageToken("?cursor=position") == nil)
    }

    @Test(arguments: [
        "?cursor=", "?cursor", "?cursor=a&cursor=b", "?cursor=a&page=2",
        "?page=2&cursor=a", "?cursor=a&cursor=a", "?sort=created_at,desc",
    ])
    func `ambiguous or empty continuations remain malformed`(url: String) {
        #expect(nextPageContinuation(url) == .malformed)
    }

    @Test
    func `cursor limits apply to decoded bytes and cycles retain their namespace`() {
        let maximum = String(repeating: "a", count: maxPaginationTokenBytes)
        #expect(nextPageContinuation("?cursor=" + maximum) == .cursor(maximum))
        #expect(nextPageContinuation("?cursor=" + maximum + "a") == .malformed)
        var tracker = PaginationTokenTracker()
        let accepted1 = tracker.accept(.page("same"))
        #expect(accepted1)
        let accepted2 = tracker.accept(.cursor("same"))
        #expect(accepted2)
        let accepted3 = tracker.accept(.cursor("same"))
        #expect(!accepted3)
        let accepted4 = tracker.accept(.page("same"))
        #expect(!accepted4)
        let accepted5 = tracker.accept(.cursor(maximum + "a"))
        #expect(!accepted5)
        let accepted6 = tracker.accept(.finished)
        #expect(!accepted6)
        let accepted7 = tracker.accept(.malformed)
        #expect(!accepted7)
    }
}
