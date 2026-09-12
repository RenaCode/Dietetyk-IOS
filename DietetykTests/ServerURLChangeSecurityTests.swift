import XCTest
@testable import Dietetyk

/// Token sesji z Keychain jest wystawiony przez KONKRETNY backend, a
/// `APIClient.perform` dokleja go jako `Authorization: Bearer` do każdego
/// żądania pod aktualny `APIConfig.baseURL` - bez sprawdzania, czy to nadal
/// ten sam serwer. Dopóki zmiana adresu w Ustawieniach nie czyściła Keychain,
/// wpisanie cudzego adresu wysyłało żywy token produkcyjnego konta na obcy
/// host. Te testy pilnują, że token znika DOKŁADNIE wtedy, gdy zmienia się
/// serwer - i nie znika, gdy nic się nie zmieniło.
@MainActor
final class ServerURLChangeSecurityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        APIConfig.resetToDefault()
        KeychainStore.deleteToken()
    }

    override func tearDown() {
        APIConfig.resetToDefault()
        KeychainStore.deleteToken()
        super.tearDown()
    }

    /// Sedno: po zmianie adresu token poprzedniego serwera nie może zostać
    /// na urządzeniu, bo następne żądanie wyśle go pod NOWY adres.
    func testChangingServerAddressClearsSessionToken() {
        KeychainStore.saveToken("sess_token_konta_produkcyjnego")
        let appState = AppState()
        XCTAssertTrue(appState.isAuthenticated, "warunek wstępny: zaczynamy jako zalogowani")

        let viewModel = SettingsViewModel(appState: appState)
        viewModel.serverURLText = "https://obcy-serwer.example"
        XCTAssertTrue(viewModel.saveServerURL())

        XCTAssertEqual(APIConfig.baseURL.absoluteString, "https://obcy-serwer.example")
        XCTAssertNil(KeychainStore.loadToken(), "token poprzedniego serwera MUSI zniknąć z Keychain")
        XCTAssertFalse(appState.isAuthenticated, "aplikacja musi wrócić na ekran logowania")
    }

    /// Powrót na domyślny backend to też zmiana serwera.
    func testResettingToDefaultServerClearsSessionToken() {
        XCTAssertTrue(APIConfig.setBaseURLString("https://wlasny-serwer.example"))
        KeychainStore.saveToken("sess_token_wlasnego_serwera")
        let appState = AppState()
        XCTAssertTrue(appState.isAuthenticated)

        let viewModel = SettingsViewModel(appState: appState)
        viewModel.resetServerURL()

        XCTAssertEqual(APIConfig.baseURL.absoluteString, APIConfig.defaultBaseURLString)
        XCTAssertNil(KeychainStore.loadToken())
        XCTAssertFalse(appState.isAuthenticated)
    }

    /// Zapisanie TEGO SAMEGO adresu nie jest zmianą serwera - nie wolno przy
    /// tym wylogowywać, bo użytkownik straciłby sesję za samo dotknięcie pola.
    func testSavingIdenticalAddressKeepsSession() {
        KeychainStore.saveToken("sess_token_do_zachowania")
        let appState = AppState()
        let viewModel = SettingsViewModel(appState: appState)
        viewModel.serverURLText = APIConfig.defaultBaseURLString

        XCTAssertTrue(viewModel.saveServerURL())

        XCTAssertEqual(KeychainStore.loadToken(), "sess_token_do_zachowania")
        XCTAssertTrue(appState.isAuthenticated)
    }

    /// Odrzucony adres nie zmienia serwera, więc nie może też skasować sesji -
    /// literówka nie powinna wylogowywać.
    func testRejectedAddressNeitherChangesServerNorClearsSession() {
        KeychainStore.saveToken("sess_token_do_zachowania")
        let appState = AppState()
        let viewModel = SettingsViewModel(appState: appState)
        viewModel.serverURLText = "ftp://obcy-serwer.example"

        XCTAssertFalse(viewModel.saveServerURL(), "ftp: nie jest dozwolonym schematem")

        XCTAssertEqual(APIConfig.baseURL.absoluteString, APIConfig.defaultBaseURLString)
        XCTAssertEqual(KeychainStore.loadToken(), "sess_token_do_zachowania")
        XCTAssertTrue(appState.isAuthenticated)
    }
}
