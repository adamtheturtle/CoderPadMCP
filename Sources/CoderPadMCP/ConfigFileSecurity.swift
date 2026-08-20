//
//  ConfigFileSecurity.swift
//  CoderPadMCP
//

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

#if os(Linux)
    /// Glibc's module map does not always surface xattr helpers; bind the libc symbol directly.
    @_silgen_name("fgetxattr")
    private func coderpad_fgetxattr(
        _ fd: Int32,
        _ name: UnsafePointer<CChar>?,
        _ value: UnsafeMutableRawPointer?,
        _ size: Int,
    ) -> Int
#endif

func securelyReadConfig(
    path: String,
    explicit: Bool,
    limit: Int,
    afterValidation: () throws -> Void = {},
) throws -> Data? {
    // `fstat` below is the authority on the file type, but opening a FIFO read-only blocks
    // until a writer connects. Nonblocking mode lets us obtain the descriptor and reject
    // special files without allowing a crafted config path to hang server startup.
    let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else {
        if errno == ENOENT, !explicit {
            return nil
        }
        if errno == ENOENT {
            throw MCPConfigLoadError.missingConfig(path: path)
        }
        if errno == ELOOP {
            throw MCPConfigLoadError.symbolicLink(path: path)
        }
        if errno == EACCES {
            throw MCPConfigLoadError.permissionDenied(path: path)
        }
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
        if count == 0 {
            break
        }
        if count < 0 {
            if errno == EINTR {
                continue
            }
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
    #if canImport(Darwin)
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT {
                return false
            }
            throw MCPConfigLoadError.readFailed(path: path)
        }

        acl_free(UnsafeMutableRawPointer(acl))
        return true
    #elseif os(Linux)
        // POSIX ACLs are stored in `system.posix_acl_access`. Probe the already-open
        // descriptor so a path swap cannot hide a grant. Filesystems that cannot
        // report xattrs fail closed: we cannot promise the file is private.
        errno = 0
        let size = coderpad_fgetxattr(descriptor, "system.posix_acl_access", nil, 0)
        if size >= 0 {
            return true
        }
        switch errno {
        case ENODATA:
            return false
        case ENOTSUP, EOPNOTSUPP:
            return true
        default:
            throw MCPConfigLoadError.readFailed(path: path)
        }
    #else
        // No ACL inspection API is available; reject rather than silently skip the check.
        _ = descriptor
        _ = path
        return true
    #endif
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
