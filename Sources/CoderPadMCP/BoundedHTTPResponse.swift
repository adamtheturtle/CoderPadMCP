import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct BoundedHTTPResponseError: LocalizedError, Equatable, Sendable {
    let limit: Int

    var errorDescription: String? {
        "Response exceeded the \(limit)-byte safety limit."
    }
}

struct BoundedDataBuffer: Sendable {
    let limit: Int
    private(set) var data = Data()

    init(limit: Int) {
        self.limit = limit
        data.reserveCapacity(min(limit, 64 * 1024))
    }

    mutating func append(_ chunk: Data) throws {
        guard chunk.count <= limit - data.count else {
            throw BoundedHTTPResponseError(limit: limit)
        }
        data.append(chunk)
    }
}

func boundedResponseData(
    for request: URLRequest,
    limit: Int,
) async throws -> (Data, URLResponse) {
    precondition(limit > 0)
    return try await BoundedHTTPResponseLoader(limit: limit).load(request)
}

private final class BoundedHTTPResponseLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var buffer: BoundedDataBuffer
    private var response: URLResponse?
    private var continuation: CheckedContinuation<(Data, URLResponse), any Error>?
    private var session: URLSession?
    private var finished = false

    init(limit: Int) {
        self.limit = limit
        buffer = BoundedDataBuffer(limit: limit)
    }

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
                self.session = session
                lock.unlock()
                session.dataTask(with: request).resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void,
    ) {
        if response.expectedContentLength > Int64(limit) {
            completionHandler(.cancel)
            finish(.failure(BoundedHTTPResponseError(limit: limit)))
            return
        }

        lock.lock()
        self.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        do {
            try buffer.append(data)
            lock.unlock()
        } catch {
            lock.unlock()
            dataTask.cancel()
            finish(.failure(error))
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure(error))
            return
        }

        lock.lock()
        let response = response
        let data = buffer.data
        lock.unlock()
        guard let response else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        finish(.success((data, response)))
    }

    private func cancel() {
        lock.lock()
        let session = session
        lock.unlock()
        session?.invalidateAndCancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<(Data, URLResponse), any Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}
