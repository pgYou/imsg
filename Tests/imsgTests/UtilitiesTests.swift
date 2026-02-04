import Foundation
import XCTest

@testable import IMsgCore
@testable import imsg

final class UtilitiesTests: XCTestCase {
  func testDurationParserHandlesUnits() {
    XCTAssertEqual(DurationParser.parse("250ms"), 0.25)
    XCTAssertEqual(DurationParser.parse("2s"), 2)
    XCTAssertEqual(DurationParser.parse("3m"), 180)
    XCTAssertEqual(DurationParser.parse("1h"), 3600)
    XCTAssertEqual(DurationParser.parse("5"), 5)
    XCTAssertNil(DurationParser.parse("bad"))
  }

  func testAttachmentDisplayPrefersTransferName() {
    let meta = AttachmentMeta(
      filename: "file.dat",
      transferName: "friendly.dat",
      uti: "",
      mimeType: "",
      totalBytes: 0,
      isSticker: false,
      originalPath: "",
      missing: false
    )
    XCTAssertEqual(displayName(for: meta), "friendly.dat")
    let fallback = AttachmentMeta(
      filename: "file.dat",
      transferName: "",
      uti: "",
      mimeType: "",
      totalBytes: 0,
      isSticker: false,
      originalPath: "",
      missing: false
    )
    XCTAssertEqual(displayName(for: fallback), "file.dat")
    let unknown = AttachmentMeta(
      filename: "",
      transferName: "",
      uti: "",
      mimeType: "",
      totalBytes: 0,
      isSticker: false,
      originalPath: "",
      missing: false
    )
    XCTAssertEqual(displayName(for: unknown), "(unknown)")
    XCTAssertEqual(pluralSuffix(for: 1), "")
    XCTAssertEqual(pluralSuffix(for: 2), "s")
  }

  func testJsonLinesPrintsSingleLineJSON() throws {
    let line = try JSONLines.encode(["status": "ok"])
    let data = line.data(using: .utf8)!
    let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    XCTAssertEqual(decoded?["status"] as? String, "ok")
  }

  func testOutputModelsEncodeExpectedKeys() throws {
    let chat = Chat(
      id: 1, identifier: "+123", name: "Test", service: "iMessage",
      lastMessageAt: Date(timeIntervalSince1970: 0))
    let chatPayload = ChatPayload(chat: chat)
    let chatData = try JSONEncoder().encode(chatPayload)
    let chatObject = try JSONSerialization.jsonObject(with: chatData) as? [String: Any]
    XCTAssertNotNil(chatObject?["last_message_at"])

    let message = Message(
      rowID: 7,
      chatID: 1,
      sender: "+123",
      text: "hi",
      date: Date(timeIntervalSince1970: 1),
      isFromMe: false,
      service: "iMessage",
      handleID: nil,
      attachmentsCount: 0,
      guid: "msg-guid-7",
      replyToGUID: "msg-guid-1"
    )
    let attachment = AttachmentMeta(
      filename: "file.dat",
      transferName: "",
      uti: "public.data",
      mimeType: "application/octet-stream",
      totalBytes: 10,
      isSticker: false,
      originalPath: "/tmp/file.dat",
      missing: false
    )
    let reaction = Reaction(
      rowID: 99,
      reactionType: .like,
      sender: "+123",
      isFromMe: true,
      date: Date(timeIntervalSince1970: 2),
      associatedMessageID: 7
    )
    let messagePayload = MessagePayload(
      message: message, attachments: [attachment], reactions: [reaction])
    let messageData = try JSONEncoder().encode(messagePayload)
    let messageObject = try JSONSerialization.jsonObject(with: messageData) as? [String: Any]
    XCTAssertEqual(messageObject?["chat_id"] as? Int64, 1)
    XCTAssertEqual(messageObject?["guid"] as? String, "msg-guid-7")
    XCTAssertEqual(messageObject?["reply_to_guid"] as? String, "msg-guid-1")
    XCTAssertNotNil(messageObject?["created_at"])

    let attachmentPayload = AttachmentPayload(meta: attachment)
    let attachmentData = try JSONEncoder().encode(attachmentPayload)
    let attachmentObject = try JSONSerialization.jsonObject(with: attachmentData) as? [String: Any]
    XCTAssertEqual(attachmentObject?["transfer_name"] as? String, "")
    XCTAssertEqual(attachmentObject?["mime_type"] as? String, "application/octet-stream")
  }

  func testParsedValuesHelpers() throws {
    let values = ParsedValues(
      options: ["limit": ["5", "9"], "name": ["bob"], "logLevel": ["debug"]],
      flags: ["jsonOutput", "verbose"],
      positional: ["first"]
    )
    XCTAssertEqual(values.flag("jsonOutput"), true)
    XCTAssertEqual(values.option("name"), "bob")
    XCTAssertEqual(values.optionValues("limit").count, 2)
    XCTAssertEqual(values.optionInt("limit"), 9)
    XCTAssertEqual(values.optionInt64("limit"), 9)
    XCTAssertEqual(values.argument(0), "first")
    do {
      _ = try values.optionRequired("missing")
      XCTFail("Should have thrown")
    } catch let error as ParsedValuesError {
      XCTAssertTrue(error.description.contains("Missing required option"))
    }

    let runtime = RuntimeOptions(parsedValues: values)
    XCTAssertEqual(runtime.jsonOutput, true)
    XCTAssertEqual(runtime.verbose, true)
    XCTAssertEqual(runtime.logLevel, "debug")
  }
}
