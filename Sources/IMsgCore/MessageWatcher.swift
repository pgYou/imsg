import Darwin
import Foundation
import Combine

public struct MessageWatcherConfiguration: Sendable, Equatable {
  public var debounceInterval: TimeInterval
  public var batchLimit: Int

  public init(debounceInterval: TimeInterval = 0.25, batchLimit: Int = 100) {
    self.debounceInterval = debounceInterval
    self.batchLimit = batchLimit
  }
}

public final class MessageWatcher {
  private let store: MessageStore

  public init(store: MessageStore) {
    self.store = store
  }

  public func publisher(
    chatID: Int64? = nil,
    sinceRowID: Int64? = nil,
    configuration: MessageWatcherConfiguration = MessageWatcherConfiguration()
  ) -> AnyPublisher<Message, Error> {
    let subject = PassthroughSubject<Message, Error>()
    let state = WatchState(
      store: store,
      chatID: chatID,
      sinceRowID: sinceRowID,
      configuration: configuration,
      subject: subject
    )
    state.start()
    
    return subject
      .handleEvents(receiveCancel: {
        state.stop()
      })
      .eraseToAnyPublisher()
  }
}

private final class WatchState {
  private let store: MessageStore
  private let chatID: Int64?
  private let configuration: MessageWatcherConfiguration
  private let subject: PassthroughSubject<Message, Error>
  private let queue = DispatchQueue(label: "imsg.watch", qos: .userInitiated)

  private var cursor: Int64
  private var sources: [DispatchSourceFileSystemObject] = []
  private var pending = false

  init(
    store: MessageStore,
    chatID: Int64?,
    sinceRowID: Int64?,
    configuration: MessageWatcherConfiguration,
    subject: PassthroughSubject<Message, Error>
  ) {
    self.store = store
    self.chatID = chatID
    self.configuration = configuration
    self.subject = subject
    self.cursor = sinceRowID ?? 0
  }

  func start() {
    queue.async {
      do {
        if self.cursor == 0 {
          self.cursor = try self.store.maxRowID()
        }
        self.poll()
      } catch {
        self.subject.send(completion: .failure(error))
      }
    }

    let paths = [store.path, store.path + "-wal", store.path + "-shm"]
    for path in paths {
      if let source = makeSource(path: path) {
        sources.append(source)
      }
    }
  }

  func stop() {
    queue.async {
      for source in self.sources {
        source.cancel()
      }
      self.sources.removeAll()
      self.subject.send(completion: .finished)
    }
  }

  private func makeSource(path: String) -> DispatchSourceFileSystemObject? {
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return nil }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .extend, .rename, .delete],
      queue: queue
    )
    source.setEventHandler { [weak self] in
      self?.schedulePoll()
    }
    source.setCancelHandler {
      close(fd)
    }
    source.resume()
    return source
  }

  private func schedulePoll() {
    if pending { return }
    pending = true
    let delay = configuration.debounceInterval
    queue.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      self.pending = false
      self.poll()
    }
  }

  private func poll() {
    do {
      let messages = try store.messagesAfter(
        afterRowID: cursor,
        chatID: chatID,
        limit: configuration.batchLimit
      )
      for message in messages {
        subject.send(message)
        if message.rowID > cursor {
          cursor = message.rowID
        }
      }
    } catch {
      subject.send(completion: .failure(error))
    }
  }
}
