import XCTest
@testable import OpenUsage

final class CodexHomeDiscoveryTests: XCTestCase {
    private func makeDiscovery(
        environment: [String: String] = [:],
        files: [String: String],
        subdirectories: [String]
    ) -> CodexHomeDiscovery {
        CodexHomeDiscovery(
            environment: FakeEnvironment(environment),
            files: FakeFiles(files),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
            listSubdirectories: { url in
                subdirectories
                    .map { URL(fileURLWithPath: $0) }
                    .filter { $0.deletingLastPathComponent().path == url.path }
            }
        )
    }

    func testFindsFileBackedAccountWithProviderIdentity() throws {
        let token = idToken(email: "work@example.com")
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.codex-work/auth.json": #"{"tokens":{"access_token":"at","account_id":"ACCOUNT-WORK","id_token":"\#(token)"}}"#,
            ],
            subdirectories: ["/Users/dev/.codex-work"]
        )

        let finding = try XCTUnwrap(discovery.run().findings.first)

        XCTAssertEqual(finding.identityKey, "account-work")
        XCTAssertEqual(finding.label, "work@example.com")
        XCTAssertEqual(finding.anchorPath, "/Users/dev/.codex-work")
    }

    func testRejectsCredentialWithoutAccountIdentity() {
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.codex-work/auth.json": #"{"tokens":{"access_token":"at"}}"#,
            ],
            subdirectories: ["/Users/dev/.codex-work"]
        )

        let result = discovery.run()

        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertTrue(result.notes.contains { $0.contains("names no account") })
    }

    func testExcludesConfiguredDefaultHome() {
        let discovery = makeDiscovery(
            environment: ["CODEX_HOME": "~/.codex-work"],
            files: [
                "/Users/dev/.codex-work/auth.json": #"{"tokens":{"access_token":"at","account_id":"account-work"}}"#,
            ],
            subdirectories: ["/Users/dev/.codex-work"]
        )

        XCTAssertTrue(discovery.run().findings.isEmpty)
    }

    private func idToken(email: String) -> String {
        func base64URL(_ value: String) -> String {
            Data(value.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(base64URL(#"{"alg":"none"}"#)).\(base64URL(#"{"email":"\#(email)"}"#)).sig"
    }
}
