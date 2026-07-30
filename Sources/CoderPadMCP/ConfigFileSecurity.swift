//
//  ConfigFileSecurity.swift
//  CoderPadMCP
//

import Darwin
import Foundation

func securelyReadConfig(
    path: String,
    explicit: Bool,
    limit: Int,
    afterValidation: () throws -> Void = {},
) throws -> Data? {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
        if errno == ENOENT, !explicit { return nil }
        if errno == ENOENT { throw MCPConfigLoadError.missingConfig(path: path) }
        if errno == ELOOP { throw MCPConfigLoadError.symbolicLink(path: path) }
        if errno == EACCES { throw MCPConfigLoadError.permissionDenied(path: path) }
        throw MCPConfigLoadError.readFailed(path: path)
    }

    defer { close(descriptor) }

    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
        throw MCPConfigLoadError.readFailed(path: path)
    }
    guard status.st_mode & S_IFMT == S_IFREG else {
        throw MCPConfigLoadError.notRegularFile(path: path)
    }
    guard status.st_uid == geteuid() else {
        throw MCPConfigLoadError.wrongOwner(path: path)
    }
    guard status.st_mode & 0o077 == 0 else {
        throw MCPConfigLoadError.insecurePermissions(path: path)
    }
    guard try !hasExtendedACL(descriptor: descriptor, path: path) else {
        throw MCPConfigLoadError.insecurePermissions(path: path)
    }
    guard status.st_size <= limit else {
        throw MCPConfigLoadError.configTooLarge(path: path, limit: limit)
    }

    try afterValidation()

    var data = Data()
    data.reserveCapacity(min(Int(status.st_size), limit))
    var buffer = [UInt8](repeating: 0, count: 16384)
    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count == 0 { break }
        if count < 0 {
            if errno == EINTR { continue }
            throw MCPConfigLoadError.readFailed(path: path)
        }
        guard data.count <= limit - count else {
            throw MCPConfigLoadError.configTooLarge(path: path, limit: limit)
        }

        data.append(contentsOf: buffer.prefix(count))
    }
    return data
}

private func hasExtendedACL(descriptor: Int32, path: String) throws -> Bool {
    errno = 0
    guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
        if errno == ENOENT { return false }
        throw MCPConfigLoadError.readFailed(path: path)
    }

    acl_free(UnsafeMutableRawPointer(acl))
    return true
}

func classifiedConfigReadError(path: String, error: any Error) -> MCPConfigLoadError {
    let cocoa = error as? CocoaError
    switch cocoa?.code {
    case .fileReadNoSuchFile:
        return .missingConfig(path: path)
    case .fileReadNoPermission:
        return .permissionDenied(path: path)
    default:
        return .readFailed(path: path)
    }
}
