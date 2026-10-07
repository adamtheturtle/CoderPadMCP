import Foundation

/// Loads an explicitly selected binary archive. Hosts can resolve their own binary resource URIs.
/// The loader must honor cancellation and the supplied byte limit. No URI is discovered implicitly.
public typealias CoderPadMCPArchiveInput = @Sendable (_ uri: String, _ maximumBytes: Int) async throws -> Data

let fileArchiveInput: CoderPadMCPArchiveInput = { uri, maximumBytes in
    guard let url = URL(string: uri), url.isFileURL, url.path.hasPrefix("/"),
          url.host == nil || url.host == "" || url.host == "localhost",
          url.query == nil, url.fragment == nil
    else {
        throw ScreenArchiveInputError.invalidURI
    }
    let task = Task.detached {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ScreenArchiveInputError.invalidURI }
        guard let size = values.fileSize, size <= maximumBytes else { throw ScreenArchiveInputError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let remaining = maximumBytes - data.count
            guard let chunk = try handle.read(upToCount: min(65536, remaining + 1)), !chunk.isEmpty else { break }
            guard chunk.count <= remaining else { throw ScreenArchiveInputError.tooLarge }
            data.append(chunk)
        }
        return data
    }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

enum ScreenArchiveInputError: Error {
    case invalidURI
    case tooLarge
}
