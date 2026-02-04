import Foundation
import SQLite
import XCTest

@testable import IMsgCore

final class MessageStoreTests: XCTestCase {
  func testListChatsReturnsChat() throws {
    let store = try TestDatabase.makeStore()
    let chats = try store.listChats(limit: 5)
    XCTAssertEqual(chats.count, 1)
    XCTAssertEqual(chats.first?.identifier, "+123")
  }

  func testChatInfoReturnsMetadata() throws {
    let store = try TestDatabase.makeStore()
    let info = try store.chatInfo(chatID: 1)
    XCTAssertEqual(info?.identifier, "+123")
    XCTAssertEqual(info?.guid, "iMessage;+;chat123")
    XCTAssertEqual(info?.name, "Test Chat")
    XCTAssertEqual(info?.service, "iMessage")
  }

  func testParticipantsReturnsUniqueHandles() throws {
    let db = try Connection(.inMemory)
    try db.execute(
      """
      CREATE TABLE chat (
        ROWID INTEGER PRIMARY KEY,
        chat_identifier TEXT,
        guid TEXT,
        display_name TEXT,
        service_name TEXT
      );
      """
    )
    try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
    try db.execute("CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);")
    try db.run(
      """
      INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
      VALUES (1, 'iMessage;+;chat123', 'iMessage;+;chat123', 'Group', 'iMessage')
      """
    )
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123'), (2, 'me@icloud.com')")
    try db.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 1), (1, 2), (1, 1)")

    let store = try MessageStore(connection: db, path: ":memory:")
    let participants = try store.participants(chatID: 1)
    XCTAssertEqual(participants.count, 2)
    XCTAssertTrue(participants.contains("+123"))
    XCTAssertTrue(participants.contains("me@icloud.com"))
  }

  func testMessagesByChatReturnsMessages() throws {
    let store = try TestDatabase.makeStore()
    let messages = try store.messages(chatID: 1, limit: 10)
    XCTAssertEqual(messages.count, 3)
    XCTAssertTrue(messages[1].isFromMe)
    XCTAssertEqual(messages[0].attachmentsCount, 0)
  }

  func testMessagesByChatAppliesDateFilterBeforeLimit() throws {
    let store = try TestDatabase.makeStore()
    let all = try store.messages(chatID: 1, limit: 10)
    let target = all.first { $0.rowID == 2 }
    XCTAssertNotNil(target)

    // Build a tight window around message 2's date so the filter matches it but not the newest message.
    guard let target else { return }
    let filter = MessageFilter(
      startDate: target.date.addingTimeInterval(-1),
      endDate: target.date.addingTimeInterval(1)
    )
    let filtered = try store.messages(chatID: 1, limit: 1, filter: filter)
    XCTAssertEqual(filtered.count, 1)
    XCTAssertEqual(filtered.first?.rowID, 2)
  }

  func testMessagesByChatAppliesParticipantFilterBeforeLimit() throws {
    let store = try TestDatabase.makeStore()

    // Insert a newer "from me" message so limit=1 would pick it unless filtering happens in SQL.
    try store.withConnection { db in
      try db.run(
        """
        INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
        VALUES (4, 2, 'newest from me', ?, 1, 'iMessage')
        """,
        TestDatabase.appleEpoch(Date().addingTimeInterval(5))
      )
      try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 4)")
    }

    let filter = MessageFilter(participants: ["+123"])
    let filtered = try store.messages(chatID: 1, limit: 1, filter: filter)
    XCTAssertEqual(filtered.count, 1)
    XCTAssertEqual(filtered.first?.sender, "+123")
  }

  func testMessagesAfterReturnsMessages() throws {
    let store = try TestDatabase.makeStore()
    let messages = try store.messagesAfter(afterRowID: 1, chatID: nil, limit: 10)
    XCTAssertEqual(messages.count, 2)
    XCTAssertEqual(messages.first?.rowID, 2)
  }

  func testMessagesAfterExcludesReactionRows() throws {
    let db = try Connection(.inMemory)
    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
        guid TEXT,
        associated_message_guid TEXT,
        associated_message_type INTEGER,
        date INTEGER,
        is_from_me INTEGER,
        service TEXT
      );
      """
    )
    try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
    try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
    try db.execute(
      "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);")

    let now = Date()
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
      VALUES (1, 1, 'hello', 'msg-guid-1', NULL, 0, ?, 0, 'iMessage')
      """,
      TestDatabase.appleEpoch(now)
    )
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
      VALUES (2, 1, '', 'reaction-guid-1', 'p:0/msg-guid-1', 2002, ?, 0, 'iMessage')
      """,
      TestDatabase.appleEpoch(now.addingTimeInterval(1))
    )
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
      VALUES (3, 1, 'reply', 'msg-guid-3', 'p:0/msg-guid-1', 1000, ?, 0, 'iMessage')
      """,
      TestDatabase.appleEpoch(now.addingTimeInterval(2))
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 3)")

    let store = try MessageStore(connection: db, path: ":memory:")
    let messages = try store.messagesAfter(afterRowID: 0, chatID: 1, limit: 10)
    let rowIDs = messages.map { $0.rowID }
    XCTAssertEqual(messages.count, 2)
    XCTAssertTrue(rowIDs.contains(1))
    XCTAssertTrue(rowIDs.contains(3))
    XCTAssertFalse(rowIDs.contains(2))
  }

  func testMessagesExcludeReactionRows() throws {
    let db = try Connection(.inMemory)
    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
        guid TEXT,
        associated_message_guid TEXT,
        associated_message_type INTEGER,
        date INTEGER,
        is_from_me INTEGER,
        service TEXT
      );
      """
    )
    try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
    try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
    try db.execute(
      "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);")

    let now = Date()
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
      VALUES (1, 1, 'hello', 'msg-guid-1', NULL, 0, ?, 0, 'iMessage')
      """,
      TestDatabase.appleEpoch(now)
    )
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
      VALUES (2, 1, '', 'reaction-guid-1', 'p:0/msg-guid-1', 2001, ?, 0, 'iMessage')
      """,
      TestDatabase.appleEpoch(now.addingTimeInterval(1))
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")

    let store = try MessageStore(connection: db, path: ":memory:")
    let messages = try store.messages(chatID: 1, limit: 10)
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages.first?.rowID, 1)
  }

  func testMessagesExposeReplyToGuid() throws {
    let db = try Connection(.inMemory)
    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
        guid TEXT,
        associated_message_guid TEXT,
        associated_message_type INTEGER,
        date INTEGER,
        is_from_me INTEGER,
        service TEXT
      );
      """
    )
    try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
    try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
    try db.execute(
      "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);")

    let now = Date()
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
      VALUES (1, 1, 'base', 'msg-guid-1', NULL, 0, ?, 0, 'iMessage')
      """,
      TestDatabase.appleEpoch(now)
    )
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
      VALUES (2, 1, 'reply', 'msg-guid-2', 'p:0/msg-guid-1', 1000, ?, 0, 'iMessage')
      """,
      TestDatabase.appleEpoch(now.addingTimeInterval(1))
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")

    let store = try MessageStore(connection: db, path: ":memory:")
    let messages = try store.messages(chatID: 1, limit: 10)
    let reply = messages.first { $0.rowID == 2 }
    XCTAssertEqual(reply?.guid, "msg-guid-2")
    XCTAssertEqual(reply?.replyToGUID, "msg-guid-1")
  }

  func testMessagesReplyToGuidHandlesNoPrefix() throws {
    let db = try Connection(.inMemory)
    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
        guid TEXT,
        associated_message_guid TEXT,
        associated_message_type INTEGER,
        date INTEGER,
        is_from_me INTEGER,
        service TEXT
      );
      """
    )
    try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
    try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
    try db.execute(
      "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);")

    let now = Date()
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
      VALUES (1, 1, 'base', 'msg-guid-1', NULL, 0, ?, 0, 'iMessage')
      """,
      TestDatabase.appleEpoch(now)
    )
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
      VALUES (2, 1, 'reply', 'msg-guid-2', 'msg-guid-1', 1000, ?, 0, 'iMessage')
      """,
      TestDatabase.appleEpoch(now.addingTimeInterval(1))
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")

    let store = try MessageStore(connection: db, path: ":memory:")
    let messages = try store.messages(chatID: 1, limit: 10)
    let reply = messages.first { $0.rowID == 2 }
    XCTAssertEqual(reply?.replyToGUID, "msg-guid-1")
  }

  func testAttachmentsByMessageReturnsMetadata() throws {
    let store = try TestDatabase.makeStore()
    let attachments = try store.attachments(for: 2)
    XCTAssertEqual(attachments.count, 1)
    XCTAssertEqual(attachments.first?.mimeType, "application/octet-stream")
  }

  func testLongRepeatedPatternMessage() throws {
    // Test the exact pattern that causes crashes: repeated "aaaaaaaaaaaa " pattern
    // This reproduces the UInt8 overflow bug when segment.count > 256
    let db = try Connection(.inMemory)
    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
        attributedBody BLOB,
        date INTEGER,
        is_from_me INTEGER,
        service TEXT
      );
      """
    )
    try db.execute(
      """
      CREATE TABLE chat (
        ROWID INTEGER PRIMARY KEY,
        chat_identifier TEXT,
        guid TEXT,
        display_name TEXT,
        service_name TEXT
      );
      """
    )
    try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
    try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
    try db.execute(
      """
      CREATE TABLE message_attachment_join (
        message_id INTEGER,
        attachment_id INTEGER
      );
      """
    )

    let now = Date()
    // Create message with repeated pattern like "aaaaaaaaaaaa aaaaaaaaaaaa ..."
    // This pattern triggers the UInt8 overflow bug in TypedStreamParser when segment > 256 bytes
    let pattern = "aaaaaaaaaaaa "
    // Creates a message > 1300 bytes
    let longText = String(repeating: pattern, count: 100)
    let bodyBytes = [UInt8(0x01), UInt8(0x2b)] + Array(longText.utf8) + [0x86, 0x84]
    let body = Blob(bytes: bodyBytes)
    try db.run(
      """
      INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
      VALUES (1, '+123', 'iMessage;+;chat123', 'Test Chat', 'iMessage')
      """
    )
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, attributedBody, date, is_from_me, service)
      VALUES (1, 1, NULL, ?, ?, 0, 'iMessage')
      """,
      body,
      TestDatabase.appleEpoch(now)
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

    let store = try MessageStore(connection: db, path: ":memory:")
    let messages = try store.messages(chatID: 1, limit: 10)
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages.first?.text, longText)
    XCTAssertEqual(messages.first?.text.count, longText.count)
  }
}
