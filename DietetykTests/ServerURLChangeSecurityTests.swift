import XCTest
@testable import Dietetyk

/// Atrapa magazynu tokenu. Prawdziwy Keychain NIE nadaje się do tego testu:
/// CI buduje bez podpisu (`CODE_SIGNING_ALLOWED=NO`), więc `SecItemAdd`
/// zwraca `errSecMissingEntitlement` i zapis po cichu nie następuje - test
/// oparty o Keychain sprawdzałby obecność uprawnień, a nie logikę sesji.
/// (Pierwsza wersja tych testów faktycznie się o to rozbiła w CI.)
private final class InMemoryTokenStore: SessionTokenStore {
    private(set) var token: String?
    /// Pozwala odtworzyć sytuację, w której Keychain odmawia zapisu.
    var failSave = false

    init(token: String? = nil) {
        self.token = token
    }

    func save(_ token: String) -> Bool {
        guard !failSave else { return false }
        self.token = token
        return true
    }

    func load() -> String? { token }

    func delete() { token = nil }
}

/// Token sesji jest wystawiony przez KONKRETNY backend, a `APIClient.perform`
/// dokleja go jako `Authorization: Bearer` do każdego żądania pod aktualny
/// `APIConfig.baseURL` - bez sprawdzania, czy to nadal ten sam serwer. Dopóki
/// zmiana adresu w Ustawieniach nie czyściła magazynu tokenu, wpisanie cudzego
/// adresu wysyłało żywy token konta na obcy host. Te testy pilnują, że token
/// znika DOKŁADNIE wtedy, gdy zmienia się serwer - i nie znika, gdy nic się
/// nie zmieniło.
@MainActor
final class ServerURLChangeSecurityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        APIConfig.resetToDefault()
    }

    override func tearDown() {
        APIConfig.resetToDefault()
        super.tearDown()
    }

    /// Sedno: po zmianie adresu token poprzedniego serwera nie może zostać na
    /// urządzeniu, bo następne żądanie wyśle go pod NOWY adres.
    func testChangingServerAddressClearsSessionToken() {
        let store = InMemoryTokenStore(token: "sess_token_konta_produkcyjnego")
        let appState = AppState(tokenStore: store)
        XCTAssertTrue(appState.isAuthenticated, "warunek wstępny: zaczynamy jako zalogowani")

        let viewModel = SettingsViewModel(appState: appState)
        viewModel.serverURLText = "https://obcy-serwer.example"
        XCTAssertTrue(viewModel.saveServerURL())

        XCTAssertEqual(APIConfig.baseURL.absoluteString, "https://obcy-serwer.example")
        XCTAssertNil(store.token, "token poprzedniego serwera MUSI zniknąć")
        XCTAssertFalse(appState.isAuthenticated, "aplikacja musi wrócić na ekran logowania")
    }

    /// Powrót na domyślny backend to też zmiana serwera.
    func testResettingToDefaultServerClearsSessionToken() {
        XCTAssertTrue(APIConfig.setBaseURLString("https://wlasny-serwer.example"))
        let store = InMemoryTokenStore(token: "sess_token_wlasnego_serwera")
        let appState = AppState(tokenStore: store)
        XCTAssertTrue(appState.isAuthenticated)

        SettingsViewModel(appState: appState).resetServerURL()

        XCTAssertEqual(APIConfig.baseURL.absoluteString, APIConfig.defaultBaseURLString)
        XCTAssertNil(store.token)
        XCTAssertFalse(appState.isAuthenticated)
    }

    /// Zapisanie TEGO SAMEGO adresu nie jest zmianą serwera - nie wolno przy
    /// tym wylogowywać, bo użytkownik straciłby sesję za samo dotknięcie pola.
    func testSavingIdenticalAddressKeepsSession() {
        let store = InMemoryTokenStore(token: "sess_token_do_zachowania")
        let appState = AppState(tokenStore: store)
        let viewModel = SettingsViewModel(appState: appState)
        viewModel.serverURLText = APIConfig.defaultBaseURLString

        XCTAssertTrue(viewModel.saveServerURL())

        XCTAssertEqual(store.token, "sess_token_do_zachowania")
        XCTAssertTrue(appState.isAuthenticated)
    }

    /// Odrzucony adres nie zmienia serwera, więc nie może też skasować sesji -
    /// literówka nie powinna wylogowywać.
    func testRejectedAddressNeitherChangesServerNorClearsSession() {
        let store = InMemoryTokenStore(token: "sess_token_do_zachowania")
        let appState = AppState(tokenStore: store)
        let viewModel = SettingsViewModel(appState: appState)
        viewModel.serverURLText = "ftp://obcy-serwer.example"

        XCTAssertFalse(viewModel.saveServerURL(), "ftp: nie jest dozwolonym schematem")

        XCTAssertEqual(APIConfig.baseURL.absoluteString, APIConfig.defaultBaseURLString)
        XCTAssertEqual(store.token, "sess_token_do_zachowania")
        XCTAssertTrue(appState.isAuthenticated)
    }

    // MARK: - Nieudany zapis tokenu

    /// Odkryte przy okazji: `SecItemAdd` potrafi realnie odmówić zapisu
    /// (build bez podpisu -> `errSecMissingEntitlement`), a jego wynik był
    /// ignorowany. Apka przechodziła wtedy na ekran główny z pustym
    /// magazynem, po czym każde żądanie wracało z 401.
    func testFailedTokenSaveDoesNotFakeALoggedInSession() {
        let store = InMemoryTokenStore()
        store.failSave = true
        let appState = AppState(tokenStore: store)

        XCTAssertThrowsError(try appState.markAuthenticated(token: "sess_nowy")) { error in
            XCTAssertEqual((error as? AppStateError), .tokenStorageFailed)
        }
        XCTAssertFalse(appState.isAuthenticated, "bez zapisanego tokenu nie wolno uznawać sesji za aktywną")
        XCTAssertNil(store.token)
    }

    func testSuccessfulTokenSaveStartsSession() throws {
        let store = InMemoryTokenStore()
        let appState = AppState(tokenStore: store)

        try appState.markAuthenticated(token: "sess_nowy")

        XCTAssertTrue(appState.isAuthenticated)
        XCTAssertEqual(store.token, "sess_nowy")
    }
}
