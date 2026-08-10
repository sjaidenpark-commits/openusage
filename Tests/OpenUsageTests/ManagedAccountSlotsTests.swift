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
        XCTAssertEqual(
            ManagedAccountSlots.nextSlotNumber(
                existingNames: [".codex-account-2", ".codex-account-3", ".codex-account-4"],
                prefix: ".codex-account-"
            ),
            5,
            "account creation keeps extending past the prepared second slot"
        )
    }
}
