//
//  Accounts.swift
//  CoderPadMCP
//
//  Multi-account configuration for the standalone server (#521). The CLI can act as
//  several CoderPad accounts — mirroring the in-app server's account directory — so the
//  `account` tool argument and `list_accounts` resolve the same way on both servers and
//  one shared tool schema fits each. Accounts come from a JSON config file; a single
//  account can still be supplied via the legacy environment variables, which becomes the
//  lone (default) account so existing setups keep working. Pure parsing, kept here so
//  it's unit-tested without touching the filesystem.
//

import CoderPadToolCore
import Foundation

/// Operational ceiling for one server process. Account/resource directory responses
/// include every account, so accepting thousands from a 1 MiB config would create
/// disproportionate memory use and model-context output.
public let maxConfiguredAccounts = 100

/// One configured CoderPad account the standalone server can act as.
public struct MCPAccount: Equatable, Sendable {
    /// Stable host-defined identity used to disambiguate accounts with the same name.
    public let id: String
    public let name: String
    /// Optional key-owner identity known to the embedding application.
    public let userEmail: String?
    public let apiKey: String
    public let baseURL: URL
    /// CoderPad Screen (assessments) is a separate API with its own key; nil disables
    /// the screen_* tools for this account.
    public let screenAPIKey: String?
    /// "eu" for EU-hosted Screen orgs, else "us".
    public let screenRegion: String
    /// Per-account write authorization. The account set's global switch must also be on.
    public let allowWrites: Bool

    /// Creates an account after applying the same model invariants as file-loaded accounts.
    public init(
        id: String? = nil,
        name: String,
        userEmail: String? = nil,
        apiKey: String,
        baseURL: URL,
        screenAPIKey: String?,
        screenRegion: String,
        allowWrites: Bool = true,
    ) throws {
        guard let normalizedName = sanitizedAccountName(name) else {
            throw MCPConfigError.invalidCredential(account: "account", field: "name")
        }
        guard let normalizedID = sanitizedAccountName(id ?? normalizedName) else {
            throw MCPConfigError.invalidCredential(account: normalizedName, field: "id")
        }
        guard let normalizedAPIKey = try validatedCredential(
            apiKey,
            account: normalizedName,
            field: "api_key",
        ) else {
            throw MCPConfigError.missingAPIKey(account: normalizedName)
        }

        self.id = normalizedID
        self.name = normalizedName
        self.userEmail = try validatedCredential(userEmail, account: normalizedName, field: "user_email")
        self.apiKey = normalizedAPIKey
        self.baseURL = try parseBaseURL(baseURL.absoluteString, account: normalizedName)
        self.screenAPIKey = try validatedCredential(
            screenAPIKey,
            account: normalizedName,
            field: "screen_api_key",
        )
        self.screenRegion = try normalizedScreenRegion(from: screenRegion, account: normalizedName)
        self.allowWrites = allowWrites
    }

    public var screenEnabled: Bool {
        guard let screenAPIKey else { return false }

        return !screenAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The Screen API host for this account's region.
    public var screenBaseURL: URL {
        screenRegion == "eu"
            ? URL(string: "https://www.codingame.eu")!
            : URL(string: "https://www.codingame.com")!
    }
}

/// The full set of accounts the server resolves tool calls against, plus the global
/// write opt-in.
public struct MCPAccountSet: Equatable, Sendable {
    public let accounts: [MCPAccount]
    /// Stable id or unique display name of the account used when a tool call omits
    /// `account`. Prefer the stable id; cross-account id/name collisions are rejected
    /// at construction so id-first resolution cannot hijack another account (#138, #195).
    public let defaultName: String
    public let allowWrites: Bool

    public init(accounts: [MCPAccount], defaultName: String, allowWrites: Bool) throws {
        try Self.validate(accounts)
        self.accounts = accounts
        self.defaultName = defaultName
        self.allowWrites = allowWrites
    }

    /// The default account (the one identified by `defaultName`, else the first), or nil
    /// for a directly constructed empty set (#1563).
    public var defaultAccount: MCPAccount? {
        accounts.first { $0.id == defaultName }
            ?? accounts.first { accountNamesEqual($0.name, defaultName) }
            ?? accounts.first
    }

    /// Resolves a tool call's `account` argument to a configured account by stable id
    /// (exact) or unique display name (case-insensitive). A nil/empty selector resolves
    /// to the default; a non-empty selector that matches nothing returns nil so the
    /// caller can report the available accounts. A name matching more than one account
    /// is ambiguous and also returns nil rather than silently targeting whichever was
    /// listed first (#1582). Prefer stable ids when names may collide.
    public func resolve(_ name: String?) -> MCPAccount? {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultAccount
        }

        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wanted.count <= maxAccountSelectorCharacters,
              wanted.utf8.count <= maxAccountSelectorUTF8Bytes
        else {
            return nil
        }
        if let identified = accounts.first(where: { $0.id == wanted }) {
            return identified
        }
        let matches = accounts.filter { accountNamesEqual($0.name, wanted) }
        guard matches.count == 1 else { return nil }

        return matches[0]
    }

    /// Whether any account has Screen configured — the screen_* tools are advertised
    /// when at least one does, matching the in-app server's gating.
    public var anyScreenEnabled: Bool {
        accounts.contains(where: \.screenEnabled)
    }

    /// Whether omitted-account Screen calls would hit a configured default. When Screen
    /// is available only on a non-default account, clients must pass `account` (#198).
    public var defaultScreenEnabled: Bool {
        defaultAccount?.screenEnabled == true
    }

    /// Whether at least one account can advertise write tools.
    public var anyWritesEnabled: Bool {
        allowWrites && accounts.contains(where: \.allowWrites)
    }

    /// Whether omitted-account write calls would be authorized on the default (#199).
    public var defaultWritesEnabled: Bool {
        guard let defaultAccount else { return false }

        return allowsWrites(to: defaultAccount)
    }

    /// Whether a specific account may execute write tools.
    public func allowsWrites(to account: MCPAccount) -> Bool {
        allowWrites && account.allowWrites
    }

    private static func validate(_ accounts: [MCPAccount]) throws {
        var seenIDs: [String] = []
        for account in accounts {
            guard !seenIDs.contains(account.id) else {
                throw MCPConfigError.duplicateID(account.id)
            }
            seenIDs.append(account.id)
        }

        // An id that equals another account's display name would make name selection
        // route to the wrong organization under id-first resolve (#195).
        for account in accounts {
            for other in accounts where other.id != account.id {
                if accountNamesEqual(account.id, other.name) {
                    throw MCPConfigError.selectorCollision(id: account.id, name: other.name)
                }
            }
        }
    }

    /// The directory returned by `list_accounts`: names, base URLs, and flags, never the
    /// API keys. The Screen region is included so a key/region mismatch is visible
    /// from the client rather than discovered on the first failing request (#1587).
    public func directory() -> [[String: Any]] {
        accounts.map { account in
            var entry: [String: Any] = [
                "id": account.id,
                "name": account.name,
                "base_url": account.baseURL.absoluteString,
                "is_default": account.id == defaultAccount?.id,
                "screen_configured": account.screenEnabled,
                "writes_enabled": allowsWrites(to: account),
            ]
            if let userEmail = account.userEmail {
                entry["user_email"] = userEmail
            }
            if account.screenEnabled {
                entry["screen_region"] = account.screenRegion
            }
            return entry
        }
    }
}

private func accountNamesEqual(_ lhs: String, _ rhs: String) -> Bool {
    lhs.caseInsensitiveCompare(rhs) == .orderedSame
}

/// Why a configuration couldn't be turned into a usable account set.
public enum MCPConfigError: Error, Equatable, LocalizedError {
    case noAccounts
    case tooManyAccounts(limit: Int)
    case missingAPIKey(account: String)
    case duplicateName(String)
    case duplicateID(String)
    /// An account's stable id matches another account's display name, so id-first
    /// selection would silently hijack name selectors (#195).
    case selectorCollision(id: String, name: String)
    case multipleDefaultAccounts([String])
    /// A multi-account config must declare its default explicitly: falling back
    /// to whichever account the JSON array happens to list first would let a
    /// config reformat silently redirect unqualified tool calls to another
    /// organization (#1586).
    case noDefaultAccount
    case invalidDefaultFlag(account: String)
    case invalidAllowWrites
    case invalidScreenRegion(account: String, region: String)
    case invalidBaseURL(account: String, baseURL: String)
    case invalidCredential(account: String, field: String)

    public var errorDescription: String? {
        switch self {
        case .noAccounts:
            "no accounts configured. Set CODERPAD_API_KEY, or point "
                + "CODERPAD_MCP_CONFIG at a config file with an \"accounts\" array."
        case let .tooManyAccounts(limit):
            "the account configuration exceeds the \(limit)-account limit."
        case let .missingAPIKey(account):
            "account \"\(account)\" is missing its \"api_key\"."
        case let .duplicateName(name):
            "two accounts share the name \"\(name)\"; names must be unique."
        case let .multipleDefaultAccounts(names):
            "multiple accounts are marked as default ("
                + names.joined(separator: ", ") + "); mark only one as the default."
        case .noDefaultAccount:
            "a config with multiple accounts must mark one as the default."
        case let .invalidDefaultFlag(account):
            "account \"\(account)\" has a non-Boolean \"default\" value."
        case .invalidAllowWrites:
            "\"allow_writes\" must be a JSON boolean (true or false)."
        case let .invalidScreenRegion(account, region):
            "account \"\(account)\" has unsupported screen_region \"\(region)\"."
        case let .invalidBaseURL(account, baseURL):
            "account \"\(account)\" has unsupported base_url \"\(baseURL)\"."
        case let .invalidCredential(account, field):
            "account \"\(account)\" has an invalid \"\(field)\" value."
        }
    }
}

/// Why the standalone JSON config file could not be loaded.
public enum MCPConfigLoadError: Error, Equatable, LocalizedError {
    /// `CODERPAD_MCP_CONFIG` is present but does not name a path after trimming.
    case emptyConfigPath
    case missingConfig(path: String)
    case permissionDenied(path: String)
    case notRegularFile(path: String)
    case symbolicLink(path: String)
    case wrongOwner(path: String)
    case insecurePermissions(path: String)
    case readFailed(path: String)
    case configTooLarge(path: String, limit: Int)
    case malformedConfig(path: String)
    case duplicateKey(path: String)
    case nonObjectConfig(path: String)

    public var errorDescription: String? {
        switch self {
        case .emptyConfigPath:
            "CODERPAD_MCP_CONFIG is set but empty; provide a config file path or unset the variable."
        case let .missingConfig(path):
            "Config file does not exist at \(path)."
        case let .permissionDenied(path):
            "Permission was denied while reading config file at \(path)."
        case let .notRegularFile(path):
            "Config path at \(path) is not a regular file."
        case let .symbolicLink(path):
            "Config path at \(path) must not be a symbolic link."
        case let .wrongOwner(path):
            "Config file at \(path) is not owned by the current user."
        case let .insecurePermissions(path):
            "Config file at \(path) must not be accessible by group or other users."
        case let .readFailed(path):
            "Could not read config file at \(path)."
        case let .configTooLarge(path, limit):
            "Config file at \(path) exceeds the \(limit)-byte size limit."
        case let .malformedConfig(path):
            "Config file at \(path) is not valid JSON."
        case let .duplicateKey(path):
            "Config file at \(path) contains a duplicate JSON object key."
        case let .nonObjectConfig(path):
            "Config file at \(path) must contain a JSON object."
        }
    }
}

/// Formats a configuration-loading failure for the standalone `coderpad-mcp` CLI's stderr.
public func configurationFailureMessage(_ error: Error) -> String {
    switch error {
    case let error as MCPConfigError:
        "coderpad-mcp: \(error.localizedDescription)\n"
    case let error as MCPConfigLoadError:
        "coderpad-mcp: \(error.localizedDescription)\n"
    default:
        "coderpad-mcp: could not load the account configuration: \(error.localizedDescription)\n"
    }
}

private func normalizedScreenRegion(from raw: String?, account: String) throws -> String {
    guard let region = trimmedNonEmpty(raw) else { return "us" }

    switch region.lowercased() {
    case "us", "eu":
        return region.lowercased()
    default:
        throw MCPConfigError.invalidScreenRegion(account: account, region: region)
    }
}

private func configScreenRegion(_ entry: [String: Any], account: String) throws -> String {
    guard let raw = entry["screen_region"] else {
        return try normalizedScreenRegion(from: nil, account: account)
    }
    guard let value = raw as? String else {
        throw MCPConfigError.invalidScreenRegion(account: account, region: String(describing: raw))
    }

    return try normalizedScreenRegion(from: value, account: account)
}

private func trimmedNonEmpty(_ raw: String?) -> String? {
    guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }

    return value
}

/// An account name suitable for tool arguments and resource URIs (#1583): control
/// and Unicode format characters are stripped and both display characters and UTF-8
/// bytes are capped, so a malformed config value can't produce an unusable, oversized,
/// or visually deceptive resource catalog. Dot-segment names are rejected because
/// resource URI parsing refuses them (#136). Nil when nothing usable remains.
private func sanitizedAccountName(_ raw: String?) -> String? {
    guard var value = trimmedNonEmpty(raw) else { return nil }

    value = String(value.unicodeScalars.filter {
        !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
    })
    value = String(value.prefix(maxAccountSelectorCharacters))
    var byteBounded = ""
    var byteCount = 0
    for scalar in value.unicodeScalars {
        let scalarBytes = scalar.utf8.count
        guard byteCount + scalarBytes <= maxAccountSelectorUTF8Bytes else { break }
        byteBounded.unicodeScalars.append(scalar)
        byteCount += scalarBytes
    }
    value = byteBounded.trimmingCharacters(in: .whitespacesAndNewlines)
    // Resource path segments reject "." / ".." (#136); never advertise those selectors.
    guard !value.isEmpty, value != ".", value != ".." else { return nil }

    return value
}

private func validatedCredential(_ raw: String?, account: String, field: String) throws -> String? {
    guard let value = trimmedNonEmpty(raw) else { return nil }

    let hasUnsafeScalar = value.unicodeScalars.contains { scalar in
        let category = scalar.properties.generalCategory
        return category == .control || category == .format
    }
    guard value.utf8.count <= 4096, !hasUnsafeScalar else {
        throw MCPConfigError.invalidCredential(account: account, field: field)
    }

    return value
}

private func optionalConfigCredential(
    _ entry: [String: Any], field: String, account: String,
) throws -> String? {
    guard let raw = entry[field] else { return nil }
    guard let value = raw as? String else {
        throw MCPConfigError.invalidCredential(account: account, field: field)
    }

    return try validatedCredential(value, account: account, field: field)
}

private func parseBaseURL(_ raw: String?, account: String) throws -> URL {
    guard let value = trimmedNonEmpty(raw) else { return URL(string: "https://app.coderpad.io")! }
    guard
        let url = URL(string: value),
        let scheme = url.scheme?.lowercased(),
        scheme == "https",
        let host = url.host(),
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        // A base URL is an origin plus optional path prefix - never a query,
        // fragment, or embedded credentials. REST clients append their own API
        // paths to it, and stray components could redirect authenticated
        // requests to an unexpected endpoint (#1585).
        url.query() == nil, url.fragment() == nil,
        url.user == nil, url.password == nil
    else {
        throw MCPConfigError.invalidBaseURL(account: account, baseURL: value)
    }

    // Normalized without a trailing slash so appended API paths can't double a
    // separator (#1585).
    if url.path() == "/" || url.absoluteString.hasSuffix("/"),
       let trimmedURL = URL(string: String(url.absoluteString.reversed().drop(while: { $0 == "/" }).reversed()))
    {
        return trimmedURL
    }
    return url
}

private func parseConfigBaseURL(_ entry: [String: Any], account: String) throws -> URL {
    guard let raw = entry["base_url"] else { return try parseBaseURL(nil, account: account) }
    guard let value = raw as? String else {
        throw MCPConfigError.invalidBaseURL(account: account, baseURL: String(describing: raw))
    }

    return try parseBaseURL(value, account: account)
}

private func truthy(_ raw: String?) -> Bool {
    ["1", "true", "yes", "on"].contains(raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
}

private func expandedConfigURL(_ path: String, homeDirectory: URL) -> URL {
    if path == "~" {
        return homeDirectory
    }
    if path.hasPrefix("~/") {
        return homeDirectory.appending(path: String(path.dropFirst(2)))
    }
    return URL(fileURLWithPath: path)
}

/// Reads the standalone server's JSON config file, if one is present. Missing default
/// config falls back to env credentials; explicit config paths fail fast on any load
/// or parse problem so the server never silently switches accounts.
///
/// Secure loading uses POSIX descriptor checks (`O_NOFOLLOW`, ownership, mode bits, and
/// ACL probes) rather than `FileManager`, so this API does not accept a filesystem
/// dependency that could not honor those guarantees.
public func loadConfigObject(
    environment: [String: String],
    homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
) throws -> [String: Any]? {
    let maximumConfigBytes = 1_048_576
    let explicitPath: String?
    if let rawPath = environment["CODERPAD_MCP_CONFIG"] {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPConfigLoadError.emptyConfigPath
        }
        explicitPath = trimmed
    } else {
        explicitPath = nil
    }
    let url: URL = if let explicitPath {
        expandedConfigURL(explicitPath, homeDirectory: homeDirectory)
    } else {
        homeDirectory.appending(path: ".config/coderpad-mcp/config.json")
    }

    let path = url.path
    guard let data = try securelyReadConfig(
        path: path,
        explicit: explicitPath != nil,
        limit: maximumConfigBytes,
    ) else { return nil }

    do {
        try rejectDuplicateJSONKeys(in: data)
    } catch DuplicateJSONKeyError.duplicateKey {
        throw MCPConfigLoadError.duplicateKey(path: path)
    } catch {
        throw MCPConfigLoadError.malformedConfig(path: path)
    }

    let object: Any
    do {
        object = try JSONSerialization.jsonObject(with: data)
    } catch {
        throw MCPConfigLoadError.malformedConfig(path: path)
    }

    guard let config = object as? [String: Any] else {
        throw MCPConfigLoadError.nonObjectConfig(path: path)
    }

    return config
}

/// Builds the account set from a parsed JSON config object, falling back to the legacy
/// single-account environment variables only when no config is present.
///
/// Config shape:
/// ```
/// { "accounts": [ { "name": "Acme", "api_key": "…", "base_url": "…",
///                   "screen_api_key": "…", "screen_region": "eu", "default": true } ],
///   "allow_writes": false }
/// ```
/// Env fallback: `CODERPAD_API_KEY` (required), `CODERPAD_BASE_URL`,
/// `CODERPAD_SCREEN_API_KEY`, `CODERPAD_SCREEN_REGION`, `CODERPAD_MCP_ALLOW_WRITES`.
/// A config's `allow_writes` is authoritative; the environment flag is used only
/// when no config is present.
public func makeAccountSet(config: [String: Any]?, environment: [String: String]) throws -> MCPAccountSet {
    let envWrites = truthy(environment["CODERPAD_MCP_ALLOW_WRITES"])
    let configWrites = try configuredAllowWrites(config)

    if let config {
        guard let rawAccounts = config["accounts"] as? [[String: Any]], !rawAccounts.isEmpty else {
            throw MCPConfigError.noAccounts
        }
        guard rawAccounts.count <= maxConfiguredAccounts else {
            throw MCPConfigError.tooManyAccounts(limit: maxConfiguredAccounts)
        }

        var accounts: [MCPAccount] = []
        var defaultNames: [String] = []
        var seenNames: [String] = []
        for entry in rawAccounts {
            let fallbackName = "account-\(accounts.count + 1)"
            let name: String
            if let rawName = entry["name"] {
                guard let stringName = rawName as? String,
                      let validName = sanitizedAccountName(stringName)
                else {
                    throw MCPConfigError.invalidCredential(account: fallbackName, field: "name")
                }

                name = validName
            } else {
                name = fallbackName
            }

            guard let key = try optionalConfigCredential(entry, field: "api_key", account: name)
            else {
                throw MCPConfigError.missingAPIKey(account: name)
            }
            guard !seenNames.contains(where: { accountNamesEqual($0, name) }) else {
                throw MCPConfigError.duplicateName(name)
            }
            seenNames.append(name)

            try accounts.append(MCPAccount(
                name: name,
                apiKey: key,
                baseURL: parseConfigBaseURL(entry, account: name),
                screenAPIKey: optionalConfigCredential(entry, field: "screen_api_key", account: name),
                screenRegion: configScreenRegion(entry, account: name),
            ))
            if let rawDefault = entry["default"] {
                guard let isDefault = rawDefault as? Bool else {
                    throw MCPConfigError.invalidDefaultFlag(account: name)
                }
                if isDefault {
                    defaultNames.append(name)
                }
            }
        }

        guard defaultNames.count <= 1 else {
            throw MCPConfigError.multipleDefaultAccounts(defaultNames)
        }

        // A multi-account config must say which account is the default: JSON
        // array order can change during merges/reformatting and must never
        // silently redirect unqualified tool calls (#1586).
        guard let defaultName = defaultNames.first ?? (accounts.count == 1 ? accounts[0].name : nil) else {
            throw MCPConfigError.noDefaultAccount
        }

        return try MCPAccountSet(accounts: accounts, defaultName: defaultName, allowWrites: configWrites)
    }

    return try environmentAccountSet(environment, allowWrites: envWrites)
}

private func environmentAccountSet(_ environment: [String: String], allowWrites: Bool) throws -> MCPAccountSet {
    // Absent or blank CODERPAD_ACCOUNT_NAME becomes "default". A present value that
    // sanitizes to nothing (controls-only, ".", "..", etc.) is a configuration error
    // rather than a silent rename (#139).
    let accountName: String
    if let rawName = environment["CODERPAD_ACCOUNT_NAME"],
       !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
        guard let sanitized = sanitizedAccountName(rawName) else {
            throw MCPConfigError.invalidCredential(account: "environment", field: "CODERPAD_ACCOUNT_NAME")
        }
        accountName = sanitized
    } else {
        accountName = "default"
    }
    guard let key = try validatedCredential(environment["CODERPAD_API_KEY"],
                                            account: accountName, field: "CODERPAD_API_KEY")
    else {
        throw MCPConfigError.noAccounts
    }

    let account = try MCPAccount(
        name: accountName,
        apiKey: key,
        baseURL: parseBaseURL(
            environment["CODERPAD_BASE_URL"],
            account: accountName,
        ),
        screenAPIKey: validatedCredential(environment["CODERPAD_SCREEN_API_KEY"],
                                          account: accountName, field: "CODERPAD_SCREEN_API_KEY"),
        screenRegion: normalizedScreenRegion(
            from: environment["CODERPAD_SCREEN_REGION"],
            account: accountName,
        ),
    )
    return try MCPAccountSet(accounts: [account], defaultName: account.id, allowWrites: allowWrites)
}

private func configuredAllowWrites(_ config: [String: Any]?) throws -> Bool {
    guard let raw = config?["allow_writes"] else { return false }
    guard let value = raw as? Bool else { throw MCPConfigError.invalidAllowWrites }

    return value
}
