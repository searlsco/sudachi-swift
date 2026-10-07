import Foundation
import Sudachi
import Testing

@Suite("Sudachi end-to-end")
struct SudachiTests {

    @Test(.enabled(if: DictFixture.isAvailable))
    func dictionaryLoads() throws {
        _ = try DictFixture.makeDictionary()
    }

    @Test(.enabled(if: DictFixture.isAvailable))
    func tokenizesBaselineSentence() throws {
        let dict = try DictFixture.makeDictionary()
        let tok = try SudachiTokenizer(dictionary: dict, mode: .c)
        let morphemes = try tok.tokenize(text: "今日は良い天気ですね。")

        #expect(!morphemes.isEmpty)
        let surfaces = morphemes.map(\.surface).joined()
        #expect(surfaces == "今日は良い天気ですね。")
    }

    @Test(.enabled(if: DictFixture.isAvailable))
    func multiGranularityCompound() throws {
        // Sudachi's headline: 国家公務員 ('national civil servant').
        // C keeps it whole, B splits 国家+公務員, A splits 国家+公務+員.
        let dict = try DictFixture.makeDictionary()

        let tokC = try SudachiTokenizer(dictionary: dict, mode: .c)
        let surfacesC = try tokC.tokenize(text: "国家公務員").map(\.surface)
        #expect(surfacesC == ["国家公務員"])

        let tokA = try SudachiTokenizer(dictionary: dict, mode: .a)
        let surfacesA = try tokA.tokenize(text: "国家公務員").map(\.surface)
        #expect(surfacesA.count >= 2)
    }

    @Test(.enabled(if: DictFixture.isAvailable))
    func morphemeRangeMapsBackToSurface() throws {
        // The `range(in:)` convenience must map a morpheme's codepoint offsets
        // to Swift String indices such that the slice equals its surface.
        let dict = try DictFixture.makeDictionary()
        let tok = try SudachiTokenizer(dictionary: dict, mode: .c)
        let text = "今日は良い天気ですね。"
        for m in try tok.tokenize(text: text) {
            let range = try #require(m.range(in: text))
            #expect(String(text[range]) == m.surface)
        }
    }

    @Test
    func morphemeRangeReturnsNilForBadOffsets() {
        // Offsets past the end of the string (e.g. the morpheme came from a
        // different string) yield nil rather than trapping.
        let outOfBounds = Morpheme(
            surface: "x", readingForm: "", dictionaryForm: "", normalizedForm: "",
            partOfSpeech: [], synonymGroupIds: [], isOov: true, wordId: 0,
            begin: 100, end: 200)
        #expect(outOfBounds.range(in: "短い") == nil)

        // In-range but reversed offsets (begin > end) also yield nil.
        let reversed = Morpheme(
            surface: "", readingForm: "", dictionaryForm: "", normalizedForm: "",
            partOfSpeech: [], synonymGroupIds: [], isOov: false, wordId: 0,
            begin: 4, end: 2)
        #expect(reversed.range(in: "abcdef") == nil)
    }

    @Test
    func morphemeRangeMapsConstructedOffsets() {
        // Success path without a dictionary: valid in-range offsets map to the
        // matching substring, so the extension reaches 100% coverage even when
        // the dictionary-gated tests are skipped.
        let m = Morpheme(
            surface: "ab", readingForm: "", dictionaryForm: "", normalizedForm: "",
            partOfSpeech: [], synonymGroupIds: [], isOov: false, wordId: 0,
            begin: 0, end: 2)
        let r = m.range(in: "abcdef")
        #expect(r != nil)
        if let r { #expect(String("abcdef"[r]) == "ab") }
    }

    @Test(.enabled(if: DictFixture.isAvailable))
    func urlConvenienceInitLoadsAndTokenizes() throws {
        // The URL-based convenience init must resolve the resource directory
        // from the dictionary's parent and produce a working dictionary.
        let url = URL(fileURLWithPath: DictFixture.systemDictPath)
        let dict = try SudachiDictionary(systemDictionary: url)
        let tok = try SudachiTokenizer(dictionary: dict, mode: .c)
        #expect(try !tok.tokenize(text: "今日は").isEmpty)
    }

    @Test
    func urlConvenienceInitThrowsNotFoundForMissingFile() {
        // Covers the convenience init without a dictionary on disk: a missing
        // .dic must surface as .DictionaryNotFound, same as the path-based init.
        // A user dictionary is passed so the URL→path mapping runs too.
        do {
            _ = try SudachiDictionary(
                systemDictionary: URL(fileURLWithPath: "/no/such/dir/system_core.dic"),
                userDictionaries: [URL(fileURLWithPath: "/no/such/dir/user.dic")])
            Issue.record("expected SudachiDictionary init to throw")
        } catch let error as SudachiError {
            guard case .DictionaryNotFound = error else {
                Issue.record("expected .DictionaryNotFound, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test
    func missingSystemDictionaryThrowsNotFound() {
        // The Swift error surface: a missing system dictionary must throw
        // SudachiError.DictionaryNotFound (needs no dictionary on disk).
        do {
            _ = try SudachiDictionary(
                systemDictPath: "/no/such/system_core.dic",
                userDictPaths: [],
                resourceDir: NSTemporaryDirectory())
            Issue.record("expected SudachiDictionary init to throw")
        } catch let error as SudachiError {
            guard case .DictionaryNotFound = error else {
                Issue.record("expected .DictionaryNotFound, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
