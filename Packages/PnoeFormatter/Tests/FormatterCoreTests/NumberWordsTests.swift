import Testing
@testable import FormatterCore

@Suite("NumberWords")
struct NumberWordsTests {
    struct Case: Sendable { let words: [String]; let value: Int; let count: Int }

    static let cardinals: [Case] = [
        Case(words: ["ten"], value: 10, count: 1),
        Case(words: ["twenty", "one"], value: 21, count: 2),
        Case(words: ["twenty-one"], value: 21, count: 1),
        Case(words: ["forty", "thousand"], value: 40_000, count: 2),
        Case(words: ["twelve", "thousand", "five", "hundred"], value: 12_500, count: 4),
        Case(words: ["one", "hundred", "thousand"], value: 100_000, count: 3),
        Case(words: ["one", "hundred", "and", "five"], value: 105, count: 4),
        Case(words: ["two", "thousand", "twenty", "six"], value: 2026, count: 4),
        Case(words: ["three", "million"], value: 3_000_000, count: 2),
        Case(words: ["ten", "percent"], value: 10, count: 1),
        Case(words: ["five", "five"], value: 5, count: 1),
        Case(words: ["twenty", "twenty"], value: 20, count: 1),
        Case(words: ["fifty", "and", "cats"], value: 50, count: 1),
    ]

    @Test(arguments: cardinals)
    func parsesCardinals(_ c: Case) {
        let result = NumberWords.parseCardinal(c.words)
        #expect(result?.value == c.value)
        #expect(result?.count == c.count)
    }

    @Test(arguments: [["hundred"], ["thousand", "five"], ["and", "five"], ["the", "ten"], ["zero"], []] as [[String]])
    func rejectsNonNumbers(_ words: [String]) {
        #expect(NumberWords.parseCardinal(words) == nil)
    }

    @Test func formatsWithGroupingAndKeepsYears() {
        #expect(NumberWords.format(5) == "5")
        #expect(NumberWords.format(999) == "999")
        #expect(NumberWords.format(2500) == "2,500")
        #expect(NumberWords.format(40_000) == "40,000")
        #expect(NumberWords.format(1_234_567) == "1,234,567")
        #expect(NumberWords.format(2026) == "2026")
        #expect(NumberWords.format(2000) == "2,000")
    }

    @Test func digitSequences() {
        #expect(NumberWords.parseDigitSequence(["four", "oh", "two", "please"])?.digits == "402")
        #expect(NumberWords.parseDigitSequence(["five", "five", "five", "one", "two", "one", "two"])?.digits == "5551212")
        #expect(NumberWords.parseDigitSequence(["one", "two", "three"]) == nil)
        #expect(NumberWords.parseDigitSequence(["oh", "no"]) == nil)
    }
}
