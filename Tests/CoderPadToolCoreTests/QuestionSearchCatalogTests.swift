import CoderPadToolCore
import Testing

@Suite("Question search catalog")
struct QuestionSearchCatalogTests {
    @Test
    func `question sorts extend the pad sorts without changing them`() {
        #expect(normalizedQuestionPagingSort("title") == "title,desc")
        #expect(normalizedQuestionPagingSort("used,asc") == "used,asc")
        #expect(normalizedQuestionPagingSort("-used") == "used,desc")
        #expect(normalizedQuestionPagingSort("created_at,desc") == "created_at,desc")
        #expect(normalizedQuestionPagingSort("state") == nil)
        #expect(normalizedQuestionPagingSort("title,ascending") == nil)
        #expect(normalizedQuestionPagingSort("title,asc,desc") == nil)
        #expect(normalizedQuestionPagingSort("") == nil)
        #expect(normalizedQuestionPagingSort(nil) == nil)
        #expect(normalizedPagingSort("title") == nil)
        #expect(questionSearchProperties["pad_types"]?["maxItems"] as? Int == 100)
        #expect(questionSearchProperties["text"]?["maxLength"] as? Int == 4096)
    }
}
