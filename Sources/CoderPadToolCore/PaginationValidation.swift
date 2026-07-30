//
//  PaginationValidation.swift
//  CoderPadToolCore
//
//  Shared MCP argument validation for user-supplied pagination. The remote APIs have
//  different conventions: Interview list tools use 1-based pages, while Screen uses
//  zero-based offsets plus a positive limit. Upper bounds are enforced too (#1612):
//  an enormous page or offset is never a real request, only backend stress or an
//  overflow risk in downstream pagination arithmetic.
//

/// The largest page/offset/limit the tools accept (#1612). Far beyond any real
/// dataset, but small enough that pagination arithmetic can never overflow.
public let maxPaginationPage = 100_000
public let maxPaginationStart = 10_000_000
public let maxPaginationLimit = 1000

public func pageValidationError(_ page: Int?) -> String? {
    guard let page else { return nil }

    if page < 1 {
        return "page must be greater than or equal to 1."
    }
    if page > maxPaginationPage {
        return "page must be \(maxPaginationPage) or less."
    }
    return nil
}

public func screenPaginationValidationError(start: Int?, limit: Int?) -> String? {
    if let start, start < 0 {
        return "start must be greater than or equal to 0."
    }
    if let start, start > maxPaginationStart {
        return "start must be \(maxPaginationStart) or less."
    }
    if let limit, limit < 1 {
        return "limit must be greater than or equal to 1."
    }
    if let limit, limit > maxPaginationLimit {
        return "limit must be \(maxPaginationLimit) or less."
    }
    return nil
}
