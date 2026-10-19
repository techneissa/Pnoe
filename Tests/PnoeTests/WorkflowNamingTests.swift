import XCTest

final class WorkflowNamingTests: XCTestCase {
    func testFreeNameIsKept() {
        XCTAssertEqual(WorkflowNaming.uniqueName("Email", existing: []), "Email")
        XCTAssertEqual(WorkflowNaming.uniqueName("Email", existing: ["Rewrite"]), "Email")
    }

    func testTakenNameGetsTheFirstFreeNumber() {
        XCTAssertEqual(WorkflowNaming.uniqueName("Email", existing: ["Email"]), "Email 2")
        XCTAssertEqual(WorkflowNaming.uniqueName("Email", existing: ["Email", "Email 2"]), "Email 3")
        XCTAssertEqual(WorkflowNaming.uniqueName("Email", existing: ["Email", "Email 3"]), "Email 2")
    }
}
