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

    public init(
        id: String? = nil,
        name: String,
        userEmail: String? = nil,
        apiKey: String,
        baseURL: URL,
        screenAPIKey: String?,
        screenRegion: String,
        allowWrites: Bool = true,
    ) {
        self.id = id ?? name
        self.name = name
        self.userEmail = userEmail
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.screenAPIKey = screenAPIKey
        self.screenRegion = screenRegion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
    /// The name of the account used when a tool call omits `account`.
    public let defaultName: String
    public let allowWrites: Bool

    public init(accounts: [MCPAccount], defaultName: String, allowWrites: Bool) {
        self.accounts = accounts
        self.defaultName = defaultName
        self.allowWrites = allowWrites
    }

    /// The default account (the one named `defaultName`, else the first), or nil
    /// for a directly constructed empty set (#1563).
    public var defaultAccount: MCPAccount? {
        accounts.first { $0.id == defaultName }
            ?? accounts.first { $0.name == defaultName }
            ?? accounts.first
    }

    /// Resolves a tool call's `account` argument to a configured account by name
    /// (case-insensitive). A nil/empty name resolves to the default; a non-empty name
    /// that matches nothing returns nil so the caller can report the available accounts.
    /// A name matching more than one account (a normalization variant the config
    /// duplicate check didn't fold) is ambiguous and also returns nil rather than
    /// silently targeting whichever was listed first (#1582).
    public func resolve(_ name: String?) -> MCPAccount? {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultAccount
        }

        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Whether at least one account can advertise write tools.
    public var anyWritesEnabled: Bool {
        allowWrites && accounts.contains(where: \.allowWrites)
    }

    /// Whether a specific account may execute write tools.
    public func allowsWrites(to account: MCPAccount) -> Bool {
        allowWrites && account.allowWrites
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
public enum MCPConfigError: Error, Equatable {
    case noAccounts
    case tooManyAccounts(limit: Int)
    case missingAPIKey(account: String)
    case duplicateName(String)
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
}

/// Why the standalone JSON config file could not be loaded.
public enum MCPConfigLoadError: Error, Equatable, LocalizedError {
    case missingConfig(path: String)
    case permissionDenied(path: String)
    case notRegularFile(path: String)
    case symbolicLink(path: String)
    case wrongOwner(path: String)
    case insecurePermissions(path: String)
    case readFailed(path: String)
    case configTooLarge(path: String, limit: Int)
    case malformedConfig(path: String)
    case nonObjectConfig(path: String)

    public var errorDescription: String? {
        switch self {
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
        case let .nonObjectConfig(path):
            "Config file at \(path) must contain a JSON object."
        }
    }
}

private func screenRegion(from raw: String?, account: String) throws -> String {
    guard let region = trimmedNonEmpty(raw) else { return "us" }

    switch region.lowercased() {
    case "us", "eu":
        return region.lowercased()
    default:
        throw MCPConfigError.invalidScreenRegion(account: account, region: region)
    }
}

private func configScreenRegion(_ entry: [String: Any], account: String) throws -> String {
    guard let raw = entry["screen_region"] else { return try screenRegion(from: nil, account: account) }
    guard let value = raw as? String else {
        throw MCPConfigError.invalidScreenRegion(account: account, region: String(describing: raw))
    }

    return try screenRegion(from: value, account: account)
}

private func trimmedNonEmpty(_ raw: String?) -> String? {
    guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }

    return value
}

/// An account name suitable for tool arguments and resource URIs (#1583): control
/// characters are stripped and the length capped, so a malformed config value can't
/// produce an unusable resource catalog. Nil when nothing usable remains.
private func sanitizedAccountName(_ raw: String?) -> String? {
    guard var value = trimmedNonEmpty(raw) else { return nil }

    value = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    value = String(value.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
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
public func loadConfigObject(
    environment: [String: String],
    fileManager _: FileManager = .default,
    homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
) throws -> [String: Any]? {
    let maximumConfigBytes = 1_048_576
    let explicitPath = trimmedNonEmpty(environment["CODERPAD_MCP_CONFIG"])
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

        return MCPAccountSet(accounts: accounts, defaultName: defaultName, allowWrites: configWrites)
    }

    return try environmentAccountSet(environment, allowWrites: envWrites)
}

private func environmentAccountSet(_ environment: [String: String], allowWrites: Bool) throws -> MCPAccountSet {
    let accountName = sanitizedAccountName(environment["CODERPAD_ACCOUNT_NAME"]) ?? "default"
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
        screenRegion: screenRegion(
            from: environment["CODERPAD_SCREEN_REGION"],
            account: accountName,
        ),
    )
    return MCPAccountSet(accounts: [account], defaultName: account.name, allowWrites: allowWrites)
}

private func configuredAllowWrites(_ config: [String: Any]?) throws -> Bool {
    guard let raw = config?["allow_writes"] else { return false }
    guard let value = raw as? Bool else { throw MCPConfigError.invalidAllowWrites }

    return value
}
