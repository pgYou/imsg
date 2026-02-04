import Combine
import Foundation
import SQLite
import XCTest

@testable import IMsgCore

private enum WatcherTestDatabase {
  static func appleEpoch(_ date: Date) -> Int64 {
    let seconds = date.timeIntervalSince1970 - MessageStore.appleEpochOffset
    return Int64(seconds * 1_000_000_000)
  }

  static func makeStore() throws -> MessageStore {
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
    try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
    try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
    try db.execute(
      "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);")

    let now = Date()
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
      VALUES (1, 1, 'hello', ?, 0, 'iMessage')
      """,
      appleEpoch(now)
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

    return try MessageStore(
      connection: db, path: ":memory:", hasAttributedBody: false, hasReactionColumns: false)
  }
}

final class MessageWatcherTests: XCTestCase {
  func testMessageWatcherYieldsExistingMessages() throws {
    let store = try WatcherTestDatabase.makeStore()
    let watcher = MessageWatcher(store: store)
    let publisher = watcher.publisher(
      chatID: nil,
      sinceRowID: -1,
      configuration: MessageWatcherConfiguration(debounceInterval: 0.01, batchLimit: 10)
    )

    let expectation = self.expectation(description: "Received message")
    var receivedMessage: Message?
    var cancellables = Set<AnyCancellable>()

    publisher
      .first()
      .sink(
        receiveCompletion: { _ in },
        receiveValue: { message in
          receivedMessage = message
          expectation.fulfill()
        }
      )
      .store(in: &cancellables)

    waitForExpectations(timeout: 2)
    XCTAssertEqual(receivedMessage?.text, "hello")
  }
}
