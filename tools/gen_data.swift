// Regenerates core/data/words.txt and core/data/bigrams.txt from Peter Norvig's
// web n-gram counts (https://norvig.com/ngrams/count_1w.txt, count_2w.txt).
//
//   swift tools/gen_data.swift count_1w.txt count_2w.txt core/data
//
// Raw web counts are full of junk tokens, so every candidate is passed through
// the macOS system spell checker. Words that are only valid when capitalised
// ("london" -> "London") are stored capitalised.

import AppKit

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write("usage: gen_data.swift count_1w.txt count_2w.txt outdir\n".data(using: .utf8)!)
    exit(1)
}

let maxCandidates = 70_000
let maxFollowers = 6
let minBigramCount = 400_000

let checker = NSSpellChecker.shared
checker.automaticallyIdentifiesLanguages = false
_ = checker.setLanguage("en")

func valid(_ word: String) -> Bool {
    checker.checkSpelling(of: word, startingAt: 0).location == NSNotFound
}

let singleLetters: Set<String> = ["a", "i"]

// lowercase token -> canonical spelling
var canonical: [String: String] = [:]
var words: [(String, Int)] = []

let unigrams = try! String(contentsOfFile: args[1], encoding: .utf8)
for line in unigrams.split(separator: "\n").prefix(maxCandidates) {
    let parts = line.split(separator: "\t")
    guard parts.count == 2, let count = Int(parts[1]) else { continue }
    let token = String(parts[0])
    guard token.allSatisfy({ $0.isLetter && $0.isASCII }) else { continue }
    if token.count == 1 && !singleLetters.contains(token) { continue }

    let spelling: String
    if token == "i" {
        spelling = "I"
    } else if valid(token) {
        spelling = token
    } else if valid(token.capitalized) {
        spelling = token.capitalized
    } else {
        continue
    }
    canonical[token] = spelling
    words.append((spelling, count))
}

let wordLines = words.map { "\($0.0)\t\($0.1)" }.joined(separator: "\n") + "\n"
try! wordLines.write(toFile: args[3] + "/words.txt", atomically: true, encoding: .utf8)

var followers: [String: [(String, Int)]] = [:]
let bigrams = try! String(contentsOfFile: args[2], encoding: .utf8)
for line in bigrams.split(separator: "\n") {
    let parts = line.split(separator: "\t")
    guard parts.count == 2, let count = Int(parts[1]), count >= minBigramCount else { continue }
    let pair = parts[0].split(separator: " ")
    guard pair.count == 2,
          let first = canonical[pair[0].lowercased()],
          let second = canonical[pair[1].lowercased()] else { continue }
    followers[first.lowercased(), default: []].append((second, count))
}

var bigramLines: [String] = []
for first in followers.keys.sorted() {
    let top = followers[first]!.sorted { $0.1 > $1.1 }.prefix(maxFollowers)
    for (second, count) in top {
        bigramLines.append("\(first)\t\(second)\t\(count)")
    }
}
try! (bigramLines.joined(separator: "\n") + "\n").write(toFile: args[3] + "/bigrams.txt", atomically: true, encoding: .utf8)

print("words: \(words.count)  bigrams: \(bigramLines.count)")
