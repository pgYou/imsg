import Foundation
import XCTest

@testable import IMsgCore

final class UtilityTests: XCTestCase {
  func testAttachmentResolverResolvesPaths() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("test.txt")
    try "hi".data(using: .utf8)!.write(to: file)

    let existing = AttachmentResolver.resolve(file.path)
    XCTAssertFalse(existing.missing)
    XCTAssertTrue(existing.resolved.hasSuffix("test.txt"))

    let missing = AttachmentResolver.resolve(dir.appendingPathComponent("missing.txt").path)
    XCTAssertTrue(missing.missing)

    let directory = AttachmentResolver.resolve(dir.path)
    XCTAssertTrue(directory.missing)
  }

  func testAttachmentResolverDisplayNamePrefersTransfer() {
    XCTAssertEqual(
      AttachmentResolver.displayName(filename: "file.dat", transferName: "nice.dat"), "nice.dat")
    XCTAssertEqual(AttachmentResolver.displayName(filename: "file.dat", transferName: ""), "file.dat")
    XCTAssertEqual(AttachmentResolver.displayName(filename: "", transferName: ""), "(unknown)")
  }

  func testIso8601ParserParsesFormats() {
    let fractional = "2024-01-02T03:04:05.678Z"
    let standard = "2024-01-02T03:04:05Z"
    XCTAssertNotNil(ISO8601Parser.parse(fractional))
    XCTAssertNotNil(ISO8601Parser.parse(standard))
    XCTAssertNil(ISO8601Parser.parse(""))
  }

  func testIso8601ParserFormatsDates() {
    let date = Date(timeIntervalSince1970: 0)
    let formatted = ISO8601Parser.format(date)
    XCTAssertTrue(formatted.contains("T"))
    XCTAssertNotNil(ISO8601Parser.parse(formatted))
  }

  func testMessageFilterHonorsParticipantsAndDates() throws {
    let now = Date(timeIntervalSince1970: 1000)
    let message = Message(
      rowID: 1,
      chatID: 1,
      sender: "Alice",
      text: "hi",
      date: now,
      isFromMe: false,
      service: "iMessage",
      handleID: nil,
      attachmentsCount: 0
    )
    let filter = MessageFilter(
      participants: ["alice"],
      startDate: now.addingTimeInterval(-10),
      endDate: now.addingTimeInterval(10)
    )
    XCTAssertTrue(filter.allows(message))
    let pastFilter = MessageFilter(startDate: now.addingTimeInterval(5))
    XCTAssertFalse(pastFilter.allows(message))
  }

  func testMessageFilterRejectsInvalidISO() {
    do {
      _ = try MessageFilter.fromISO(participants: [], startISO: "bad-date", endISO: nil)
      XCTFail("Should have thrown")
    } catch let error as IMsgError {
      switch error {
      case .invalidISODate(let value):
        XCTAssertEqual(value, "bad-date")
      default:
        XCTFail("Unexpected error type")
      }
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testTypedStreamParserPrefersLongestSegment() {
    let short = [UInt8(0x01), UInt8(0x2b)] + Array("short".utf8) + [0x86, 0x84]
    let long = [UInt8(0x01), UInt8(0x2b)] + Array("longer text".utf8) + [0x86, 0x84]
    let data = Data(short + long)
    XCTAssertEqual(TypedStreamParser.parseAttributedBody(data), "longer text")
  }

  func testTypedStreamParserTrimsControlCharacters() {
    let bytes: [UInt8] = [0x00, 0x0A] + Array("hello".utf8)
    let data = Data(bytes)
    XCTAssertEqual(TypedStreamParser.parseAttributedBody(data), "hello")
  }

  func testPhoneNumberNormalizerFormatsValidNumber() {
    let normalizer = PhoneNumberNormalizer()
    let normalized = normalizer.normalize("+1 650-253-0000", region: "US")
    XCTAssertEqual(normalized, "+16502530000")
  }

  func testPhoneNumberNormalizerReturnsInputOnFailure() {
    let normalizer = PhoneNumberNormalizer()
    let normalized = normalizer.normalize("not-a-number", region: "US")
    XCTAssertEqual(normalized, "not-a-number")
  }

  func testMessageSenderBuildsArguments() throws {
    var captured: [String] = []
    let sender = MessageSender(runner: { _, args in
      captured = args
    })
    try sender.send(
      MessageSendOptions(
        recipient: "+16502530000",
        text: "hi",
        attachmentPath: "",
        service: .auto,
        region: "US"
      )
    )
    XCTAssertEqual(captured.count, 7)
    XCTAssertEqual(captured[0], "+16502530000")
    XCTAssertEqual(captured[2], "imessage")
    XCTAssertTrue(captured[5].isEmpty)
    XCTAssertEqual(captured[6], "0")
  }

  func testMessageSenderUsesChatIdentifier() throws {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDir) }
    let attachment = tempDir.appendingPathComponent("file.dat")
    try Data("hello".utf8).write(to: attachment)
    let attachmentsSubdirectory = tempDir.appendingPathComponent("staged")
    try fileManager.createDirectory(at: attachmentsSubdirectory, withIntermediateDirectories: true)

    var captured: [String] = []
    let sender = MessageSender(
      runner: { _, args in captured = args },
      attachmentsSubdirectoryProvider: { attachmentsSubdirectory }
    )
    try sender.send(
      MessageSendOptions(
        recipient: "",
        text: "hi",
        attachmentPath: attachment.path,
        service: .sms,
        region: "US",
        chatIdentifier: "iMessage;+;chat123",
        chatGUID: "ignored-guid"
      )
    )
    XCTAssertEqual(captured[5], "ignored-guid")
    XCTAssertEqual(captured[6], "1")
    XCTAssertEqual(captured[4], "1")
  }

  func testMessageSenderStagesAttachmentsBeforeSend() throws {
    let fileManager = FileManager.default
    let attachmentsSubdirectory = fileManager.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    try fileManager.createDirectory(at: attachmentsSubdirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: attachmentsSubdirectory) }
    let sourceDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: sourceDir) }
    let sourceFile = sourceDir.appendingPathComponent("sample.txt")
    let payload = Data("hi".utf8)
    try payload.write(to: sourceFile)

    var captured: [String] = []
    let sender = MessageSender(
      runner: { _, args in captured = args },
      attachmentsSubdirectoryProvider: { attachmentsSubdirectory }
    )

    try sender.send(
      MessageSendOptions(
        recipient: "+16502530000",
        text: "",
        attachmentPath: sourceFile.path,
        service: .imessage,
        region: "US"
      )
    )

    let stagedPath = captured[3]
    XCTAssertNotEqual(stagedPath, sourceFile.path)
    XCTAssertTrue(stagedPath.hasPrefix(attachmentsSubdirectory.path))
    XCTAssertTrue(fileManager.fileExists(atPath: stagedPath))
    let stagedData = try Data(contentsOf: URL(fileURLWithPath: stagedPath))
    XCTAssertEqual(stagedData, payload)
  }

  func testMessageSenderThrowsWhenAttachmentsSubdirectoryIsReadOnly() throws {
    let fileManager = FileManager.default
    let readOnlyRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: readOnlyRoot, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyRoot.path)
    defer {
      try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyRoot.path)
      try? fileManager.removeItem(at: readOnlyRoot)
    }
    let sourceFile = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let payload = Data("payload".utf8)
    try payload.write(to: sourceFile)
    defer { try? fileManager.removeItem(at: sourceFile) }

    let sender = MessageSender(
      runner: { _, _ in },
      attachmentsSubdirectoryProvider: { readOnlyRoot }
    )

    do {
      try sender.send(
        MessageSendOptions(
          recipient: "+16502530000",
          text: "",
          attachmentPath: sourceFile.path,
          service: .imessage,
          region: "US"
        )
      )
      XCTFail("Should have thrown")
    } catch {
      // Expected
    }
  }

  func testMessageSenderThrowsWhenAttachmentMissing() {
    let fileManager = FileManager.default
    let attachmentsSubdirectory = fileManager.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    try? fileManager.createDirectory(at: attachmentsSubdirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: attachmentsSubdirectory) }
    let missingFile = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    var runnerCalled = false
    let sender = MessageSender(
      runner: { _, _ in runnerCalled = true },
      attachmentsSubdirectoryProvider: { attachmentsSubdirectory }
    )

    do {
      try sender.send(
        MessageSendOptions(
          recipient: "+16502530000",
          text: "",
          attachmentPath: missingFile,
          service: .imessage,
          region: "US"
        )
      )
      XCTFail("Should have thrown")
    } catch let error as IMsgError {
      XCTAssertTrue(error.errorDescription?.contains("Attachment not found") == true)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertFalse(runnerCalled)
  }

  func testMessageSenderTreatsHandleIdentifierAsRecipient() throws {
    var captured: [String] = []
    let sender = MessageSender(runner: { _, args in
      captured = args
    })
    try sender.send(
      MessageSendOptions(
        recipient: "",
        text: "hi",
        attachmentPath: "",
        service: .auto,
        region: "US",
        chatIdentifier: "+16502530000",
        chatGUID: ""
      )
    )
    XCTAssertEqual(captured[0], "+16502530000")
    XCTAssertTrue(captured[5].isEmpty)
    XCTAssertEqual(captured[6], "0")
  }

  func testErrorDescriptionsIncludeDetails() {
    let error = IMsgError.invalidService("weird")
    XCTAssertTrue(error.errorDescription?.contains("Invalid service: weird") == true)
    let chatError = IMsgError.invalidChatTarget("bad")
    XCTAssertTrue(chatError.errorDescription?.contains("Invalid chat target: bad") == true)
    let dateError = IMsgError.invalidISODate("2024-99-99")
    XCTAssertTrue(dateError.errorDescription?.contains("Invalid ISO8601 date") == true)
    let scriptError = IMsgError.appleScriptFailure("nope")
    XCTAssertTrue(scriptError.errorDescription?.contains("AppleScript failed: nope") == true)
    let underlying = NSError(domain: "Test", code: 1)
    let permission = IMsgError.permissionDenied(path: "/tmp/chat.db", underlying: underlying)
    let permissionDescription = permission.errorDescription ?? ""
    XCTAssertTrue(permissionDescription.contains("Permission Error"))
    XCTAssertTrue(permissionDescription.contains("/tmp/chat.db"))
  }
}
