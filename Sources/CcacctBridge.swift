// CcacctBridge.swift
// Where a ccacct-managed account's data lives right now.
//
// ccacct (github.com/ValeriiMedvezhonkov/ccacct) rotates accounts through the native
// `~/.claude` slot. `ccacct use <name>` parks the current occupant's token back
// into its profile directory and stages the new account's token into the bare
// `Claude Code-credentials` Keychain service, deleting the profile's own
// suffixed item. So a managed account is in one of two places depending on who
// was activated last, and a stored path cannot express that.
//
// This layer is optional: with no ccacct installation present every entry point
// reports "not installed" and callers fall back to their statically pinned
// config dir, which is exactly the behaviour without this file.

import Foundation

/// One account as ccacct records it in `accounts/<name>.conf`.
struct CcacctAccount {
    let name: String
    let email: String?
    /// The account's own profile directory. Note this is where it lives when
    /// *parked* — while it owns the native slot its data is in `~/.claude`
    /// instead. Use `Ccacct.resolvedConfigDir(for:)` rather than this.
    let profileDir: String?
}

/// Read-only view of a ccacct installation.
///
/// Deliberately parses files rather than shelling out to `ccacct`: this runs on
/// every popover refresh, and the app must never be able to mutate the user's
/// credential state as a side effect of merely displaying it.
enum Ccacct {

    static var home: URL {
        if let override = ProcessInfo.processInfo.environment["CCACCT_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-accounts")
    }

    static var isInstalled: Bool { snapshot().isInstalled }

    /// Accounts in stable (alphabetical) order, matching `ccacct list`.
    static var accounts: [CcacctAccount] { snapshot().accounts }

    /// The account ccacct considers system-wide active.
    static var activeName: String? { snapshot().activeName }

    /// The account currently occupying `~/.claude`.
    static var nativeOwner: String? { snapshot().nativeOwner }

    static func account(named name: String) -> CcacctAccount? {
        snapshot().accounts.first { $0.name == name }
    }

    /// Where `name`'s data lives right now: nil (meaning `~/.claude`) when it
    /// holds the native slot, otherwise its profile directory.
    ///
    /// Returning nil for the native owner is what keeps the Keychain lookup
    /// correct — activating an account deletes its suffixed Keychain item and
    /// writes the bare `Claude Code-credentials` service instead, so hashing the
    /// profile path would point at an item that no longer exists.
    static func resolvedConfigDir(for name: String) -> String? {
        let snap = snapshot()
        guard let account = snap.accounts.first(where: { $0.name == name }) else { return nil }
        if snap.nativeOwner == name { return nil }
        return account.profileDir
    }

    /// True when `name` is registered with ccacct at all.
    static func isKnown(_ name: String) -> Bool {
        snapshot().accounts.contains { $0.name == name }
    }

    // MARK: Snapshot cache

    struct Snapshot {
        var isInstalled = false
        var accounts: [CcacctAccount] = []
        var activeName: String?
        var nativeOwner: String?
    }

    private static let lock = NSLock()
    private static var cached: Snapshot?
    private static var cachedStamp: (accounts: Date, active: Date, native: Date)?

    /// Drop the cache so the next read re-scans. Called when the app refreshes,
    /// so a `ccacct use` performed in a terminal is picked up without a restart.
    static func invalidate() {
        lock.lock()
        cached = nil
        cachedStamp = nil
        lock.unlock()
    }

    /// Cached parse, re-read only when one of the three inputs changes mtime.
    private static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }

        let stamp = currentStamp()
        if let cached, let cachedStamp, cachedStamp == stamp { return cached }

        let snap = scan()
        cached = snap
        cachedStamp = stamp
        return snap
    }

    private static func currentStamp() -> (accounts: Date, active: Date, native: Date) {
        (mtime(home.appendingPathComponent("accounts")),
         mtime(home.appendingPathComponent("active")),
         mtime(home.appendingPathComponent("native-owner")))
    }

    private static func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    private static func scan() -> Snapshot {
        var snap = Snapshot()
        let accountsDir = home.appendingPathComponent("accounts")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: accountsDir.path, isDirectory: &isDir),
              isDir.boolValue
        else { return snap }

        snap.isInstalled = true

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: accountsDir, includingPropertiesForKeys: nil)) ?? []
        snap.accounts = entries
            .filter { $0.pathExtension == "conf" }
            .compactMap(parseConf)
            .sorted { $0.name < $1.name }

        snap.activeName = readName(home.appendingPathComponent("active"))
        snap.nativeOwner = readName(home.appendingPathComponent("native-owner"))

        // A recorded name that is no longer registered is stale; treat it as
        // absent rather than resolving rows against an account that is gone.
        if let active = snap.activeName, !snap.accounts.contains(where: { $0.name == active }) {
            snap.activeName = nil
        }
        if let owner = snap.nativeOwner, !snap.accounts.contains(where: { $0.name == owner }) {
            snap.nativeOwner = nil
        }
        return snap
    }

    /// `key=value` per line, as written by ccacct's `conf_set`.
    private static func parseConf(_ url: URL) -> CcacctAccount? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { fields[key] = value }
        }
        // Fall back to the filename so an account with a malformed conf still
        // appears, rather than vanishing from the list with no explanation.
        let name = fields["name"]?.isEmpty == false
            ? fields["name"]!
            : url.deletingPathExtension().lastPathComponent
        guard !name.isEmpty else { return nil }
        return CcacctAccount(
            name: name,
            email: fields["email"].flatMap { $0.isEmpty ? nil : $0 },
            profileDir: fields["dir"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private static func readName(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let name = text.split(separator: "\n").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return name.isEmpty ? nil : name
    }
}
