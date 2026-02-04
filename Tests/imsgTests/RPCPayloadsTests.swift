import Foundation
import XCTest

@testable import IMsgCore
@testable import imsg

final class RPCPayloadsTests: XCTestCase {
  func testIsGroupHandleFlagsGroup() {
    XCTAssertEqual(isGroupHandle(identifier: "iMessage;+;chat123", guid: ""), true)
    XCTAssertEqual(isGroupHandle(identifier: "", guid: "iMessage;-;chat999"), true)
    XCTAssertEqual(isGroupHandle(identifier: "+1555", guid: ""), false)
  }

  func testChatPayloadIncludesParticipantsAndGroupFlag() {
    let date = Date(timeIntervalSince1970: 0)
    let payload = chatPayload(
      id: 1,
      identifier: "iMessage;+;chat123",
      guid: "iMessage;+;chat123",
      name: "Group",
      service: "iMessage",
      lastMessageAt: date,
      participants: ["+111", "+222"]
    )
    XCTAssertEqual(payload["id"] as? Int64, 1)
    XCTAssertEqual(payload["identifier"] as? String, "iMessage;+;chat123")
    XCTAssertEqual(payload["is_group"] as? Bool, true)
    XCTAssertEqual((payload["participants"] as? [String])?.count, 2)
  }

  func testMessagePayloadIncludesChatFields() {
    let message = Message(
      rowID: 5,
      chatID: 10,
      sender: "+123",
      text: "hello",
      date: Date(timeIntervalSince1970: 1),
      isFromMe: false,
      service: "iMessage",
      handleID: nil,
      attachmentsCount: 1,
      guid: "msg-guid-5",
      replyToGUID: "msg-guid-1"
    )
    let chatInfo = ChatInfo(
      id: 10,
      identifier: "iMessage;+;chat123",
      guid: "iMessage;+;chat123",
      name: "Group",
      service: "iMessage"
    )
    let attachment = AttachmentMeta(
      filename: "file.dat",
      transferName: "file.dat",
      uti: "public.data",
      mimeType: "application/octet-stream",
      totalBytes: 12,
      isSticker: false,
      originalPath: "/tmp/file.dat",
      missing: false
    )
    let reaction = Reaction(
      rowID: 99,
      reactionType: .like,
      sender: "+123",
      isFromMe: false,
      date: Date(timeIntervalSince1970: 2),
      associatedMessageID: 5
    )
    let payload = messagePayload(
      message: message,
      chatInfo: chatInfo,
      participants: ["+111"],
      attachments: [attachment],
      reactions: [reaction]
    )
    XCTAssertEqual(payload["chat_id"] as? Int64, 10)
    XCTAssertEqual(payload["guid"] as? String, "msg-guid-5")
    XCTAssertEqual(payload["reply_to_guid"] as? String, "msg-guid-1")
    XCTAssertEqual(payload["chat_identifier"] as? String, "iMessage;+;chat123")
    XCTAssertEqual(payload["chat_name"] as? String, "Group")
    XCTAssertEqual(payload["is_group"] as? Bool, true)
    XCTAssertEqual((payload["attachments"] as? [[String: Any]])?.count, 1)
    XCTAssertEqual(
      (payload["reactions"] as? [[String: Any]])?.first?["emoji"] as? String,
      ReactionType.like.emoji)
  }

  func testMessagePayloadOmitsEmptyReplyToGuid() {
    let message = Message(
      rowID: 6,
      chatID: 10,
      sender: "+123",
      text: "hello",
      date: Date(timeIntervalSince1970: 1),
      isFromMe: false,
      service: "iMessage",
      handleID: nil,
      attachmentsCount: 0,
      guid: "msg-guid-6",
      replyToGUID: nil
    )
    let payload = messagePayload(
      message: message,
      chatInfo: nil,
      participants: [],
      attachments: [],
      reactions: []
    )
    XCTAssertNil(payload["reply_to_guid"])
    XCTAssertEqual(payload["guid"] as? String, "msg-guid-6")
  }

  func testParamParsingHelpers() {
    XCTAssertEqual(stringParam(123 as NSNumber), "123")
    XCTAssertEqual(intParam("42"), 42)
    XCTAssertNotNil(int64Param(NSNumber(value: 9_223_372_036_854_775_000 as Int64)))
    XCTAssertEqual(boolParam("true"), true)
    XCTAssertEqual(boolParam("false"), false)
    XCTAssertEqual(stringArrayParam("a,b , c").count, 3)
    XCTAssertEqual(stringArrayParam(["x", "y"]).count, 2)
  }
}
