import Foundation
import XCTest

@testable import imsg

final class CommandRouterTests: XCTestCase {
  func testCommandRouterPrintsVersionFromEnv() async throws {
    setenv("IMSG_VERSION", "9.9.9-test", 1)
    defer { unsetenv("IMSG_VERSION") }
    let router = CommandRouter()
    XCTAssertEqual(router.version, "9.9.9-test")
    let status = await router.run(argv: ["imsg", "--version"])
    XCTAssertEqual(status, 0)
  }

  func testCommandRouterPrintsHelp() async {
    let router = CommandRouter()
    let status = await router.run(argv: ["imsg", "--help"])
    XCTAssertEqual(status, 0)
  }

  func testCommandRouterUnknownCommand() async {
    let router = CommandRouter()
    let status = await router.run(argv: ["imsg", "nope"])
    XCTAssertEqual(status, 1)
  }
}
