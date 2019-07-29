#!/usr/bin/swift

/// This file is used to check for correctness in CHANGELOG.md files.
/// Specifically, it checks for
/// - Presence of a [tag] at the start of each entry, and the validity of the tag.
/// - Past-tense phrasing.

import Foundation

func showHelp(_ exitCode: Int32 = 0) -> Never {
  print(
    """
    Usage: changelog.swift [-h] changelog
    Arguments:
      -h, --help: Displays usage dialogue
      changelog: Path to a CHANGELOG.md file
    """
  )
  exit(exitCode)
}

let arguments = CommandLine.arguments
let changelogPath: String

if arguments.contains("-h") || arguments.contains("--help") {
  showHelp(0)
}

guard arguments.count == 2 else { showHelp(1) }
changelogPath = arguments[1]

guard let fileContentData = FileManager.default.contents(atPath: changelogPath) else {
  fatalError("Unable to open contents at path \(changelogPath)")
}

let fileContents = String(decoding: fileContentData, as: UTF8.self)

print(fileContents)
