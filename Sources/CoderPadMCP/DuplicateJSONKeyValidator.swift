//
//  DuplicateJSONKeyValidator.swift
//  CoderPadMCP
//

import Foundation

enum DuplicateJSONKeyError: Error {
    case duplicateKey
    case malformedJSON
}

/// `JSONSerialization` accepts duplicate object keys and silently keeps one value.
/// Walk the JSON structure first so security-sensitive config cannot hide overrides.
func rejectDuplicateJSONKeys(in data: Data) throws {
    var bytes = Array(data)
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
        bytes.removeFirst(3)
    }
    guard String(bytes: bytes, encoding: .utf8) != nil else {
        throw DuplicateJSONKeyError.malformedJSON
    }

    var validator = DuplicateJSONKeyValidator(bytes: bytes)
    try validator.validate()
}

private struct DuplicateJSONKeyValidator {
    private let bytes: [UInt8]
    private var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func validate() throws {
        skipWhitespace()
        try validateValue(depth: 0)
        skipWhitespace()
        guard index == bytes.endIndex else { throw DuplicateJSONKeyError.malformedJSON }
    }

    private mutating func validateValue(depth: Int) throws {
        guard depth <= 512 else { throw DuplicateJSONKeyError.malformedJSON }
        guard let byte = currentByte else { throw DuplicateJSONKeyError.malformedJSON }

        switch byte {
        case ascii("{"):
            try validateObject(depth: depth)
        case ascii("["):
            try validateArray(depth: depth)
        case ascii("\""):
            _ = try parseString()
        default:
            try skipPrimitive()
        }
    }

    private mutating func validateObject(depth: Int) throws {
        try consume(ascii("{"))
        skipWhitespace()
        if consumeIfPresent(ascii("}")) {
            return
        }

        var keys: Set<String> = []
        while true {
            guard currentByte == ascii("\"") else { throw DuplicateJSONKeyError.malformedJSON }

            let key = try parseString()
            guard keys.insert(key).inserted else { throw DuplicateJSONKeyError.duplicateKey }

            skipWhitespace()
            try consume(ascii(":"))
            skipWhitespace()
            try validateValue(depth: depth + 1)
            skipWhitespace()

            if consumeIfPresent(ascii("}")) {
                return
            }
            try consume(ascii(","))
            skipWhitespace()
        }
    }

    private mutating func validateArray(depth: Int) throws {
        try consume(ascii("["))
        skipWhitespace()
        if consumeIfPresent(ascii("]")) {
            return
        }

        while true {
            try validateValue(depth: depth + 1)
            skipWhitespace()
            if consumeIfPresent(ascii("]")) {
                return
            }
            try consume(ascii(","))
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        try consume(ascii("\""))

        while let byte = currentByte {
            switch byte {
            case ascii("\""):
                index += 1
                let encodedString = Data(bytes[start ..< index])
                guard let value = try? JSONSerialization.jsonObject(
                    with: encodedString,
                    options: [.fragmentsAllowed],
                ) as? String else {
                    throw DuplicateJSONKeyError.malformedJSON
                }

                return value

            case ascii("\\"):
                index += 1
                guard let escape = currentByte else { throw DuplicateJSONKeyError.malformedJSON }

                if escape == ascii("u") {
                    index += 1
                    for _ in 0 ..< 4 {
                        guard let digit = currentByte, digit.isASCIIHexDigit else {
                            throw DuplicateJSONKeyError.malformedJSON
                        }

                        index += 1
                    }
                } else {
                    guard [ascii("\""), ascii("\\"), ascii("/"), ascii("b"), ascii("f"),
                           ascii("n"), ascii("r"), ascii("t")].contains(escape)
                    else { throw DuplicateJSONKeyError.malformedJSON }

                    index += 1
                }

            case 0x00 ... 0x1F:
                throw DuplicateJSONKeyError.malformedJSON

            default:
                index += 1
            }
        }

        throw DuplicateJSONKeyError.malformedJSON
    }

    private mutating func skipPrimitive() throws {
        let start = index
        while let byte = currentByte,
              !byte.isJSONWhitespace,
              ![ascii(","), ascii("]"), ascii("}")].contains(byte)
        {
            index += 1
        }
        guard index > start else { throw DuplicateJSONKeyError.malformedJSON }
    }

    private mutating func skipWhitespace() {
        while currentByte?.isJSONWhitespace == true {
            index += 1
        }
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard consumeIfPresent(expected) else { throw DuplicateJSONKeyError.malformedJSON }
    }

    private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
        guard currentByte == expected else { return false }

        index += 1
        return true
    }

    private var currentByte: UInt8? {
        index < bytes.endIndex ? bytes[index] : nil
    }
}

private func ascii(_ character: Character) -> UInt8 {
    character.asciiValue!
}

private extension UInt8 {
    var isASCIIHexDigit: Bool {
        (ascii("0") ... ascii("9")).contains(self)
            || (ascii("a") ... ascii("f")).contains(self)
            || (ascii("A") ... ascii("F")).contains(self)
    }

    var isJSONWhitespace: Bool {
        [ascii(" "), ascii("\t"), ascii("\n"), ascii("\r")].contains(self)
    }
}
