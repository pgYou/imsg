import Commander
import Foundation
import IMsgCore

enum SendCommand {
  static let spec = CommandSpec(
    name: "send",
    abstract: "Send a message (text and/or attachment)",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "to", names: [.long("to")], help: "phone number or email"),
          .make(label: "chatID", names: [.long("chat-id")], help: "chat rowid"),
          .make(
            label: "chatIdentifier", names: [.long("chat-identifier")],
            help: "chat identifier (e.g. iMessage;+;chat...)"),
          .make(label: "chatGUID", names: [.long("chat-guid")], help: "chat guid"),
          .make(
            label: "replyToGUID", names: [.long("reply-to-guid")],
            help: "reply to message guid (not supported by AppleScript)"),
          .make(
            label: "reactionToGUID", names: [.long("reaction-to-guid"), .long("react-to-guid")],
            help: "react to message guid (IMCore only)"),
          .make(
            label: "reaction", names: [.long("reaction"), .long("react")],
            help: "reaction type or emoji (love|like|dislike|laugh|emphasis|question|emoji)"),
          .make(
            label: "mode", names: [.long("mode")],
            help: "send mode: applescript|imcore|auto"),
          .make(label: "text", names: [.long("text")], help: "message body"),
          .make(label: "file", names: [.long("file")], help: "path to attachment"),
          .make(
            label: "service", names: [.long("service")], help: "service to use: imessage|sms|auto"),
          .make(
            label: "region", names: [.long("region")],
            help: "default region for phone normalization"),
        ],
        flags: [
          .make(
            label: "reactionRemove", names: [.long("reaction-remove"), .long("react-remove")],
            help: "remove reaction instead of adding (IMCore only)")
        ]
      )
    ),
    usageExamples: [
      "imsg send --to +14155551212 --text \"hi\"",
      "imsg send --to +14155551212 --text \"hi\" --file ~/Desktop/pic.jpg --service imessage",
      "imsg send --chat-id 1 --text \"hi\"",
      "IMSG_ALLOW_PRIVATE=1 imsg send --mode imcore --reply-to-guid <guid> --text \"hi\"",
      "IMSG_ALLOW_PRIVATE=1 imsg send --mode imcore --reaction like --reaction-to-guid <guid>",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    sendMessage: @escaping (MessageSendOptions) throws -> Void = { try MessageSender().send($0) },
    storeFactory: @escaping (String) throws -> MessageStore = { try MessageStore(path: $0) }
  ) async throws {
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let recipient = values.option("to") ?? ""
    let chatID = values.optionInt64("chatID")
    let chatIdentifier = values.option("chatIdentifier") ?? ""
    let chatGUID = values.option("chatGUID") ?? ""
    let replyToGUID = values.option("replyToGUID") ?? ""
    let reactionToGUID = values.option("reactionToGUID") ?? ""
    let reactionRaw = values.option("reaction") ?? ""
    let reactionRemove = values.flag("reactionRemove")
    let reactionType = reactionRaw.isEmpty ? nil : ReactionType.parse(reactionRaw)
    if !reactionRaw.isEmpty && reactionType == nil {
      throw IMsgError.invalidReaction(reactionRaw)
    }
    let reactionRequested = !reactionToGUID.isEmpty || reactionType != nil || reactionRemove
    if reactionRequested {
      if reactionType == nil {
        throw ParsedValuesError.missingOption("reaction")
      }
      if reactionToGUID.isEmpty {
        throw ParsedValuesError.missingOption("reaction-to-guid")
      }
      if !replyToGUID.isEmpty {
        throw IMsgError.invalidReaction("Reply and reaction are mutually exclusive")
      }
    }
    let modeRaw = values.option("mode") ?? ""
    let mode = modeRaw.isEmpty ? nil : MessageSendMode.parse(modeRaw)
    if !modeRaw.isEmpty && mode == nil {
      throw IMsgError.invalidSendMode(modeRaw)
    }
    let hasChatTarget = chatID != nil || !chatIdentifier.isEmpty || !chatGUID.isEmpty
    if hasChatTarget && !recipient.isEmpty {
      throw ParsedValuesError.invalidOption("to")
    }
    if !hasChatTarget && recipient.isEmpty {
      throw ParsedValuesError.missingOption("to")
    }

    let text = values.option("text") ?? ""
    let file = values.option("file") ?? ""
    if text.isEmpty && file.isEmpty && !reactionRequested {
      throw ParsedValuesError.missingOption("text or file")
    }
    if reactionRequested && !file.isEmpty {
      throw ParsedValuesError.invalidOption("file")
    }
    let serviceRaw = values.option("service") ?? "auto"
    guard let service = MessageService(rawValue: serviceRaw) else {
      throw IMsgError.invalidService(serviceRaw)
    }
    let region = values.option("region") ?? "US"

    var resolvedChatIdentifier = chatIdentifier
    var resolvedChatGUID = chatGUID
    if let chatID {
      let store = try storeFactory(dbPath)
      guard let info = try store.chatInfo(chatID: chatID) else {
        throw IMsgError.invalidChatTarget("Unknown chat id \(chatID)")
      }
      resolvedChatIdentifier = info.identifier
      resolvedChatGUID = info.guid
    }
    if hasChatTarget && resolvedChatIdentifier.isEmpty && resolvedChatGUID.isEmpty {
      throw IMsgError.invalidChatTarget("Missing chat identifier or guid")
    }

    try sendMessage(
      MessageSendOptions(
        recipient: recipient,
        text: text,
        attachmentPath: file,
        service: service,
        region: region,
        chatIdentifier: resolvedChatIdentifier,
        chatGUID: resolvedChatGUID,
        replyToGUID: replyToGUID,
        reactionToGUID: reactionToGUID,
        reactionType: reactionType,
        reactionIsRemoval: reactionRemove,
        mode: mode
      ))

    if runtime.jsonOutput {
      try JSONLines.print(["status": "sent"])
    } else {
      Swift.print("sent")
    }
  }
}
