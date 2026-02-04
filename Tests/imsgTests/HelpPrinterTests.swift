import Foundation
import XCTest

@testable import imsg

final class HelpPrinterTests: XCTestCase {
  func testHelpPrinterPrintsCommandDetails() throws {
    let signature = CommandSignature(
      options: [
        .make(label: "opt", names: [.short("o"), .long("opt")], help: "opt help")
      ],
      flags: [
        .make(label: "flag", names: [.short("f"), .long("flag")], help: "flag help")
      ],
      arguments: [
        .make(label: "arg", help: "arg help")
      ]
    )
    let spec = CommandSpec(
      name: "demo",
      abstract: "Demo command",
      discussion: "Extra details",
      signature: signature,
      usageExamples: ["imsg demo --opt 1"]
    ) { _, _ in }

    let lines = HelpPrinter.renderCommand(rootName: "imsg", spec: spec)
    let output = lines.joined(separator: "\n")
    XCTAssertTrue(output.contains("imsg demo"))
    XCTAssertTrue(output.contains("Arguments:"))
    XCTAssertTrue(output.contains("Options:"))
    XCTAssertTrue(output.contains("-o, --opt <value>"))
    XCTAssertTrue(output.contains("-f, --flag"))
  }
}
