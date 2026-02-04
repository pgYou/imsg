// import Commander  // TODO: Replace with ArgumentParser
import ArgumentParser

struct RuntimeOptions: Sendable {
  let jsonOutput: Bool
  let verbose: Bool
  let logLevel: String?

  init(parsedValues: ParsedValues) {
    self.jsonOutput = parsedValues.flags.contains("jsonOutput")
    self.verbose = parsedValues.flags.contains("verbose")
    self.logLevel = parsedValues.options["logLevel"]?.last
  }
}
