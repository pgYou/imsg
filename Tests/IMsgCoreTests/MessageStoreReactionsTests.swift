import Foundation
import SQLite
import XCTest

@testable import IMsgCore

private enum ReactionTestDatabase {
  static func appleEpoch(_ date: Date) -> Int64 {
    let seconds = date.timeIntervalSince1970 - MessageStore.appleEpochOffset
    return Int64(seconds * 1_000_000_000)
  }

  static func makeConnection() throws -> Connection {
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
    try db.execute(
      """
      CREATE TABLE chat (
        ROWID INTEGER PRIMARY KEY,
        chat_identifier TEXT,
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
    return db
  }

  static func seedBaseMessage(
    _ db: Connection,
    now: Date,
    messageID: Int64 = 1,
    guid: String = "msg-guid-1",
    text: String = "Hello world"
  ) throws {
    try db.run(
      """
      INSERT INTO chat(ROWID, chat_identifier, display_name, service_name)
      VALUES (1, '+123', 'Test Chat', 'iMessage')
      """
    )
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123'), (2, '+456')")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
      VALUES (?, 1, ?, ?, NULL, 0, ?, 0, 'iMessage')
      """,
      messageID,
      text,
      guid,
      appleEpoch(now.addingTimeInterval(-600))
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, ?)", messageID)
  }
}

final class MessageStoreReactionsTests: XCTestCase {
  func testReactionsForMessageReturnsReactions() throws {
    let db = try ReactionTestDatabase.makeConnection()
    let now = Date()
    try ReactionTestDatabase.seedBaseMessage(db, now: now)

    // Love reaction from +456
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
      VALUES (2, 2, '', 'reaction-guid-1', 'p:0/msg-guid-1', 2000, ?, 0, 'iMessage')
      """,
      ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-500))
    )
    // Like reaction from me
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
      VALUES (3, 1, '', 'reaction-guid-2', 'p:0/msg-guid-1', 2001, ?, 1, 'iMessage')
      """,
      ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-400))
    )
    // Laugh reaction from +456
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
      VALUES (4, 2, '', 'reaction-guid-3', 'p:0/msg-guid-1', 2003, ?, 0, 'iMessage')
      """,
      ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-300))
    )
    // Custom emoji reaction (type 2006) from +456
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
      VALUES (5, 2, 'Reacted 🎉 to "Hello world"', 'reaction-guid-4', 'p:0/msg-guid-1', 2006, ?, 0, 'iMessage')
      """,
      ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-200))
    )

    let store = try MessageStore(connection: db, path: ":memory:")
    let reactions = try store.reactions(for: 1)

    XCTAssertEqual(reactions.count, 4)

    XCTAssertEqual(reactions[0].reactionType, .love)
    XCTAssertEqual(reactions[0].sender, "+456")
    XCTAssertEqual(reactions[0].isFromMe, false)

    XCTAssertEqual(reactions[1].reactionType, .like)
    XCTAssertEqual(reactions[1].isFromMe, true)

    XCTAssertEqual(reactions[2].reactionType, .laugh)
    XCTAssertEqual(reactions[2].sender, "+456")

    XCTAssertEqual(reactions[3].reactionType, .custom("🎉"))
    XCTAssertEqual(reactions[3].reactionType.emoji, "🎉")
    XCTAssertEqual(reactions[3].sender, "+456")
  }

  func testReactionsForMessageWithNoReactionsReturnsEmpty() throws {
    let db = try ReactionTestDatabase.makeConnection()
    let now = Date()
    try ReactionTestDatabase.seedBaseMessage(db, now: now, text: "No reactions here")

    let store = try MessageStore(connection: db, path: ":memory:")
    let reactions = try store.reactions(for: 1)

    XCTAssertTrue(reactions.isEmpty)
  }

  func testReactionsForMessageRemovesReactions() throws {
    let db = try ReactionTestDatabase.makeConnection()
    let now = Date()
    try ReactionTestDatabase.seedBaseMessage(db, now: now)

    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
      VALUES (2, 2, '', 'reaction-guid-1', 'p:0/msg-guid-1', 2001, ?, 0, 'iMessage')
      """,
      ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-500))
    )
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
      VALUES (3, 2, 'Removed a like', 'reaction-guid-2', 'p:0/msg-guid-1', 3001, ?, 0, 'iMessage')
      """,
      ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-400))
    )

    let store = try MessageStore(connection: db, path: ":memory:")
    let reactions = try store.reactions(for: 1)

    XCTAssertTrue(reactions.isEmpty)
  }

  func testReactionsForMessageParsesCustomEmojiWithoutEnglishPrefix() throws {
    let db = try ReactionTestDatabase.makeConnection()
    let now = Date()
    try ReactionTestDatabase.seedBaseMessage(db, now: now)

    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
      VALUES (2, 2, '🎉 reagiu a "Hello world"', 'reaction-guid-1', 'p:0/msg-guid-1', 2006, ?, 0, 'iMessage')
      """,
      ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-500))
    )

    let store = try MessageStore(connection: db, path: ":memory:")
    let reactions = try store.reactions(for: 1)

    XCTAssertEqual(reactions.count, 1)
    XCTAssertEqual(reactions[0].reactionType, .custom("🎉"))
  }

  func testReactionsMatchGuidWithoutPrefix() throws {
    let db = try ReactionTestDatabase.makeConnection()
    let now = Date()
    try ReactionTestDatabase.seedBaseMessage(db, now: now)

    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
      VALUES (2, 2, '', 'reaction-guid-1', 'msg-guid-1', 2000, ?, 0, 'iMessage')
      """,
      ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-500))
    )

    let store = try MessageStore(connection: db, path: ":memory:")
    let reactions = try store.reactions(for: 1)

    XCTAssertEqual(reactions.count, 1)
    XCTAssertEqual(reactions[0].reactionType, .love)
  }

  func testReactionsForMessageRemovesCustomEmojiWithoutEmojiText() throws {
    let db = try ReactionTestDatabase.makeConnection()
    let now = Date()
    try ReactionTestDatabase.seedBaseMessage(db, now: now)

    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
      VALUES (2, 2, 'Reacted 🎉 to "Hello world"', 'reaction-guid-1', 'p:0/msg-guid-1', 2006, ?, 0, 'iMessage')
      """,
      ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-500))
    )
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, associated_message_guid, associated_message_type, date, is_from_me, service)
      VALUES (3, 2, 'Removed a reaction', 'reaction-guid-2', 'p:0/msg-guid-1', 3006, ?, 0, 'iMessage')
      """,
      ReactionTestDatabase.appleEpoch(now.addingTimeInterval(-400))
    )

    let store = try MessageStore(connection: db, path: ":memory:")
    let reactions = try store.reactions(for: 1)

    XCTAssertTrue(reactions.isEmpty)
  }

  func testReactionsForMessageReturnsEmptyWhenColumnsMissing() throws {
    let db = try Connection(.inMemory)
    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
        date INTEGER,
        is_from_me INTEGER,
        service TEXT
      );
      """
    )
    let store = try MessageStore(connection: db, path: ":memory:")
    let reactions = try store.reactions(for: 1)

    XCTAssertTrue(reactions.isEmpty)
  }

  func testReactionTypeProperties() throws {
    XCTAssertEqual(ReactionType.love.name, "love")
    XCTAssertEqual(ReactionType.love.emoji, "❤️")
    XCTAssertEqual(ReactionType.like.name, "like")
    XCTAssertEqual(ReactionType.like.emoji, "👍")
    XCTAssertEqual(ReactionType.dislike.name, "dislike")
    XCTAssertEqual(ReactionType.dislike.emoji, "👎")
    XCTAssertEqual(ReactionType.laugh.name, "laugh")
    XCTAssertEqual(ReactionType.laugh.emoji, "😂")
    XCTAssertEqual(ReactionType.emphasis.name, "emphasis")
    XCTAssertEqual(ReactionType.emphasis.emoji, "‼️")
    XCTAssertEqual(ReactionType.question.name, "question")
    XCTAssertEqual(ReactionType.question.emoji, "❓")
    XCTAssertEqual(ReactionType.custom("🎉").name, "custom")
    XCTAssertEqual(ReactionType.custom("🎉").emoji, "🎉")
  }

  func testReactionTypeFromRawValue() throws {
    XCTAssertEqual(ReactionType(rawValue: 2000), .love)
    XCTAssertEqual(ReactionType(rawValue: 2001), .like)
    XCTAssertEqual(ReactionType(rawValue: 2002), .dislike)
    XCTAssertEqual(ReactionType(rawValue: 2003), .laugh)
    XCTAssertEqual(ReactionType(rawValue: 2004), .emphasis)
    XCTAssertEqual(ReactionType(rawValue: 2005), .question)
    XCTAssertEqual(ReactionType(rawValue: 2006, customEmoji: "🎉"), .custom("🎉"))
    XCTAssertNil(ReactionType(rawValue: 2006))
    XCTAssertNil(ReactionType(rawValue: 9999))
  }

  func testReactionTypeHelpers() throws {
    XCTAssertTrue(ReactionType.isReactionAdd(2000))
    XCTAssertTrue(ReactionType.isReactionAdd(2005))
    XCTAssertTrue(ReactionType.isReactionAdd(2006))
    XCTAssertFalse(ReactionType.isReactionAdd(1999))
    XCTAssertFalse(ReactionType.isReactionAdd(2007))

    XCTAssertTrue(ReactionType.isReactionRemove(3000))
    XCTAssertTrue(ReactionType.isReactionRemove(3005))
    XCTAssertTrue(ReactionType.isReactionRemove(3006))
    XCTAssertFalse(ReactionType.isReactionRemove(2999))
    XCTAssertFalse(ReactionType.isReactionRemove(3007))

    XCTAssertEqual(ReactionType.fromRemoval(3000), .love)
    XCTAssertEqual(ReactionType.fromRemoval(3001), .like)
    XCTAssertEqual(ReactionType.fromRemoval(3005), .question)
    XCTAssertEqual(ReactionType.fromRemoval(3006, customEmoji: "🎉"), .custom("🎉"))
  }
}
