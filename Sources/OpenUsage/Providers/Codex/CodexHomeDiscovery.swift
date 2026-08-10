import Foundation

/// Launch-time scan for extra file-backed Codex logins in custom `CODEX_HOME` directories.
/// Candidates are bounded to dot-directories in `~` and directories under `~/.config`; a home only
/// counts when its `auth.json` contains a usable OAuth token and a provider-issued account id.
struct CodexHomeDiscovery {
    struct Finding: Equatable, Sendable {
        var identityKey: String
        var label: String?
        var anchorPath: String
    }

    struct Result: Sendable {
        var findings: [Finding] = []
        var notes: [String] = []
    }

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var homeDirectory: @Sendable () -> URL
    var listSubdirectories: @Sendable (URL) -> [URL]
    var timeBudget: TimeInterval
    var now: @Sendable () -> Date

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        listSubdirectories: @escaping @Sendable (URL) -> [URL] = Self.filesystemSubdirectories,
        timeBudget: TimeInterval = 0.4,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.files = files
        self.homeDirectory = homeDirectory
        self.listSubdirectories = listSubdirectories
        self.timeBudget = timeBudget
        self.now = now
    }

    func run() -> Result {
        let started = now()
        var result = Result()
        let excluded = Set(defaultCodexHomes().map(canonical))

        for candidate in candidateDirectories() {
            if now().timeIntervalSince(started) > timeBudget {
                result.notes.append("codex home scan hit its \(Int(timeBudget * 1000))ms budget; finishing with partial results")
                break
            }
            guard !excluded.contains(canonical(candidate.path)) else { continue }
            if let finding = codexCandidate(at: candidate, notes: &result.notes) {
                result.findings.append(finding)
            }
        }
        return result
    }

    private func candidateDirectories() -> [URL] {
        let home = homeDirectory()
        var candidates = listSubdirectories(home).filter { $0.lastPathComponent.hasPrefix(".") }
        candidates += listSubdirectories(home.appendingPathComponent(".config"))
        return candidates.sorted { $0.path < $1.path }
    }

    private static func filesystemSubdirectories(of url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        return contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    private func codexCandidate(at url: URL, notes: inout [String]) -> Finding? {
        let authPath = url.path + "/auth.json"
        guard let text = try? files.readTextIfPresent(authPath) else { return nil }
        guard let auth = CodexAuthStore.parseAuth(text),
              auth.tokens?.accessToken?.nilIfEmpty != nil
        else {
            notes.append("codex candidate \(logPath(url.path)): auth.json has no OAuth access token → skipped")
            return nil
        }

        let payload = auth.tokens?.idToken.flatMap { ProviderParse.jwtPayload($0) }
        let identity = auth.tokens?.accountID?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? DefaultAccountObserver.chatGPTAccountID(inIDTokenPayload: payload)
        guard let identity else {
            notes.append("codex candidate \(logPath(url.path)): credentials name no account → skipped")
            return nil
        }

        let normalized = identity.lowercased()
        notes.append("codex candidate \(logPath(url.path)): accepted (\(ProviderAccountID.hash8(normalized)), file credential)")
        return Finding(
            identityKey: normalized,
            label: (payload?["email"] as? String)?.nilIfEmpty,
            anchorPath: url.path
        )
    }

    private func defaultCodexHomes() -> [String] {
        if let raw = environment.value(for: "CODEX_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map(expandTilde)
        }
        let home = homeDirectory()
        return [
            home.appendingPathComponent(".config/codex").path,
            home.appendingPathComponent(".codex").path
        ]
    }

    private func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory().path + String(path.dropFirst(1))
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: expandTilde(path)).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func logPath(_ path: String) -> String {
        let home = homeDirectory().path
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
