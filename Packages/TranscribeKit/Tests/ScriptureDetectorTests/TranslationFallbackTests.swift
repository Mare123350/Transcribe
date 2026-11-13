import Foundation
import Testing
@testable import ScriptureDetector

@Suite("Choosing a translation, with fallback")
struct TranslationFallbackTests {
    let installed = ["KJV", "WEB", "BSB", "ASV", "YLT"]

    @Test("A named version that's installed is used")
    func installedRequest() {
        let choice = TranslationResolver.resolve(requested: "bsb", installed: installed, defaultVersion: "KJV")
        #expect(choice == TranslationChoice(shown: "BSB", requested: nil, source: .installed))
        #expect(choice.label == nil)
    }

    @Test("A missing version falls back to the default, labelled")
    func fallbackToDefault() {
        let choice = TranslationResolver.resolve(requested: "NIV", installed: installed, defaultVersion: "KJV")
        #expect(choice.shown == "KJV")
        #expect(choice.source == .fallback)
        #expect(choice.label == "NIV requested, showing KJV")
    }

    @Test("An online provider is preferred to falling back")
    func onlineRequest() {
        let choice = TranslationResolver.resolve(requested: "ESV", installed: installed, online: ["ESV"], defaultVersion: "KJV")
        #expect(choice == TranslationChoice(shown: "ESV", requested: nil, source: .online))
    }

    @Test("The fallback order is followed when the default lacks the passage")
    func fallbackOrder() {
        // A partial import (New Testament only) as the default, asked for an Old Testament verse.
        let choice = TranslationResolver.resolve(
            requested: nil, installed: ["NTONLY"] + installed, defaultVersion: "NTONLY", order: ["NIV", "WEB", "KJV"],
            hasPassage: { $0 != "NTONLY" }
        )
        #expect(choice == TranslationChoice(shown: "WEB", requested: nil, source: .installed))
    }

    @Test("A requested version installed without the passage falls back")
    func partialRequested() {
        let choice = TranslationResolver.resolve(requested: "NIV", installed: ["NIV"] + installed, defaultVersion: "KJV", hasPassage: { $0 != "NIV" })
        #expect(choice.label == "NIV requested, showing KJV")
    }

    @Test("A default that isn't installed is skipped")
    func missingDefault() {
        let choice = TranslationResolver.resolve(requested: nil, installed: installed, defaultVersion: "NIV", order: ["BSB"])
        #expect(choice.shown == "BSB")
    }

    @Test("Nothing has the passage")
    func nothing() {
        let choice = TranslationResolver.resolve(requested: "NIV", installed: installed, defaultVersion: "KJV", hasPassage: { _ in false })
        #expect(choice.source == .missing)
        #expect(choice.label == "NIV requested, not available")
    }

    @Test("The detector shows the default's text for a version that isn't installed")
    func detectorFallback() async throws {
        let bibles = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../Transcribe/Resources/Bibles").standardized
        let files = try FileManager.default.contentsOfDirectory(at: bibles, includingPropertiesForKeys: nil).filter { $0.pathExtension == "sqlite" }
        let detector = ScriptureDetector(translations: TranslationLibrary.load(bundled: files, importedDirectory: nil))
        let john316 = BibleReference(book: "JHN", chapter: 3, verseStart: 16)
        let resolved = await detector.resolvedPassage(john316, requested: "NIV", defaultVersion: "KJV", order: [])
        #expect(resolved.choice.label == "NIV requested, showing KJV")
        #expect(resolved.text?.hasPrefix("For God so loved the world") == true)
    }
}

@Suite("Online providers and their cache")
struct OnlineProviderTests {
    final class MockHTTP: HTTPClient, @unchecked Sendable {
        var requests: [(URL, [String: String])] = []
        var responses: [String: (String, Int)] = [:]
        let lock = NSLock()

        func get(_ url: URL, headers: [String: String]) async throws -> (data: Data, status: Int) {
            lock.withLock { requests.append((url, headers)) }
            let match = lock.withLock { responses.first { url.absoluteString.contains($0.key) }?.value }
            guard let (body, status) = match else { return (Data(), 200) }
            return (Data(body.utf8), status)
        }
    }

    @Test("ESV: key sent as a token, text cached, attribution included")
    func esv() async throws {
        let http = MockHTTP()
        http.responses["api.esv.org"] = (#"{"passages": ["  For God so loved the world, that he gave his only Son.\n\n"]}"#, 200)
        let service = OnlineBibleService(http: http, credentials: MemoryCredentialStore([.esv: "secret"]), cache: try OnlineVerseCache(url: nil))
        let reference = BibleReference(book: "JHN", chapter: 3, verseStart: 16)
        let passage = try await service.passage(reference, abbreviation: "ESV")
        #expect(passage.text == "For God so loved the world, that he gave his only Son.")
        #expect(passage.copyright.contains("Crossway"))
        #expect(http.requests.first?.1["Authorization"] == "Token secret")
        #expect(http.requests.first?.0.absoluteString.contains("q=John%203:16") == true)

        let again = try await service.passage(reference, abbreviation: "ESV")
        #expect(again.fromCache)
        #expect(http.requests.count == 1)
    }

    @Test("A rejected key is reported clearly")
    func badKey() async throws {
        let http = MockHTTP()
        http.responses["api.esv.org"] = ("{}", 401)
        let service = OnlineBibleService(http: http, credentials: MemoryCredentialStore([.esv: "wrong"]), cache: try OnlineVerseCache(url: nil))
        await #expect(throws: OnlineBibleError.invalidKey(.esv)) {
            try await service.passage(BibleReference(book: "JHN", chapter: 3, verseStart: 16), abbreviation: "ESV")
        }
    }

    @Test("Without a key, a provider's versions aren't offered")
    func noKey() async throws {
        let service = OnlineBibleService(http: MockHTTP(), credentials: MemoryCredentialStore(), cache: try OnlineVerseCache(url: nil))
        #expect(await service.availableVersions().isEmpty)
    }

    @Test("API.Bible: passage id, api-key header, usage reported anonymously")
    func apiBible() async throws {
        let http = MockHTTP()
        http.responses["/passages/"] = (#"{"data": {"content": "     For God so loved the world. ", "copyright": "© Test Publisher"}, "meta": {"fumsToken": "tok123"}}"#, 200)
        let niv = OnlineVersion(provider: .apiBible, abbreviation: "NIV", name: "New International Version", remoteID: "78a9f6124f344018-01")
        let service = OnlineBibleService(http: http, credentials: MemoryCredentialStore([.apiBible: "k"]), cache: try OnlineVerseCache(url: nil), apiBibleVersions: [niv], deviceID: "device")
        let passage = try await service.passage(BibleReference(book: "JHN", chapter: 3, verseStart: 16, verseEnd: 18), abbreviation: "niv")
        #expect(passage.text == "For God so loved the world.")
        #expect(passage.copyright == "© Test Publisher")
        let request = try #require(http.requests.first)
        #expect(request.0.absoluteString.contains("/v1/bibles/78a9f6124f344018-01/passages/JHN.3.16-JHN.3.18"))
        #expect(request.1["api-key"] == "k")
        try await Task.sleep(for: .milliseconds(100))
        let fums = http.requests.first { $0.0.host == "fums.api.bible" }
        #expect(fums?.0.query?.contains("t=tok123") == true)
        #expect(fums?.0.query?.contains("dId=device") == true)
    }

    @Test("ESV cache never holds more than 500 verses")
    func esvLimit() throws {
        let cache = try OnlineVerseCache(url: nil)
        let start = Date(timeIntervalSince1970: 1_000)
        for chapter in 1...30 {
            cache.store(provider: .esv, version: "esv", key: "PSA.\(chapter)", text: "x", copyright: "", verses: 20, now: start.addingTimeInterval(Double(chapter)))
        }
        #expect(cache.totalVerses(.esv) <= 500)
        #expect(cache.passage(provider: .esv, version: "esv", key: "PSA.1") == nil)
        #expect(cache.passage(provider: .esv, version: "esv", key: "PSA.30") != nil)
        cache.store(provider: .esv, version: "esv", key: "PSA.119", text: "x", copyright: "", verses: 600)
        #expect(cache.passage(provider: .esv, version: "esv", key: "PSA.119") == nil)
    }

    @Test("API.Bible cache entries expire after 30 days")
    func apiBibleExpiry() throws {
        let cache = try OnlineVerseCache(url: nil)
        let fetched = Date(timeIntervalSince1970: 1_000_000)
        cache.store(provider: .apiBible, version: "niv", key: "JHN.3.16-16", text: "x", copyright: "", verses: 1, now: fetched)
        #expect(cache.passage(provider: .apiBible, version: "niv", key: "JHN.3.16-16", now: fetched.addingTimeInterval(29 * 86400)) != nil)
        #expect(cache.passage(provider: .apiBible, version: "niv", key: "JHN.3.16-16", now: fetched.addingTimeInterval(31 * 86400)) == nil)
    }
}
