// Regenerates Keyboard/emoji.txt from the Unicode emoji list and the CLDR
// English annotations, which supply the words each emoji is searched by:
//
//   https://unicode.org/Public/emoji/16.0/emoji-test.txt
//   https://github.com/unicode-org/cldr/blob/release-46/common/annotations/en.xml
//
//   swift tools/gen_emoji.swift emoji-test.txt en.xml Keyboard/emoji.txt
//
// The output has a "# Name" line for each group, followed by a line for each
// of its emoji in Unicode's order: the emoji, its name and its keywords,
// separated by tabs, with "|" between keywords. Skin-tone variants are left
// out: there are five of each and the picker has no way to choose between them.

import Foundation

let args = CommandLine.arguments
guard args.count == 4,
      let source = try? String(contentsOfFile: args[1], encoding: .utf8),
      let annotations = try? String(contentsOfFile: args[2], encoding: .utf8)
else {
    FileHandle.standardError.write("usage: gen_emoji.swift emoji-test.txt en.xml out.txt\n".data(using: .utf8)!)
    exit(1)
}

// Unicode's groups, renamed and merged the way people expect to find them.
let names = [
    "Smileys & Emotion": "Smileys & People",
    "People & Body": "Smileys & People",
    "Animals & Nature": "Animals & Nature",
    "Food & Drink": "Food & Drink",
    "Travel & Places": "Travel & Places",
    "Activities": "Activities",
    "Objects": "Objects",
    "Symbols": "Symbols",
    "Flags": "Flags",
]
let skinTones: ClosedRange<UInt32> = 0x1F3FB...0x1F3FF

/// CLDR writes emoji without the variation selector that asks for colour.
func bare(_ emoji: String) -> String {
    String(String.UnicodeScalarView(emoji.unicodeScalars.filter { $0.value != 0xFE0F }))
}

func unescaped(_ xml: Substring) -> String {
    xml.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
}

var spoken: [String: String] = [:]
var keywords: [String: [String]] = [:]
for match in annotations.matches(of: #/<annotation cp="([^"]+)"( type="tts")?>([^<]*)</annotation>/#) {
    let emoji = bare(String(match.1))
    if match.2 != nil {
        spoken[emoji] = unescaped(match.3)
    } else {
        keywords[emoji] = match.3.split(separator: "|").map { unescaped($0).trimmingCharacters(in: .whitespaces) }
    }
}

var order: [String] = []
var groups: [String: [String]] = [:]
var current: String?
var unnamed = 0
for line in source.split(separator: "\n") {
    if line.hasPrefix("# group: ") {
        current = names[String(line.dropFirst("# group: ".count))]
        continue
    }
    guard let current, !line.hasPrefix("#"), line.contains("; fully-qualified") else { continue }
    let scalars = line.prefix { $0 != ";" }.split(separator: " ").compactMap { UInt32($0, radix: 16) }
    guard !scalars.contains(where: skinTones.contains) else { continue }
    let emoji = String(String.UnicodeScalarView(scalars.compactMap(Unicode.Scalar.init)))
    // "... # 😀 E1.0 grinning face"
    let listed = line.split(separator: "#", maxSplits: 1).last!.split(separator: " ", maxSplits: 2).last!
    if spoken[bare(emoji)] == nil {
        unnamed += 1
    }
    let name = spoken[bare(emoji)] ?? String(listed)
    let extra = (keywords[bare(emoji)] ?? []).filter { $0 != name }
    if groups[current] == nil {
        order.append(current)
    }
    groups[current, default: []].append("\(emoji)\t\(name)\t\(extra.joined(separator: "|"))")
}

let text = order.map { "# \($0)\n" + groups[$0]!.joined(separator: "\n") + "\n" }.joined()
try! text.write(toFile: args[3], atomically: true, encoding: .utf8)
print(order.map { "\($0): \(groups[$0]!.count)" }.joined(separator: ", "))
print("\(unnamed) named from the emoji list for want of an annotation")
