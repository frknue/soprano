import Foundation

/// Case-insensitive subsequence matching for the command palette, scored like fzf: matched
/// characters count, contiguous runs and word starts count more, gaps and a late start cost.
/// Whitespace in the query is ignored ("darkmode" finds "dark mode"). A match scattered over
/// too many separate runs is no match, so short queries don't light up every long title.
struct FuzzyMatch: Equatable {
    var score: Int
    /// Offsets (in `Character`s) of the matched characters in the text, ascending.
    var positions: [Int]

    static func match(_ query: String, in text: String) -> FuzzyMatch? {
        let needle = query.lowercased().filter { !$0.isWhitespace }.map { $0 }
        guard !needle.isEmpty else { return nil }
        let original = Array(text)
        let hay = original.map { String($0).lowercased().first ?? $0 }
        guard hay.count >= needle.count else { return nil }

        var best: FuzzyMatch?
        for start in hay.indices where hay[start] == needle[0] {
            guard let positions = forwardMatch(needle, in: hay, from: start) else { break }
            let candidate = FuzzyMatch(score: score(positions, original: original, needleCount: needle.count), positions: positions)
            if runs(positions) > 1 + needle.count / 3 { continue }
            if best == nil || candidate.score > best!.score { best = candidate }
        }
        guard var result = best else { return nil }
        let lowered = text.lowercased()
        let plainQuery = query.lowercased().trimmingCharacters(in: .whitespaces)
        if lowered == plainQuery {
            result.score += 100
        } else if lowered.hasPrefix(plainQuery) {
            result.score += 40
        }
        return result
    }

    /// Earliest positions of `needle` in `hay` starting at `start`; nil when it doesn't fit.
    private static func forwardMatch(_ needle: [Character], in hay: [Character], from start: Int) -> [Int]? {
        var positions: [Int] = []
        positions.reserveCapacity(needle.count)
        var index = start
        for character in needle {
            while index < hay.count, hay[index] != character { index += 1 }
            guard index < hay.count else { return nil }
            positions.append(index)
            index += 1
        }
        return positions
    }

    private static func runs(_ positions: [Int]) -> Int {
        guard !positions.isEmpty else { return 0 }
        return 1 + zip(positions, positions.dropFirst()).filter { $1 != $0 + 1 }.count
    }

    private static func score(_ positions: [Int], original: [Character], needleCount: Int) -> Int {
        var score = 0
        var previous: Int?
        for position in positions {
            score += 16
            if isWordStart(position, in: original) {
                score += position == 0 ? 32 : 20
            }
            if let previous {
                if position == previous + 1 {
                    score += 32
                } else {
                    score -= 8 + 2 * min(position - previous - 1, 12)
                }
            }
            previous = position
        }
        score -= min(positions.first ?? 0, 12)
        // One unbroken run (a plain substring) reads best.
        if runs(positions) == 1 { score += 30 }
        return score
    }

    private static func isWordStart(_ index: Int, in text: [Character]) -> Bool {
        guard index > 0 else { return true }
        let previous = text[index - 1]
        let current = text[index]
        if !(previous.isLetter || previous.isNumber) { return true }
        return previous.isLowercase && current.isUppercase
    }
}
