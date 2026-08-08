import XCTest
@testable import OpenUsage

final class ManagedAccountSlotsTests: XCTestCase {
    func testNextSlotFillsTheFirstGapAndIgnoresForeignNames() {
        XCTAssertEqual(
            ManagedAccountSlots.nextSlotNumber(
                existingNames: [".claude-account-2", ".claude-account-4", ".codex-account-3"],
                prefix: ".claude-account-"
            ),
            3
        )
    }
}
