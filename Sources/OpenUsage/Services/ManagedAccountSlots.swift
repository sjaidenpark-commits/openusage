import AppKit
import Foundation
import Observation
import Security

enum ManagedAccountProvider: String, CaseIterable, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    fileprivate var directoryPrefix: String { ".\(rawValue)-account-" }
}

struct ManagedAccountSlot: Identifiable, Equatable, Sendable {
    var provider: ManagedAccountProvider
    var number: Int
    var directoryURL: URL
    var accountLabel: String?
    var isReady: Bool

    var id: String { directoryURL.path }
    var title: String { accountLabel?.nilIfEmpty ?? "Account \(number)" }
}

/// Owns only the extra account homes created from Settings. Default Claude/Codex homes are never
/// modified. Login stays in the provider CLI; OpenUsage only creates an isolated home and opens its
/// login command in Terminal.
@MainActor
@Observable
final class ManagedAccountSlots {
    private(set) var slots: [ManagedAccountSlot] = []
    private(set) var notice: String?

    private let fileManager: FileManager
    private let homeDirectory: URL
    private let appBundleURL: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        appBundleURL: URL = Bundle.main.bundleURL
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.appBundleURL = appBundleURL
        refresh()
    }

    func refresh() {
        let claude = Dictionary(
            uniqueKeysWithValues: ClaudeConfigDirDiscovery().run().findings.map {
                ($0.anchorPath, $0.label)
            }
        )
        let codex = Dictionary(
            uniqueKeysWithValues: CodexHomeDiscovery().run().findings.map {
                ($0.anchorPath, $0.label)
            }
        )

        slots = ManagedAccountProvider.allCases.flatMap { provider in
            managedDirectories(provider: provider).map { number, url in
                let finding = provider == .claude ? claude[url.path] : codex[url.path]
                return ManagedAccountSlot(
                    provider: provider,
                    number: number,
                    directoryURL: url,
                    accountLabel: finding ?? nil,
                    isReady: finding != nil
                )
            }
        }
    }

    func add(_ provider: ManagedAccountProvider) {
        do {
            let number = Self.nextSlotNumber(
                existingNames: managedDirectories(provider: provider).map { $0.url.lastPathComponent },
                prefix: provider.directoryPrefix
            )
            let directory = homeDirectory.appendingPathComponent("\(provider.directoryPrefix)\(number)")
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            if provider == .codex {
                try write("cli_auth_credentials_store = \"file\"\n", to: directory.appendingPathComponent("config.toml"), permissions: 0o600)
            }
            notice = nil
            refresh()
            signIn(slot(provider: provider, number: number, directory: directory))
        } catch {
            notice = "Couldn't add the account: \(error.localizedDescription)"
        }
    }

    func signIn(_ slot: ManagedAccountSlot) {
        do {
            let scriptURL = slot.directoryURL.appendingPathComponent("openusage-login.command")
            try write(loginScript(for: slot), to: scriptURL, permissions: 0o700)
            guard NSWorkspace.shared.open(scriptURL) else {
                throw ManagedAccountError.couldNotOpenTerminal
            }
            notice = "Finish the \(slot.provider.displayName) login in Terminal. OpenUsage restarts automatically."
        } catch {
            notice = "Couldn't start login: \(error.localizedDescription)"
        }
    }

    func remove(_ slot: ManagedAccountSlot) {
        do {
            if slot.provider == .claude {
                try removeClaudeKeychainCredential(configDir: slot.directoryURL.path)
            }
            var trashedURL: NSURL?
            try fileManager.trashItem(at: slot.directoryURL, resultingItemURL: &trashedURL)
            notice = nil
            refresh()
            try restartApp()
        } catch {
            notice = "Couldn't remove the account: \(error.localizedDescription)"
        }
    }

    nonisolated static func nextSlotNumber(existingNames: [String], prefix: String) -> Int {
        let used = Set(existingNames.compactMap { name -> Int? in
            guard name.hasPrefix(prefix) else { return nil }
            return Int(name.dropFirst(prefix.count))
        })
        return (2...).first { !used.contains($0) }!
    }

    private func managedDirectories(provider: ManagedAccountProvider) -> [(number: Int, url: URL)] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: homeDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        return urls.compactMap { url in
            guard url.lastPathComponent.hasPrefix(provider.directoryPrefix),
                  let number = Int(url.lastPathComponent.dropFirst(provider.directoryPrefix.count)),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return nil }
            return (number, url)
        }
        .sorted { $0.number < $1.number }
    }

    private func slot(provider: ManagedAccountProvider, number: Int, directory: URL) -> ManagedAccountSlot {
        ManagedAccountSlot(
            provider: provider,
            number: number,
            directoryURL: directory,
            accountLabel: nil,
            isReady: false
        )
    }

    private func loginScript(for slot: ManagedAccountSlot) -> String {
        let home = Self.shellQuote(slot.directoryURL.path)
        let app = Self.shellQuote(appBundleURL.path)
        let command: String
        switch slot.provider {
        case .claude:
            command = "export CLAUDE_CONFIG_DIR=\(home)\nclaude auth login --claudeai"
        case .codex:
            command = "export CODEX_HOME=\(home)\ncodex login"
        }
        return """
        #!/bin/zsh -l
        \(command)
        status=$?
        if (( status == 0 )); then
          echo "Login complete. Restarting OpenUsage…"
          /usr/bin/osascript -e 'tell application id "com.robinebers.openusage" to quit' >/dev/null 2>&1
          /bin/sleep 1
          /usr/bin/open \(app)
        fi
        exit $status
        """ + "\n"
    }

    private func write(_ text: String, to url: URL, permissions: Int) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func removeClaudeKeychainCredential(configDir: String) throws {
        let service = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: configDir,
            environment: ProcessEnvironmentReader()
        )
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ManagedAccountError.keychainDeleteFailed(status)
        }
    }

    private func restartApp() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "/bin/sleep 1; /usr/bin/open \(Self.shellQuote(appBundleURL.path))"]
        try process.run()
        NSApp.terminate(nil)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum ManagedAccountError: LocalizedError {
    case couldNotOpenTerminal
    case keychainDeleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .couldNotOpenTerminal:
            "Terminal couldn't open the login command."
        case .keychainDeleteFailed(let status):
            "Keychain credential couldn't be removed (\(status))."
        }
    }
}
