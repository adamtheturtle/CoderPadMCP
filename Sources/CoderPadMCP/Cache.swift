import Foundation

/// Cache record categories understood by CoderPad MCP.
public enum CoderPadMCPRecordKind: String, Sendable {
    case pads
    case questions
}

/// Maximum encoded JSON blob accepted from a host cache hook before parse.
public let maxCoderPadMCPCacheBytes = 8 * 1024 * 1024

/// Optional host cache hooks used by embedded providers.
///
/// The cache returns encoded JSON arrays to keep the public boundary Sendable and
/// independent of a host application's model types. The standalone server does not
/// install a cache.
public struct CoderPadMCPCache: Sendable {
    public typealias Load = @Sendable (
        _ kind: CoderPadMCPRecordKind,
        _ accountID: String,
        _ requireFresh: Bool,
    ) -> Data?
    public typealias Invalidate = @Sendable (
        _ kind: CoderPadMCPRecordKind,
        _ accountID: String,
    ) async -> Void

    public let load: Load
    public let invalidate: Invalidate

    public init(load: @escaping Load, invalidate: @escaping Invalidate) {
        self.load = load
        self.invalidate = invalidate
    }
}
