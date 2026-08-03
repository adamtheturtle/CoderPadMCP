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

/// The largest page/offset values the tools accept (#1612). Far beyond any real
/// dataset, but small enough that pagination arithmetic can never overflow.
public let maxPaginationPage = 100_000
public let maxPaginationStart = 10_000_000
/// CoderPad Screen v1.1 documents 50 as the maximum tests-page size.
public let maxPaginationLimit = 50

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

/// Converts paging sort values to CoderPad's `field,direction` syntax. The
/// leading-minus spelling was advertised by older server versions, so retain it
/// as a compatibility alias rather than sending it upstream where it causes a 500.
public func normalizedPagingSort(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }

    if value.first == "-" {
        let field = String(value.dropFirst())
        return isPagingSortField(field) ? "\(field),desc" : nil
    }

    let components = value.split(separator: ",", omittingEmptySubsequences: false)
    if components.count == 1, isPagingSortField(value) {
        return "\(value),asc"
    }
    guard components.count == 2,
          isPagingSortField(String(components[0])),
          components[1] == "asc" || components[1] == "desc"
    else { return nil }

    return value
}

/// Returns a client-facing error for malformed sort values before they reach the
/// CoderPad API. An absent sort remains valid.
public func pagingSortValidationError(_ value: String?) -> String? {
    guard value != nil else { return nil }
    guard normalizedPagingSort(value) != nil else {
        return "sort must name a field, optionally followed by asc or desc, such as created_at,desc."
    }
    return nil
}

private func isPagingSortField(_ value: String) -> Bool {
    !value.isEmpty && value.unicodeScalars.allSatisfy {
        (0x61 ... 0x7A).contains($0.value)
            || (0x41 ... 0x5A).contains($0.value)
            || (0x30 ... 0x39).contains($0.value)
            || $0.value == 0x5F
    }
}
