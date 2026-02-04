// Commander compatibility layer for Swift 5.9 migration
// Provides types previously imported from Commander framework

import Foundation

// MARK: - Stderr Output Stream

public struct StderrOutputStream: TextOutputStream {
  public static var shared = StderrOutputStream()
  public mutating func write(_ string: String) {
    FileHandle.standardError.write(Data(string.utf8))
  }
}

// MARK: - Name Types

public enum CommanderName: Equatable, Hashable {
  case short(Character)
  case long(String)
  case aliasShort(Character)
  case aliasLong(String)

  var isShort: Bool {
    switch self {
    case .short, .aliasShort: return true
    case .long, .aliasLong: return false
    }
  }

  var stringValue: String {
    switch self {
    case .short(let c), .aliasShort(let c): return String(c)
    case .long(let s), .aliasLong(let s): return s
    }
  }
}

// MARK: - Option Parsing Mode

public enum OptionParsingMode {
  case single
  case upToNextOption
}

// MARK: - Definition Types

public struct OptionDefinition {
  public let label: String
  public let names: [CommanderName]
  public let help: String?
  public let parsing: OptionParsingMode

  public static func make(
    label: String,
    names: [CommanderName],
    help: String? = nil,
    parsing: OptionParsingMode = .single
  ) -> OptionDefinition {
    OptionDefinition(label: label, names: names, help: help, parsing: parsing)
  }
}

public struct FlagDefinition {
  public let label: String
  public let names: [CommanderName]
  public let help: String?

  public static func make(
    label: String,
    names: [CommanderName],
    help: String? = nil
  ) -> FlagDefinition {
    FlagDefinition(label: label, names: names, help: help)
  }
}

public struct ArgumentDefinition {
  public let label: String
  public let help: String?
  public let isOptional: Bool

  public static func make(
    label: String,
    help: String? = nil,
    isOptional: Bool = false
  ) -> ArgumentDefinition {
    ArgumentDefinition(label: label, help: help, isOptional: isOptional)
  }
}

// MARK: - Command Signature

public struct CommandSignature {
  public var options: [OptionDefinition]
  public var flags: [FlagDefinition]
  public var arguments: [ArgumentDefinition]

  public init(
    options: [OptionDefinition] = [],
    flags: [FlagDefinition] = [],
    arguments: [ArgumentDefinition] = []
  ) {
    self.options = options
    self.flags = flags
    self.arguments = arguments
  }

  public func withStandardRuntimeFlags() -> CommandSignature {
    var copy = self
    copy.flags.append(contentsOf: [
      .make(label: "jsonOutput", names: [.long("json")], help: "Output as JSON lines"),
      .make(label: "verbose", names: [.long("verbose"), .short("v")], help: "Verbose output"),
    ])
    copy.options.append(
      .make(label: "logLevel", names: [.long("log-level")], help: "Log level")
    )
    return copy
  }
}

// MARK: - Command Descriptor

public struct CommandDescriptor {
  public let name: String
  public let abstract: String
  public let discussion: String?
  public let signature: CommandSignature
  public let subcommands: [CommandDescriptor]

  public init(
    name: String,
    abstract: String,
    discussion: String? = nil,
    signature: CommandSignature = CommandSignature(),
    subcommands: [CommandDescriptor] = []
  ) {
    self.name = name
    self.abstract = abstract
    self.discussion = discussion
    self.signature = signature
    self.subcommands = subcommands
  }
}

// MARK: - Parsed Values

public struct ParsedValues {
  public var options: [String: [String]]
  public var flags: Set<String>
  public var positional: [String]

  public init(
    options: [String: [String]] = [:],
    flags: Set<String> = [],
    positional: [String] = []
  ) {
    self.options = options
    self.flags = flags
    self.positional = positional
  }
}

// MARK: - Invocation

public struct Invocation {
  public let path: [String]
  public let parsedValues: ParsedValues
}

// MARK: - Program Error

public enum CommanderProgramError: Error, CustomStringConvertible {
  case missingSubcommand
  case unknownCommand(String)
  case missingRequiredOption(String)
  case invalidValue(option: String, value: String)
  case unexpectedArgument(String)

  public var description: String {
    switch self {
    case .missingSubcommand:
      return "Missing subcommand"
    case .unknownCommand(let name):
      return "Unknown command: \(name)"
    case .missingRequiredOption(let name):
      return "Missing required option: --\(name)"
    case .invalidValue(let option, let value):
      return "Invalid value '\(value)' for option --\(option)"
    case .unexpectedArgument(let arg):
      return "Unexpected argument: \(arg)"
    }
  }
}

// MARK: - Program

public final class Program {
  private let descriptors: [CommandDescriptor]

  public init(descriptors: [CommandDescriptor]) {
    self.descriptors = descriptors
  }

  public func resolve(argv: [String]) throws -> Invocation {
    guard argv.count >= 1 else {
      throw CommanderProgramError.missingSubcommand
    }

    let rootName = argv[0]
    guard let root = descriptors.first(where: { $0.name == rootName }) else {
      throw CommanderProgramError.unknownCommand(rootName)
    }

    if argv.count < 2 {
      throw CommanderProgramError.missingSubcommand
    }

    let commandName = argv[1]
    guard let subcommand = root.subcommands.first(where: { $0.name == commandName }) else {
      throw CommanderProgramError.unknownCommand(commandName)
    }

    let parsedValues = try parse(
      argv: Array(argv.dropFirst(2)),
      signature: subcommand.signature
    )

    return Invocation(
      path: [rootName, commandName],
      parsedValues: parsedValues
    )
  }

  private func parse(argv: [String], signature: CommandSignature) throws -> ParsedValues {
    var options: [String: [String]] = [:]
    var flags: Set<String> = []
    var positional: [String] = []

    let optionMap = buildOptionMap(signature.options)
    let flagMap = buildFlagMap(signature.flags)

    var i = 0
    while i < argv.count {
      let token = argv[i]

      if token == "--" {
        // Everything after -- is positional
        positional.append(contentsOf: argv[(i + 1)...])
        break
      }

      if token.hasPrefix("--") {
        let name = String(token.dropFirst(2))
        if let (eqIdx, _) = name.firstIndexAndElement(where: { $0 == "=" }) {
          // --option=value
          let optName = String(name[..<eqIdx])
          let optValue = String(name[name.index(after: eqIdx)...])
          if let def = optionMap[optName] {
            options[def.label, default: []].append(optValue)
          } else if flagMap[optName] != nil {
            throw CommanderProgramError.invalidValue(option: optName, value: optValue)
          } else {
            throw CommanderProgramError.unknownCommand("--\(optName)")
          }
        } else if let def = optionMap[name] {
          // --option value [value...]
          i += 1
          if def.parsing == .upToNextOption {
            while i < argv.count && !argv[i].hasPrefix("-") {
              options[def.label, default: []].append(argv[i])
              i += 1
            }
            continue
          } else {
            guard i < argv.count else {
              throw CommanderProgramError.missingRequiredOption(name)
            }
            options[def.label, default: []].append(argv[i])
          }
        } else if let def = flagMap[name] {
          flags.insert(def.label)
        } else {
          throw CommanderProgramError.unknownCommand("--\(name)")
        }
      } else if token.hasPrefix("-") && token.count > 1 {
        let chars = Array(token.dropFirst())
        for (idx, char) in chars.enumerated() {
          let charStr = String(char)
          if let def = optionMap[charStr] {
            // Short option with value
            if idx == chars.count - 1 {
              i += 1
              guard i < argv.count else {
                throw CommanderProgramError.missingRequiredOption(charStr)
              }
              options[def.label, default: []].append(argv[i])
            } else {
              // Rest of string is the value
              let value = String(chars[(idx + 1)...])
              options[def.label, default: []].append(value)
              break
            }
          } else if let def = flagMap[charStr] {
            flags.insert(def.label)
          } else {
            throw CommanderProgramError.unknownCommand("-\(char)")
          }
        }
      } else {
        positional.append(token)
      }

      i += 1
    }

    return ParsedValues(options: options, flags: flags, positional: positional)
  }

  private func buildOptionMap(_ options: [OptionDefinition]) -> [String: OptionDefinition] {
    var map: [String: OptionDefinition] = [:]
    for opt in options {
      for name in opt.names {
        map[name.stringValue] = opt
      }
    }
    return map
  }

  private func buildFlagMap(_ flags: [FlagDefinition]) -> [String: FlagDefinition] {
    var map: [String: FlagDefinition] = [:]
    for flag in flags {
      for name in flag.names {
        map[name.stringValue] = flag
      }
    }
    return map
  }
}

// MARK: - String Extension

private extension String {
  func firstIndexAndElement(where predicate: (Character) -> Bool) -> (Index, Character)? {
    for (idx, char) in zip(indices, self) {
      if predicate(char) {
        return (idx, char)
      }
    }
    return nil
  }
}
