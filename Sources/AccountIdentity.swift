// AccountIdentity.swift
// Who is actually signed in at a config directory.
//
// A config directory is not a stable identity. `~/.claude` is a *slot*: sign in
// again with a different account, or let a profile manager rotate accounts
// through it, and the directory stays put while the account behind it changes.
// A row that pinned a label to a path therefore goes on confidently reporting
// somebody else's usage, with nothing in the UI to reveal it.
//
// Claude Code does leave one authoritative marker — `oauthAccount.emailAddress`
// in the config JSON — which nothing in the app used to read. This reads it, so
// a row can be checked against the account that is really there.

import Foundation

/// Reads the signed-in identity Claude Code records for a config directory.
enum ClaudeIdentity {

    /// `.claude.json` for a config dir. The default login is the odd one out:
    /// its file is `~/.claude.json`, a sibling of `~/.claude` rather than a
    /// child of it. Looking for `~/.claude/.claude.json` finds nothing.
    static func configFile(for configDir: String?) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let dir = configDir else { return home.appendingPathComponent(".claude.json") }
        return URL(fileURLWithPath: dir).appendingPathComponent(".claude.json")
    }

    /// Email of the account signed in at `configDir`, or nil when the directory
    /// holds no login. This is the ground truth a row's label is checked against.
    static func email(for configDir: String?) -> String? {
        oauthAccount(for: configDir)?["emailAddress"] as? String
    }

    static func accountUUID(for configDir: String?) -> String? {
        oauthAccount(for: configDir)?["accountUuid"] as? String
    }

    private static func oauthAccount(for configDir: String?) -> [String: Any]? {
        guard let data = try? Data(contentsOf: configFile(for: configDir)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["oauthAccount"] as? [String: Any]
    }
}
