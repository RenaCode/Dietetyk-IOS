import XCTest
@testable import Dietetyk

/// `APIConfig` żyje w `UserDefaults.standard`, którego ten test (jako część
/// pakietu hostowanego w apce - `TEST_HOST`/`BUNDLE_LOADER` w project.yml)
/// faktycznie współdzieli z aplikacją. `tearDown` zawsze przywraca domyślny
/// adres, żeby kolejne testy (i ewentualne ręczne odpalenie apki na tym
/// samym symulatorze) nie odziedziczyły adresu ustawionego tutaj.
final class APIConfigTests: XCTestCase {
    override func tearDown() {
        APIConfig.resetToDefault()
        super.tearDown()
    }

    func testSetBaseURLStringAcceptsValidURL() {
        let ok = APIConfig.setBaseURLString("https://example.com")
        XCTAssertTrue(ok)
        XCTAssertEqual(APIConfig.baseURL.absoluteString, "https://example.com")
    }

    func testSetBaseURLStringTrimsWhitespace() {
        let ok = APIConfig.setBaseURLString("  https://example.com  \n")
        XCTAssertTrue(ok)
        XCTAssertEqual(APIConfig.baseURL.absoluteString, "https://example.com")
    }

    func testSetBaseURLStringRejectsMissingScheme() {
        let ok = APIConfig.setBaseURLString("example.com")
        XCTAssertFalse(ok)
    }

    func testSetBaseURLStringRejectsGarbage() {
        let ok = APIConfig.setBaseURLString("nie to nie url")
        XCTAssertFalse(ok)
    }

    /// Sam `scheme != nil` przepuszczał `file:`/`ftp:`/dowolny custom scheme -
    /// adres zapisywał się, a każde żądanie kończyło się potem mętnym błędem
    /// sieci zamiast czytelnym "nieprawidłowy adres serwera".
    func testSetBaseURLStringRejectsNonHTTPSchemes() {
        XCTAssertFalse(APIConfig.setBaseURLString("ftp://example.com"))
        XCTAssertFalse(APIConfig.setBaseURLString("file:///etc/passwd"))
        XCTAssertFalse(APIConfig.setBaseURLString("dietetyk://example.com"))
    }

    /// `http` zostaje dopuszczony świadomie - na potrzeby lokalnego
    /// developmentu przeciw `http://localhost:3000`.
    func testSetBaseURLStringAcceptsHTTPForLocalDevelopment() {
        XCTAssertTrue(APIConfig.setBaseURLString("http://localhost:3000"))
        XCTAssertEqual(APIConfig.baseURL.absoluteString, "http://localhost:3000")
    }

    /// Schemat pisany wielkimi literami to wciąż ten sam schemat.
    func testSetBaseURLStringAcceptsUppercaseScheme() {
        XCTAssertTrue(APIConfig.setBaseURLString("HTTPS://example.com"))
    }

    func testInvalidURLDoesNotOverwritePreviouslyStoredValue() {
        XCTAssertTrue(APIConfig.setBaseURLString("https://dobry-serwer.pl"))
        XCTAssertFalse(APIConfig.setBaseURLString("zly url"))
        XCTAssertEqual(APIConfig.baseURL.absoluteString, "https://dobry-serwer.pl")
    }

    func testResetToDefaultRestoresProductionURL() {
        APIConfig.setBaseURLString("https://example.com")
        APIConfig.resetToDefault()
        XCTAssertEqual(APIConfig.baseURL.absoluteString, APIConfig.defaultBaseURLString)
    }
}
